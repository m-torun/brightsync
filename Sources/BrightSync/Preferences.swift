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
        static let pauseDuringCalls = "pauseDuringCalls"
        static let displayRanges = "displayBrightnessRanges"
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

    /// Each display's brightness maximum, learned from its first good read.
    static var displayRanges: [String: Int] {
        get { defaults.dictionary(forKey: Key.displayRanges) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Key.displayRanges) }
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
