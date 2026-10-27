import Foundation

/// One Zigbee2MQTT server, read through its web interface's WebSocket. The
/// server sends its devices and their last states as soon as the socket
/// opens, then every change, so nothing is polled. All state lives on one
/// private queue, which is also the URL session's delegate queue.
final class Zigbee2MQTTServer: NSObject, URLSessionWebSocketDelegate {
    struct Snapshot {
        var sensors: [LightSensor] = []
        var problem: String?
        /// Whether the device list has arrived over the current connection.
        var connected = false
    }

    let address: String
    /// Called on the main queue whenever the sensors, a reading or the problem changes.
    var onUpdate: ((Snapshot) -> Void)?

    private let queue = DispatchQueue(label: "app.brightsync.zigbee2mqtt")
    private let log: (String) -> Void
    private lazy var session: URLSession = {
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var readings = Zigbee2MQTT.Readings()
    private var snapshot = Snapshot()
    private var socket: URLSessionWebSocketTask?
    private var awaitingPong = false
    private var stopped = false
    private var failures = 0
    private var retry: DispatchWorkItem?

    init(address: String, log: @escaping (String) -> Void = Log.write) {
        self.address = address
        self.log = log
    }

    private var label: String {
        Zigbee2MQTT.label(for: address)
    }

    func connect() {
        queue.async { self.start() }
    }

    /// Reconnects now, forgetting any back-off. For wake and network changes.
    func refresh() {
        queue.async {
            guard !self.stopped else { return }
            self.failures = 0
            self.start()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.retry?.cancel()
            self.close()
        }
    }

    // MARK: - Connecting

    private func start() {
        retry?.cancel()
        retry = nil
        close()
        guard let url = Zigbee2MQTT.socketURL(for: address) else {
            return publish(problem: "Zigbee2MQTT address \(address) is not usable")
        }
        let task = session.webSocketTask(with: url)
        // The device list grows with every device paired; the default limit is 1 MB.
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        awaitingPong = false
        task.resume()
        receive(on: task)
        schedulePing(on: task)
    }

    private func close() {
        let task = socket
        socket = nil
        snapshot.connected = false
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.socket else { return }
            switch result {
            case let .success(.string(text)):
                handle(text)
            case let .success(.data(data)):
                handle(String(decoding: data, as: UTF8.self))
            case .success:
                break
            case let .failure(error):
                return failed(describe(error, task: task))
            }
            receive(on: task)
        }
    }

    /// Light can stay steady for hours, so a silent socket is normal. A ping
    /// every 30 seconds tells a quiet connection from a dead one.
    private func schedulePing(on task: URLSessionWebSocketTask) {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, task === self.socket else { return }
            if awaitingPong {
                return failed("stopped answering")
            }
            awaitingPong = true
            task.sendPing { [weak self] error in
                self?.queue.async {
                    guard let self, task === self.socket else { return }
                    if let error {
                        return self.failed(self.describe(error, task: task))
                    }
                    self.awaitingPong = false
                }
            }
            schedulePing(on: task)
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === socket else { return }
        log("zigbee2mqtt: listening to \(label)")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === socket else { return }
        failed("closed the connection")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === socket else { return }
        failed(error.map { describe($0, task: task) } ?? "closed the connection")
    }

    // MARK: - Messages

    private func handle(_ text: String) {
        let message = Zigbee2MQTT.parse(text)
        let changed = readings.apply(message)
        if case .devices = message {
            let names = readings.sensors.map(\.name)
            if !snapshot.connected || changed {
                log("zigbee2mqtt: \(label) has \(names.count) light sensor\(names.count == 1 ? "" : "s")"
                    + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")))
            }
            failures = 0
            snapshot.connected = true
            snapshot.problem = nil
            return publish()
        }
        if changed {
            publish()
        }
    }

    // MARK: - Failures

    private func failed(_ reason: String) {
        close()
        guard !stopped else { return }
        failures += 1
        let delay = min(5 * pow(2, Double(failures - 1)), 300)
        log("zigbee2mqtt: \(label) \(reason); trying again in \(Int(delay)) s")
        publish(problem: "Zigbee2MQTT at \(label) \(reason)")
        let work = DispatchWorkItem { [weak self] in self?.start() }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func describe(_ error: Error, task: URLSessionTask) -> String {
        // macOS reports a denied Local Network permission as being offline.
        if "\((error as NSError).userInfo)".contains("Local network prohibited") {
            return "is unreachable: BrightSync is not allowed on the local network (System Settings → Privacy & Security → Local Network)"
        }
        switch (task.response as? HTTPURLResponse)?.statusCode {
        case 401?: return "asks for an auth token, which BrightSync does not support yet"
        case 404?: return "has no web interface there; check the address and that the frontend is enabled"
        default: break
        }
        switch (error as? URLError)?.code {
        case .timedOut?: return "did not answer"
        case .cannotConnectToHost?: return "refused the connection"
        case .cannotFindHost?: return "was not found"
        case .notConnectedToInternet?, .networkConnectionLost?: return "is unreachable: no network"
        case .badServerResponse?: return "did not open a WebSocket; check the address and that the frontend is enabled"
        default: return "is unreachable (\(error.localizedDescription))"
        }
    }

    private func publish(problem: String? = nil) {
        if problem != nil {
            snapshot.problem = problem
        }
        snapshot.sensors = readings.sensors
        let snapshot = self.snapshot
        DispatchQueue.main.async { self.onUpdate?(snapshot) }
    }
}
