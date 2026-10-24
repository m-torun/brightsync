import Foundation

/// One paired Hue bridge. Finds it, fetches its light sensors, then keeps the
/// bridge's event stream open so readings arrive the moment they change;
/// nothing is polled. All state lives on one private queue, which is also the
/// URL session's delegate queue.
final class HueBridge: NSObject, URLSessionDataDelegate {
    static let keychainService = "BrightSync Hue"

    struct Snapshot {
        var sensors: [LightSensor] = []
        var problem: String?
    }

    enum PairingAnswer {
        case paired
        case waitingForButton
        case failed(String)
    }

    let id: String
    /// Called on the main queue whenever the sensors, a reading or the problem changes.
    var onUpdate: ((Snapshot) -> Void)?

    private let queue = DispatchQueue(label: "app.brightsync.hue")
    private let log: (String) -> Void
    private lazy var discovery = HueDiscovery(queue: queue)
    private lazy var session: URLSession = {
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var host: String?
    private var key: String?
    /// Set when the Keychain would not hand over the key. Asking again would
    /// prompt again, so that waits for the user to pair or relaunch.
    private var keyUnavailable = false
    private var stopped = false
    private var snapshot = Snapshot()
    private var stream: URLSessionDataTask?
    private var streamOpened: Date?
    private var parser = EventStreamParser()
    private var trustFailed = false
    private var failures = 0
    /// Whether the bridge has been looked for since it was last reached.
    private var searched = false
    private var retry: DispatchWorkItem?
    /// Bumped by every `start`, so replies to an earlier attempt are ignored.
    private var attempt = 0
    /// Set when the stream is reopened after a quiet spell, which is not worth logging.
    private var quietReopen = false

    init(id: String, host: String?, log: @escaping (String) -> Void = Log.write) {
        self.id = id
        self.host = host
        self.log = log
    }

    func connect() {
        queue.async { self.start() }
    }

    /// Reconnects now, forgetting any back-off. For wake and network changes.
    func refresh() {
        queue.async {
            guard !self.stopped else { return }
            self.failures = 0
            self.searched = false
            self.start()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.retry?.cancel()
            self.cancelStream()
        }
    }

    // MARK: - Connecting

    private func start() {
        retry?.cancel()
        retry = nil
        cancelStream()
        attempt += 1
        if key == nil {
            guard !keyUnavailable else { return }
            // The first read of a key stored by another app or build shows a
            // Keychain prompt and blocks this queue until it is answered.
            key = Keychain.password(service: Self.keychainService, account: id)
            if key == nil {
                keyUnavailable = true
                log("hue: could not read the key for bridge \(id) from the Keychain")
                return publish(problem: "BrightSync could not read its Hue key; pair the bridge again")
            }
        }
        guard let host else { return find() }
        fetchSensors(from: host)
    }

    /// Looks the bridge up over Bonjour, in case its address changed.
    private func find() {
        searched = true
        let attempt = self.attempt
        discovery.browse(for: 5) { [self] bridges in
            guard attempt == self.attempt else { return }
            guard let match = bridges.first(where: { $0.id.lowercased() == id.lowercased() }) else {
                return failed("not found on this network")
            }
            if match.host != host {
                log("hue: bridge found at \(match.host)")
                host = match.host
                Preferences.setHueHost(match.host, for: id)
            }
            fetchSensors(from: match.host)
        }
    }

    private func fetchSensors(from host: String) {
        get("/clip/v2/resource/device", from: host) { [self] devices in
            get("/clip/v2/resource/light_level", from: host) { [self] levels in
                let previous = snapshot.sensors
                snapshot.sensors = Hue.sensors(bridgeID: id, lightLevels: levels, devices: devices)
                snapshot.problem = nil
                for sensor in snapshot.sensors where !previous.contains(sensor) {
                    log("hue: \(sensor.name) " + (sensor.unavailable.map { "is \($0)" } ?? "\(Self.format(sensor.lux)) lux"))
                }
                publish()
                openStream(from: host)
            }
        }
    }

    private func get(_ path: String, from host: String, then: @escaping ([HueResource]) -> Void) {
        guard let url = URL(string: "https://\(host)\(path)") else {
            return unusable(host)
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "hue-application-key")
        let attempt = self.attempt
        session.dataTask(with: request) { [self] data, response, error in
            guard attempt == self.attempt else { return }
            if let error {
                return failed(describe(error), lookAgain: true)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                return keyRejected()
            }
            guard status == 200, let data, let reply = try? JSONDecoder().decode(HueEnvelope.self, from: data) else {
                return failed("unexpected reply (HTTP \(status))")
            }
            then(reply.resources)
        }.resume()
    }

    private func openStream(from host: String) {
        guard let url = URL(string: "https://\(host)/eventstream/clip/v2") else {
            return unusable(host)
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "hue-application-key")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The stream is silent while the light is steady. After this long
        // without a byte it is reopened, which also catches a dead connection.
        request.timeoutInterval = 15 * 60
        cancelStream()
        parser = EventStreamParser()
        let task = session.dataTask(with: request)
        stream = task
        streamOpened = Date()
        task.resume()
    }

    private func cancelStream() {
        let task = stream
        stream = nil
        task?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if HueTrust.bridgeID(of: trust, expected: id) != nil {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            trustFailed = true
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === stream else { return completionHandler(.cancel) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            completionHandler(.cancel)
            stream = nil
            return status == 401 || status == 403 ? keyRejected() : failed("event stream refused (HTTP \(status))")
        }
        if !quietReopen {
            log("hue: listening to bridge at \(host ?? "?")")
        }
        quietReopen = false
        searched = false
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === stream else { return }
        for event in parser.feed(data) {
            handle(event)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === stream else { return }
        stream = nil
        let lived = -(streamOpened ?? Date()).timeIntervalSinceNow
        if lived > 60 {
            failures = 0
        }
        if (error as? URLError)?.code == .timedOut, lived > 60 {
            // Quiet for a long time: reopen, refetching readings in case one was missed.
            quietReopen = true
            return start()
        }
        failed(error.map(describe) ?? "event stream closed", lookAgain: true)
    }

    // MARK: - Events

    private func handle(_ text: String) {
        guard let events = try? JSONDecoder().decode([HueEnvelope].self, from: Data(text.utf8)) else { return }
        var changed = false
        for event in events {
            for resource in event.resources where resource.type == "light_level" {
                guard event.type == "update" else {
                    // A sensor was added or removed: fetch the list again.
                    return start()
                }
                let sensorID = Hue.sensorID(bridgeID: id, resource: resource.id)
                guard let index = snapshot.sensors.firstIndex(where: { $0.id == sensorID }) else { continue }
                // Ordinary readings carry the valid flag too, so only a change
                // counts: turned off or back on in the Hue app. Then the
                // sensor's whole state is fetched again rather than pieced
                // together from events.
                let carriesState = resource.enabled != nil || resource.light?.light_level_valid != nil
                let problem = Hue.unavailable(resource)
                if carriesState, (problem == nil) != (snapshot.sensors[index].unavailable == nil) {
                    log("hue: \(snapshot.sensors[index].name) \(problem.map { "is \($0)" } ?? "is reporting again")")
                    return start()
                }
                guard let report = resource.light?.light_level_report,
                      snapshot.sensors[index].unavailable == nil else { continue }
                let lux = Hue.lux(fromLightLevel: report.light_level)
                snapshot.sensors[index].lux = lux
                snapshot.sensors[index].updated = Hue.date(report.changed) ?? Date()
                log("hue: \(snapshot.sensors[index].name) \(Self.format(lux)) lux")
                changed = true
            }
        }
        if changed {
            publish()
        }
    }

    // MARK: - Pairing

    /// Asks the bridge for an application key, which it hands out only within
    /// 30 seconds of its link button being pressed. On success the key goes
    /// into the Keychain and the bridge connects. Completes on the main queue.
    func requestKey(deviceType: String, completion: @escaping (PairingAnswer) -> Void) {
        queue.async { [self] in
            guard let host, let url = URL(string: "https://\(host)/api") else { return finish(.failed("has no usable address")) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["devicetype": deviceType, "generateclientkey": true])
            session.dataTask(with: request) { [self] data, _, error in
                if let error {
                    return finish(.failed(describe(error)))
                }
                let reply = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]])?.first
                if let success = reply?["success"] as? [String: Any], let username = success["username"] as? String {
                    guard Keychain.save(username, service: Self.keychainService, account: id) else {
                        return finish(.failed("could not save the key in the Keychain"))
                    }
                    key = username
                    keyUnavailable = false
                    Preferences.setHueHost(host, for: id)
                    log("hue: paired with bridge at \(host)")
                    return finish(.paired)
                }
                if let error = reply?["error"] as? [String: Any], error["type"] as? Int == 101 {
                    return finish(.waitingForButton)
                }
                finish(.failed("unexpected reply"))
            }.resume()
        }

        func finish(_ answer: PairingAnswer) {
            DispatchQueue.main.async { completion(answer) }
        }
    }

