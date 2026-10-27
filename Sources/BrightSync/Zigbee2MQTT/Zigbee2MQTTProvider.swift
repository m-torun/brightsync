import AppKit

/// Light sensors on Zigbee2MQTT servers: any Zigbee device that reports
/// illuminance, such as a motion or presence sensor. A server is added by the
/// address of its web interface, which is all BrightSync keeps; a user who
/// never adds one never sees a network request.
final class Zigbee2MQTTProvider: LightSensorProvider {
    let name = "Zigbee2MQTT"
    private(set) var sensors: [LightSensor] = []
    private(set) var problem: String?
    private(set) var activity: String?
    var onChange: (() -> Void)?

    private var servers: [String: Zigbee2MQTTServer] = [:]
    private var snapshots: [String: Zigbee2MQTTServer.Snapshot] = [:]

    var isSetUp: Bool {
        !servers.isEmpty
    }

    func start() {
        for address in Preferences.zigbee2mqttServers {
            add(Zigbee2MQTTServer(address: address))
        }
    }

    func refresh() {
        servers.values.forEach { $0.refresh() }
    }

    /// Asks for the server's address, checks that it answers, then keeps it.
    /// Its light sensors then show up.
    func addSensors() {
        guard activity == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a Zigbee2MQTT server"
        alert.informativeText = "Enter the address of its web interface, such as 192.168.1.10:8080. BrightSync reads the light level of every device that reports one.\n\nThe frontend must be on in Zigbee2MQTT, without an auth token. macOS may ask whether BrightSync may find devices on your local network; it needs that to reach the server."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "host:8080"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        check(address) { failure in
            NSApp.activate(ignoringOtherApps: true)
            let result = NSAlert()
            if let failure {
                result.messageText = "Could not add the Zigbee2MQTT server"
                result.informativeText = failure
            } else {
                let found = self.snapshots[self.key(address)]?.sensors.map(\.name) ?? []
                result.messageText = "Added Zigbee2MQTT at \(Zigbee2MQTT.label(for: address))"
                result.informativeText = found.isEmpty
                    ? "None of its devices reports a light level yet. Ones that do appear under Sensors as they are paired."
                    : "Found \(found.joined(separator: ", ")). Choose a sensor under Brightness → Follow."
            }
            result.runModal()
        }
    }

    /// Connects to `address` and waits for its device list. Completes on the
    /// main queue with nil once it arrived and the server is kept, or the
    /// reason it did not work.
    func check(_ address: String, completion: @escaping (String?) -> Void) {
        guard Zigbee2MQTT.socketURL(for: address) != nil else {
            return completion("“\(address)” is not an address BrightSync can use.")
        }
        if let existing = servers[key(address)] {
            existing.refresh()
            return completion(nil)
        }
        activity = "Connecting to Zigbee2MQTT at \(Zigbee2MQTT.label(for: address))…"
        onChange?()
        let server = Zigbee2MQTTServer(address: address)
        var finished = false
        let finish = { [weak self] (failure: String?) in
            guard let self, !finished else { return }
            finished = true
            activity = nil
            if failure == nil {
                Preferences.zigbee2mqttServers.append(address)
                add(server)
            } else {
                server.stop()
                onChange?()
            }
            completion(failure)
        }
        server.onUpdate = { [weak self] snapshot in
            if snapshot.connected {
                self?.snapshots[self?.key(address) ?? address] = snapshot
                finish(nil)
            } else if let problem = snapshot.problem {
                finish(problem + ".")
            }
        }
        server.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            finish("Zigbee2MQTT at \(Zigbee2MQTT.label(for: address)) did not send its devices within 10 seconds.")
        }
    }

    /// The same server typed two ways counts once.
    private func key(_ address: String) -> String {
        Zigbee2MQTT.socketURL(for: address)?.absoluteString.lowercased() ?? address
    }

    private func add(_ server: Zigbee2MQTTServer) {
        let key = key(server.address)
        guard servers[key] == nil else { return }
        servers[key] = server
        server.onUpdate = { [weak self] snapshot in
            self?.snapshots[key] = snapshot
            self?.merge()
        }
        if snapshots[key] == nil {
            server.connect()
        } else {
            merge()
        }
    }

    private func merge() {
        sensors = snapshots.values.flatMap(\.sensors).sorted { $0.name < $1.name }
        problem = snapshots.values.compactMap(\.problem).first
        onChange?()
    }
}
