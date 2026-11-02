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

struct Profile: Codable, Equatable {
    var name: String
    var settings: ProfileSettings
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
    mutating func arrive(at displays: [Display], with live: ProfileSettings) -> Arrival? {
        guard !displays.isEmpty else { return nil }
        let keys = displays.map(\.key).sorted()
        let key = keys.joined(separator: "+")
        let name = displays.map(\.name).sorted().joined(separator: " + ")
        guard let from = activeKey else {
            // The first run with profiles: what is set now is for these monitors.
            profiles[key] = Profile(name: name, settings: live)
            activeKey = key
            return nil
        }
        guard key != from else {
            profiles[key]?.name = name
            profiles[key]?.settings = live
            return nil
        }
        profiles[from]?.settings = live
        activeKey = key
        if var known = profiles[key] {
            known.name = name
            profiles[key] = known
            return Arrival(settings: known.settings, isNew: false)
        }
        // Sharing a monitor suggests the same room with one monitor switched
        // away, so its sensor still applies. Otherwise this is a new room: the
        // last room's sensor would be measuring the wrong light, so brightness
        // follows nothing until one is chosen here.
        var settings = live
        if !from.split(separator: "+").map(String.init).contains(where: keys.contains) {
            settings.sourceDisplay = nil
            settings.sourceSensor = nil
            settings.colorSource = nil
            settings.displayOffsets = [:]
        }
        profiles[key] = Profile(name: name, settings: settings)
        return Arrival(settings: settings, isNew: true)
    }
}
