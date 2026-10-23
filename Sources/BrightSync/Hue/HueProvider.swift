import AppKit

/// Light sensors on every paired Philips Hue bridge, such as the motion
/// sensor's ambient light reading. A bridge counts as paired when the
/// Keychain holds a key for it, so a user who never pairs one never sees a
/// prompt or a network request.
final class HueProvider: LightSensorProvider {
    let name = "Philips Hue"
    private(set) var sensors: [LightSensor] = []
    private(set) var problem: String?
    private(set) var isPairing = false
    var onChange: (() -> Void)?

    private var bridges: [String: HueBridge] = [:]
    private var snapshots: [String: HueBridge.Snapshot] = [:]
    private let pairingQueue = DispatchQueue(label: "app.brightsync.hue.pairing")
    private lazy var discovery = HueDiscovery(queue: pairingQueue)

    var isPaired: Bool {
        !bridges.isEmpty
    }

    var activity: String? {
        isPairing ? "Waiting for the link button on your Hue bridge…" : nil
    }

    /// Hue sensors come from a bridge: explains the link button, then pairs
    /// and reports how it went. The bridge's light sensors then show up.
    func addSensors() {
        guard !isPairing else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pair with your Hue bridge"
        alert.informativeText = "Press the round link button on top of the Hue bridge, then click Pair. BrightSync looks for bridges on this network and keeps asking for 30 seconds.\n\nmacOS may ask whether BrightSync may find devices on your local network; it needs that to reach the bridge."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pair { failure in
            NSApp.activate(ignoringOtherApps: true)
            let result = NSAlert()
            if let failure {
                result.messageText = "Could not pair with the Hue bridge"
                result.informativeText = failure
            } else {
                result.messageText = "Paired with the Hue bridge"
                result.informativeText = "Its light sensors are listed under Sensors, and can be chosen under Brightness → Follow."
            }
            result.runModal()
        }
    }

    func start() {
        for id in Keychain.accounts(service: HueBridge.keychainService) {
            add(HueBridge(id: id, host: Preferences.hueHost(for: id)))
        }
    }

    func refresh() {
        bridges.values.forEach { $0.refresh() }
    }

    /// Looks for bridges, then asks each for a key every two seconds for 30
    /// seconds while the user presses the link button. Completes on the main
    /// queue with nil once paired, or the reason it did not work.
    func pair(completion: @escaping (String?) -> Void) {
        guard !isPairing else { return }
        isPairing = true
        onChange?()
        let finish = { [weak self] (failure: String?) in
            self?.isPairing = false
            self?.onChange?()
            completion(failure)
        }
        discovery.browse(for: 4) { found in
            DispatchQueue.main.async {
                guard !found.isEmpty else {
                    return finish("No Hue bridge was found on this network.")
                }
                let candidates = found.map { HueBridge(id: $0.id, host: $0.host) }
                self.ask(candidates, until: Date().addingTimeInterval(30), finish: finish)
            }
        }
    }

    private func ask(_ candidates: [HueBridge], until deadline: Date, finish: @escaping (String?) -> Void) {
        let deviceType = "brightsync#" + (Host.current().localizedName ?? "Mac").prefix(19)
        let group = DispatchGroup()
        var paired: HueBridge?
        var failure: String?
        for bridge in candidates {
            group.enter()
            bridge.requestKey(deviceType: deviceType) { answer in
                switch answer {
                case .paired: paired = bridge
                case .waitingForButton: break
                case let .failed(reason): failure = "The Hue bridge \(reason)."
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if let paired {
                self.add(paired, replacing: true)
                finish(nil)
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.ask(candidates, until: deadline, finish: finish)
                }
            } else {
                finish(failure ?? "The link button was not pressed within 30 seconds.")
            }
        }
    }

    private func add(_ bridge: HueBridge, replacing: Bool = false) {
        let id = bridge.id.lowercased()
        if let existing = bridges[id] {
            guard replacing else { return }
            existing.stop()
        }
        bridges[id] = bridge
        bridge.onUpdate = { [weak self] snapshot in
            self?.snapshots[id] = snapshot
            self?.merge()
        }
        bridge.connect()
    }

    private func merge() {
        sensors = snapshots.values.flatMap(\.sensors).sorted { $0.name < $1.name }
        problem = snapshots.values.compactMap(\.problem).first
        onChange?()
    }
}