    // MARK: - Failures

    private func failed(_ reason: String, lookAgain: Bool = false) {
        cancelStream()
        guard !stopped else { return }
        if lookAgain, !searched {
            log("hue: bridge at \(host ?? "?"): \(reason); looking for it again")
            return find()
        }
        failures += 1
        let delay = min(5 * pow(2, Double(failures - 1)), 300)
        log("hue: bridge \(reason); trying again in \(Int(delay)) s")
        publish(problem: "Hue bridge \(reason)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if delay >= 60 {
                searched = false
            }
            start()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A bad cached address is forgotten so that Bonjour is asked again.
    private func unusable(_ address: String) {
        log("hue: ignoring unusable bridge address \(address)")
        host = nil
        searched = false
        failed("has no usable address", lookAgain: true)
    }

    private func keyRejected() {
        cancelStream()
        key = nil
        keyUnavailable = true
        log("hue: bridge rejected BrightSync's key")
        publish(problem: "The Hue bridge no longer accepts BrightSync; pair it again")
    }

    private func describe(_ error: Error) -> String {
        if trustFailed {
            trustFailed = false
            return "failed the certificate check"
        }
        // macOS reports a denied Local Network permission as being offline.
        if "\((error as NSError).userInfo)".contains("Local network prohibited") {
            return "unreachable: BrightSync is not allowed on the local network (System Settings → Privacy & Security → Local Network)"
        }
        switch (error as? URLError)?.code {
        case .timedOut?: return "did not answer"
        case .cannotConnectToHost?: return "refused the connection"
        case .notConnectedToInternet?, .networkConnectionLost?: return "unreachable: no network"
        default: return "unreachable (\(error.localizedDescription))"
        }
    }

    private func publish(problem: String? = nil) {
        if problem != nil {
            snapshot.problem = problem
        }
        let snapshot = self.snapshot
        DispatchQueue.main.async { self.onUpdate?(snapshot) }
    }

    static func format(_ lux: Double?) -> String {
        guard let lux else { return "?" }
        return lux < 10 ? String(format: "%.1f", lux) : String(Int(lux.rounded()))
    }
}
