import Foundation

/// The settings that belong to a room rather than to the Mac. Sensors added,
/// display ranges and Pause during calls apply everywhere and are not here.
struct ProfileSettings: Codable, Equatable {
    var sourceDisplay: String?
    var sourceSensor: String?
    var colorSource: String?
    var isEnabled = true
    var syncColor = false
    var interval = 30
    var offsetsTogether = true
    var sharedOffset = 0.0
    var displayOffsets: [String: Double] = [:]
    var smoothLight = true
    var rampBrightness = true
    var rampSeconds = 10
}

extension ProfileSettings {
    /// A setting added in a later version takes its default, rather than the
    /// whole saved book failing to decode and every profile being lost.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let standard = ProfileSettings()
        sourceDisplay = try saved.decodeIfPresent(String.self, forKey: .sourceDisplay)
        sourceSensor = try saved.decodeIfPresent(String.self, forKey: .sourceSensor)
        colorSource = try saved.decodeIfPresent(String.self, forKey: .colorSource)
        isEnabled = try saved.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? standard.isEnabled
        syncColor = try saved.decodeIfPresent(Bool.self, forKey: .syncColor) ?? standard.syncColor
        interval = try saved.decodeIfPresent(Int.self, forKey: .interval) ?? standard.interval
        offsetsTogether = try saved.decodeIfPresent(Bool.self, forKey: .offsetsTogether) ?? standard.offsetsTogether
        sharedOffset = try saved.decodeIfPresent(Double.self, forKey: .sharedOffset) ?? standard.sharedOffset
        displayOffsets = try saved.decodeIfPresent([String: Double].self, forKey: .displayOffsets) ?? standard.displayOffsets
        smoothLight = try saved.decodeIfPresent(Bool.self, forKey: .smoothLight) ?? standard.smoothLight
        rampBrightness = try saved.decodeIfPresent(Bool.self, forKey: .rampBrightness) ?? standard.rampBrightness
        rampSeconds = try saved.decodeIfPresent(Int.self, forKey: .rampSeconds) ?? standard.rampSeconds
    }
}

struct Profile: Codable, Equatable {
    /// The monitors' product names, sorted.
    var monitors: [String]
    var settings: ProfileSettings

    var name: String {
        monitors.joined(separator: " + ")
    }
}

/// One profile per combination of monitors, found and named by those monitors.
struct ProfileBook: Codable, Equatable {
    /// What a move to another combination of monitors asks to be loaded.
    struct Arrival: Equatable {
        let settings: ProfileSettings
        let isNew: Bool
    }

    private(set) var activeKey: String?
    private var profiles: [String: Profile] = [:]

    var activeName: String? {
        activeKey.flatMap { profiles[$0]?.name }
    }

    var names: [String] {
        Set(profiles.values.map(\.name)).sorted()
    }

    func settings(named name: String) -> ProfileSettings? {
        profiles.values.first { $0.name == name }?.settings
    }

    /// Call when the connected monitors settle, with the settings in use.
    /// Returns what to load, or nil when the settings in use stay as they are.
    /// No monitors at all says nothing about the room (they may just be
    /// showing another input), so the active profile stays.
    ///
    /// Profiles are found by EDID, which tells two units of a model apart. But
    /// one monitor reports a different EDID on each input, so names decide what
    /// a first-time combination starts from.
    mutating func arrive(at displays: [Display], with live: ProfileSettings) -> Arrival? {
        guard !displays.isEmpty else { return nil }
        let key = displays.map(\.key).sorted().joined(separator: "+")
        let monitors = displays.map(\.name).sorted()
        guard let from = activeKey else {
            // The first run with profiles: what is set now is for these monitors.
            profiles[key] = Profile(monitors: monitors, settings: live)
            activeKey = key
            return nil
        }
        guard key != from else { return nil }
        profiles[from]?.settings = live
        let left = profiles[from]?.monitors ?? []
        activeKey = key
        if let known = profiles[key] {
            return Arrival(settings: known.settings, isNew: false)
        }
        var settings = live
        if let same = profiles.keys.sorted().compactMap({ profiles[$0] }).first(where: { $0.monitors == monitors }) {
            // These monitors by another cable or input.
            settings = same.settings
        } else if !left.contains(where: monitors.contains) {
            // Nothing in common with the room just left, so this is a new one:
            // that room's sensor would measure the wrong light, and brightness
            // follows nothing until one is chosen here. Sharing a monitor
            // suggests the same room with one switched away, so it keeps the sensor.
            settings.sourceDisplay = nil
            settings.sourceSensor = nil
            settings.colorSource = nil
            settings.displayOffsets = [:]
        }
        profiles[key] = Profile(monitors: monitors, settings: settings)
        return Arrival(settings: settings, isNew: true)
    }
}
