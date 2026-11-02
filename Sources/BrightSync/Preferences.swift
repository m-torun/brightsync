import Foundation

/// Settings live in this user's own defaults, never in the repository.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let sourceDisplay = "sourceDisplayKey"
        static let interval = "intervalSeconds"
        static let enabled = "syncEnabled"
        static let deadband = "deadband"
        static let syncColor = "syncColorTemperature"
        static let colorSource = "colorSourceKey"
        static let sourceSensor = "sourceSensorID"
        static let offsetsTogether = "adjustMonitorsTogether"
        static let sharedOffset = "brightnessOffset"
        static let displayOffsets = "displayBrightnessOffsets"
        static let hueHosts = "hueBridgeHosts"
        static let zigbee2mqttServers = "zigbee2mqttServers"
        static let pauseDuringCalls = "pauseDuringCalls"
        static let displayRanges = "displayBrightnessRanges"
        static let knownDisplays = "knownDisplays"
        static let smoothLight = "smoothLight"
        static let rampBrightness = "rampBrightness"
        static let rampSeconds = "rampSeconds"
        static let profileBook = "roomProfiles"
    }

    /// How often the source display is read. Every read goes through the
    /// display coprocessor, so the floor is deliberately not lower.
    static let intervalChoices = [10, 30, 60, 120]

    /// Identity of the display whose brightness the others follow. Nil means
    /// "whichever display macOS considers the main one".
    static var sourceDisplay: String? {
        get { defaults.string(forKey: Key.sourceDisplay) }
        set { defaults.set(newValue, forKey: Key.sourceDisplay) }
    }

    /// The light sensor brightness follows. When set, it takes precedence
    /// over the source display.
    static var sourceSensor: String? {
        get { defaults.string(forKey: Key.sourceSensor) }
        set { defaults.set(newValue, forKey: Key.sourceSensor) }
    }

    /// How far brightness is moved from the default curve: one offset for
    /// every monitor, or one each.
    static var offsets: BrightnessOffsets {
        get {
            BrightnessOffsets(together: defaults.object(forKey: Key.offsetsTogether) as? Bool ?? true,
                              shared: defaults.double(forKey: Key.sharedOffset),
                              perDisplay: defaults.dictionary(forKey: Key.displayOffsets) as? [String: Double] ?? [:])
        }
        set {
            defaults.set(newValue.together, forKey: Key.offsetsTogether)
            defaults.set(newValue.shared, forKey: Key.sharedOffset)
            defaults.set(newValue.perDisplay, forKey: Key.displayOffsets)
        }
    }

    /// Last known address of each paired Hue bridge, by bridge ID, so that
    /// connecting does not wait for Bonjour. The keys themselves are in the Keychain.
    static func hueHost(for bridgeID: String) -> String? {
        (defaults.dictionary(forKey: Key.hueHosts) as? [String: String])?[bridgeID.lowercased()]
    }

    static func setHueHost(_ host: String, for bridgeID: String) {
        var hosts = defaults.dictionary(forKey: Key.hueHosts) as? [String: String] ?? [:]
        hosts[bridgeID.lowercased()] = host
        defaults.set(hosts, forKey: Key.hueHosts)
    }

    /// Addresses of the Zigbee2MQTT web interfaces added under Sensors, as typed.
    static var zigbee2mqttServers: [String] {
        get { defaults.stringArray(forKey: Key.zigbee2mqttServers) ?? [] }
        set { defaults.set(newValue, forKey: Key.zigbee2mqttServers) }
    }

    static var interval: Int {
        get { max(intervalChoices[0], defaults.object(forKey: Key.interval) as? Int ?? 30) }
        set { defaults.set(newValue, forKey: Key.interval) }
    }

    static var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Copies the colour preset (VCP 0x14) from `colorSource` to the other
    /// displays. Off by default: preset numbering is only nominally standard,
    /// so two vendors may disagree about what a given preset means.
    static var syncColorTemperature: Bool {
        get { defaults.bool(forKey: Key.syncColor) }
        set { defaults.set(newValue, forKey: Key.syncColor) }
    }

    /// The display whose colour preset the others copy, independent of what
    /// brightness follows. Nil means the main display; before this setting
    /// existed, colour came from the brightness source display.
    static var colorSource: String? {
        get { defaults.string(forKey: Key.colorSource) ?? sourceDisplay }
        set { defaults.set(newValue, forKey: Key.colorSource) }
    }

    /// The displays seen last, as (key, name), so their sliders can be shown
    /// before BrightSync has reached them after a launch.
    static var knownDisplays: [(key: String, name: String)] {
        get {
            (defaults.array(forKey: Key.knownDisplays) as? [[String]] ?? []).compactMap { pair in
                pair.count == 2 ? (pair[0], pair[1]) : nil
            }
        }
        set { defaults.set(newValue.map { [$0.key, $0.name] }, forKey: Key.knownDisplays) }
    }

    /// Each display's brightness maximum, learned from its first good read.
    static var displayRanges: [String: Int] {
        get { defaults.dictionary(forKey: Key.displayRanges) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Key.displayRanges) }
    }

    /// Follow the light averaged over 5 minutes, with big changes at once.
    /// On by default.
    static var smoothLight: Bool {
        get { defaults.object(forKey: Key.smoothLight) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.smoothLight) }
    }

    /// Seconds per 1% step on offer. Every step is a DDC write, so the floor
    /// is deliberately not lower.
    static let rampChoices = [3, 5, 10, 20, 30]

    /// Move brightness towards a sensor's target in 1% steps. On by default.
    static var rampBrightness: Bool {
        get { defaults.object(forKey: Key.rampBrightness) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.rampBrightness) }
    }

    static var rampSeconds: Int {
        get { max(rampChoices[0], defaults.object(forKey: Key.rampSeconds) as? Int ?? 10) }
        set { defaults.set(newValue, forKey: Key.rampSeconds) }
    }

    /// The settings remembered for each combination of monitors.
    static var profileBook: ProfileBook {
        get {
            defaults.data(forKey: Key.profileBook).flatMap { try? JSONDecoder().decode(ProfileBook.self, from: $0) } ?? ProfileBook()
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.profileBook) }
    }

    /// The settings in use now, which belong to the active profile. They stay
    /// in their own keys, and are copied to and from a profile on a switch.
    static var roomSettings: ProfileSettings {
        get {
            let offsets = self.offsets
            return ProfileSettings(sourceDisplay: sourceDisplay, sourceSensor: sourceSensor, colorSource: colorSource,
                                   isEnabled: isEnabled, syncColor: syncColorTemperature, interval: interval,
                                   offsetsTogether: offsets.together, sharedOffset: offsets.shared, displayOffsets: offsets.perDisplay,
                                   smoothLight: smoothLight, rampBrightness: rampBrightness, rampSeconds: rampSeconds)
        }
        set {
            sourceDisplay = newValue.sourceDisplay
            sourceSensor = newValue.sourceSensor
            colorSource = newValue.colorSource
            isEnabled = newValue.isEnabled
            syncColorTemperature = newValue.syncColor
            interval = newValue.interval
            offsets = BrightnessOffsets(together: newValue.offsetsTogether, shared: newValue.sharedOffset, perDisplay: newValue.displayOffsets)
            smoothLight = newValue.smoothLight
            rampBrightness = newValue.rampBrightness
            rampSeconds = newValue.rampSeconds
        }
    }

    /// Send nothing while any app uses the camera or microphone. On by default.
    static var pauseDuringCalls: Bool {
        get { defaults.object(forKey: Key.pauseDuringCalls) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.pauseDuringCalls) }
    }

    /// Ignore differences at or below this many points, so that rounding
    /// between panels with different ranges does not cause constant writes.
    static var deadband: Int {
        get { defaults.object(forKey: Key.deadband) as? Int ?? 1 }
        set { defaults.set(newValue, forKey: Key.deadband) }
    }
}
