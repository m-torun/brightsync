import Foundation

/// What BrightSync reads from Zigbee2MQTT. Its web interface relays every MQTT
/// message over a WebSocket at `/api` as `{"topic": ..., "payload": ...}`:
/// on connecting, the device list and each device's last known state, then
/// every change as it happens.
enum Zigbee2MQTT {
    /// A device that reports light.
    struct Device: Equatable {
        let ieee: String
        /// The MQTT topic its state arrives under; the user can rename it.
        let friendlyName: String
        /// What BrightSync shows: the friendly name, or the model for a device
        /// still named after its address.
        let name: String
    }

    enum Message {
        /// Every device that reports light. Sent again whenever one is added,
        /// renamed or removed.
        case devices([Device])
        /// A device's state, by friendly name.
        case state(String, [String: Any])
        /// Whether a device is online, by friendly name. Only sent when
        /// availability is turned on in Zigbee2MQTT.
        case availability(String, Bool)
        case other
    }

    /// Zigbee2MQTT 2 reports lux as `illuminance`. Version 1 had lux in
    /// `illuminance_lux`, with `illuminance` a raw value for some devices.
    private static let luxProperties = ["illuminance_lux", "illuminance"]

    static func sensorID(ieee: String) -> String {
        "zigbee2mqtt:\(ieee.lowercased())"
    }

    /// The WebSocket for an address as typed: "host", "host:port" or the
    /// web interface's URL. Without a scheme or port, Zigbee2MQTT's default
    /// port 8080 is assumed.
    static func socketURL(for address: String) -> URL? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = typed.contains("://")
        guard var components = URLComponents(string: hasScheme ? typed : "http://" + typed),
              let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "ws": components.scheme = "ws"
        case "https", "wss": components.scheme = "wss"
        default: return nil
        }
        if !hasScheme, components.port == nil {
            components.port = 8080
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path.hasSuffix("/api") ? path : path + "/api"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// "host:port", for messages.
    static func label(for address: String) -> String {
        guard let url = socketURL(for: address), let host = url.host else { return address }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func parse(_ text: String) -> Message {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let topic = object["topic"] as? String else { return .other }
        let payload = object["payload"]
        if topic == "bridge/devices" {
            return .devices(devices(from: payload))
        }
        if topic.hasPrefix("bridge/") {
            return .other
        }
        if topic.hasSuffix("/availability") {
            // {"state": "online"}, or a bare "online" in older versions.
            let state = (payload as? [String: Any])?["state"] as? String ?? payload as? String
            guard let state else { return .other }
            return .availability(String(topic.dropLast("/availability".count)), state == "online")
        }
        if let state = payload as? [String: Any] {
            return .state(topic, state)
        }
        return .other
    }

    /// The devices in a `bridge/devices` payload that report light. The
    /// coordinator, devices still being interviewed (no definition yet) and
    /// disabled devices are left out.
    static func devices(from payload: Any?) -> [Device] {
        guard let list = payload as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let ieee = entry["ieee_address"] as? String,
                  let friendlyName = entry["friendly_name"] as? String,
                  entry["disabled"] as? Bool != true,
                  let definition = entry["definition"] as? [String: Any],
                  reportsLight(definition["exposes"]) else { return nil }
            let model = definition["description"] as? String ?? definition["model"] as? String
            let unnamed = friendlyName.lowercased() == ieee.lowercased()
            return Device(ieee: ieee.lowercased(), friendlyName: friendlyName,
                          name: unnamed ? model ?? friendlyName : friendlyName)
        }
    }

    /// Whether any exposed feature, at any depth, is a light level.
    private static func reportsLight(_ exposes: Any?) -> Bool {
        guard let features = exposes as? [[String: Any]] else { return false }
        return features.contains { feature in
            luxProperties.contains(feature["property"] as? String ?? "") || reportsLight(feature["features"])
        }
    }

    static func lux(from state: [String: Any]) -> Double? {
        for property in luxProperties {
            if let value = state[property] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }

    /// When the device last reported, if Zigbee2MQTT is set to say
    /// (`advanced.last_seen`: an ISO 8601 date or epoch milliseconds).
    static func lastSeen(_ state: [String: Any]) -> Date? {
        if let milliseconds = state["last_seen"] as? NSNumber {
            return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        return (state["last_seen"] as? String).flatMap { Hue.date($0) }
    }

    /// The light sensors on one server and their readings, kept up to date
    /// from its messages. Readings and availability are kept by friendly
    /// name, the topic they arrive under, so they count whichever order
    /// they come in after connecting.
    struct Readings {
        private(set) var devices: [Device] = []
        private var lux: [String: Double] = [:]
        private var updated: [String: Date] = [:]
        private var offline: Set<String> = []

        var sensors: [LightSensor] {
            devices.map { device in
                let isOffline = offline.contains(device.friendlyName)
                return LightSensor(id: sensorID(ieee: device.ieee), name: device.name,
                                   lux: isOffline ? nil : lux[device.friendlyName],
                                   updated: updated[device.friendlyName],
                                   unavailable: isOffline ? "offline in Zigbee2MQTT" : nil)
            }.sorted { $0.name < $1.name }
        }

        /// Applies one message. Returns true when the sensors or a reading
        /// changed; a report repeating the same light is not a change.
        mutating func apply(_ message: Message, at now: Date = Date()) -> Bool {
            switch message {
            case let .devices(list):
                let before = sensors
                devices = list
                return sensors != before
            case let .state(name, state):
                guard let value = Zigbee2MQTT.lux(from: state), value != lux[name] else { return false }
                lux[name] = value
                updated[name] = lastSeen(state) ?? now
                return devices.contains { $0.friendlyName == name } && !offline.contains(name)
            case let .availability(name, online):
                let changed = offline.contains(name) == online
                if online {
                    offline.remove(name)
                } else {
                    offline.insert(name)
                }
                return changed && devices.contains { $0.friendlyName == name }
            case .other:
                return false
            }
        }
    }
}
