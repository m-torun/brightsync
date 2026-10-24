import Foundation

/// The parts of the Hue bridge's CLIP v2 resources that BrightSync uses.
struct HueResource: Decodable {
    struct Reference: Decodable {
        let rid: String
        let rtype: String
    }

    struct Metadata: Decodable {
        let name: String?
    }

    struct Light: Decodable {
        struct Report: Decodable {
            let changed: String?
            let light_level: Int
        }

        let light_level_report: Report?
        /// False while the sensor has nothing trustworthy to report.
        let light_level_valid: Bool?
    }

    let id: String
    let type: String
    let owner: Reference?
    /// False when the sensor is turned off in the Hue app.
    let enabled: Bool?
    let metadata: Metadata?
    let light: Light?
}

/// A response to `GET /clip/v2/resource/...`, or one event from the event stream.
/// Resources this app does not understand are skipped rather than failing the lot.
struct HueEnvelope: Decodable {
    let type: String?
    let resources: [HueResource]

    private enum CodingKeys: String, CodingKey {
        case type, data
    }

    private struct Lenient: Decodable {
        let resource: HueResource?
        init(from decoder: Decoder) throws {
            resource = try? HueResource(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        resources = try container.decode([Lenient].self, forKey: .data).compactMap(\.resource)
    }
}

enum Hue {
    /// The API reports light as 10000 × log10(lux) + 1.
    static func lux(fromLightLevel level: Int) -> Double {
        pow(10, Double(level - 1) / 10000)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Light sensors from the bridge's `light_level` and `device` resources,
    /// named after the device they belong to.
    static func sensors(bridgeID: String, lightLevels: [HueResource], devices: [HueResource]) -> [LightSensor] {
        let names = Dictionary(devices.map { ($0.id, $0.metadata?.name) }, uniquingKeysWith: { first, _ in first })
        return lightLevels.filter { $0.type == "light_level" }.map { resource in
            let report = resource.light?.light_level_report
            let problem = unavailable(resource)
            return LightSensor(id: sensorID(bridgeID: bridgeID, resource: resource.id),
                               name: resource.owner.flatMap { names[$0.rid] ?? nil } ?? "Hue light sensor",
                               lux: problem == nil ? report.map { lux(fromLightLevel: $0.light_level) } : nil,
                               updated: date(report?.changed),
                               unavailable: problem)
        }
    }

    /// Why a light_level resource has no usable reading, if it has none.
    static func unavailable(_ resource: HueResource) -> String? {
        if resource.enabled == false {
            return "turned off in the Hue app"
        }
        if resource.light?.light_level_valid == false {
            return "not reporting a valid light level"
        }
        return nil
    }

    static func sensorID(bridgeID: String, resource: String) -> String {
        "hue:\(bridgeID.lowercased()):\(resource)"
    }
}
