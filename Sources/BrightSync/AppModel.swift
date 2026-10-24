import AppKit
import ServiceManagement

/// What the menu and the Settings window show, and everything either can
/// change, so both stay in step. Main thread only.
final class AppModel: ObservableObject {
    /// What brightness follows.
    enum Source: Hashable {
        case mainDisplay
        case display(String)
        case sensor(String)
    }

    let engine: SyncEngine
    let ambient: AmbientController
    private var events: DisplayEvents?

    @Published private(set) var status = SyncStatus()
    @Published var settingsTab = SettingsView.Tab.brightness

    init(engine: SyncEngine = SyncEngine(gate: DisplayGate(conditions: HoldConditions.all())),
         providers: [LightSensorProvider] = AmbientController.defaultProviders()) {
        self.engine = engine
        ambient = AmbientController(engine: engine, providers: providers)
    }

    func start() {
        engine.onStatus = { [weak self] status in
            self?.status = status
            let seen = status.readings.map { (key: $0.key, name: $0.name) }
            if !seen.isEmpty, seen.map(\.key) != Preferences.knownDisplays.map(\.key) {
                Preferences.knownDisplays = seen
            }
        }
        ambient.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        Log.write("launch: BrightSync started; waiting \(Int(engine.gate.quietPeriod)) s before talking to displays")
        let events = DisplayEvents(gate: engine.gate, finishTransactions: { [engine] in
            engine.finishTransactions()
        }) { [weak self] event in
            self?.engine.schedule()
            if event == .systemDidWake {
                self?.ambient.refresh()
            }
            self?.objectWillChange.send()
        }
        events.start()
        self.events = events
        ambient.start()
        engine.schedule()
    }

    // MARK: - Settings

    var isEnabled: Bool {
        get { Preferences.isEnabled }
        set {
            objectWillChange.send()
            Preferences.isEnabled = newValue
            engine.syncNow()
        }
    }

    var source: Source {
        get {
            if let id = Preferences.sourceSensor { return .sensor(id) }
            if let key = Preferences.sourceDisplay { return .display(key) }
            return .mainDisplay
        }
        set {
            objectWillChange.send()
            switch newValue {
            case .mainDisplay:
                Preferences.sourceSensor = nil
                Preferences.sourceDisplay = nil
            case let .display(key):
                Preferences.sourceSensor = nil
                Preferences.sourceDisplay = key
            case let .sensor(id):
                Preferences.sourceSensor = id
            }
            ambient.update()
            engine.syncNow()
        }
    }

    var syncColor: Bool {
        get { Preferences.syncColorTemperature }
        set {
            objectWillChange.send()
            Preferences.syncColorTemperature = newValue
            engine.syncNow()
        }
    }

    /// The display whose colour preset the others copy; nil for the main display.
    var colorSource: String? {
        get { Preferences.colorSource }
        set {
            objectWillChange.send()
            Preferences.colorSource = newValue
            engine.syncNow()
        }
    }

    var smoothLight: Bool {
        get { Preferences.smoothLight }
        set {
            objectWillChange.send()
            Preferences.smoothLight = newValue
            ambient.update()
        }
    }

    /// "3.3 lux", or "3.3 lux now, 2.4 averaged" while smoothing catches up.
    var lightDescription: String? {
        guard let current = ambient.currentLux, let lux = ambient.lux else { return nil }
        if abs(lux - current) / current < 0.05 {
            return "\(HueBridge.format(current)) lux"
        }
        return "\(HueBridge.format(current)) lux now, \(HueBridge.format(lux)) averaged"
    }

    var pauseDuringCalls: Bool {
        get { Preferences.pauseDuringCalls }
        set {
            objectWillChange.send()
            Preferences.pauseDuringCalls = newValue
            engine.schedule()
        }
    }

    var interval: Int {
        get { Preferences.interval }
        set {
            objectWillChange.send()
            Preferences.interval = newValue
            engine.schedule()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not change the login item"
                alert.informativeText = "\(error.localizedDescription)\n\nYou can also set this in System Settings → General → Login Items."
                alert.runModal()
            }
        }
    }

    // MARK: - What to show

    var followsSensor: Bool {
        Preferences.sourceSensor != nil
    }

    /// The displays seen in the last round. Until the first round after a
    /// launch, the ones seen last time, so their sliders are there at once.
    var displays: [DisplayReading] {
        if !status.readings.isEmpty {
            return status.readings
        }
        return Preferences.knownDisplays.map {
            DisplayReading(key: $0.key, name: $0.name, percent: nil, colorPreset: nil, isSource: false)
        }
    }

    /// Why nothing is being sent right now, if that is the case.
    var pausedReason: String? {
        switch engine.gate.state {
        case let .held(reason), let .paused(reason): return "Paused: \(reason)"
        case let .settling(remaining): return "Waiting for displays to settle (\(Int(remaining.rounded(.up))) s)"
        case .open: return nil
        }
    }

    var offsets: BrightnessOffsets {
        ambient.offsets
    }

    /// Like a car's SYNC button: one slider for every monitor, or one each.
    var adjustTogether: Bool {
        get { offsets.together }
        set {
            objectWillChange.send()
            ambient.setTogether(newValue, displays: displays.map(\.key))
        }
    }

    /// The brightness a display ends up with, or the shared one for nil.
    func resultPercent(for display: String?) -> Int? {
        ambient.percent(for: display ?? "").map { Int($0.rounded()) }
    }

    var defaultPercent: Int? {
        ambient.defaultPercent.map { Int($0.rounded()) }
    }

    /// "Desk sensor · 38 lux", or why there is no reading.
    var lightCaption: String {
        if let sensor = ambient.selected, let lux = sensor.lux {
            return "\(sensor.name) · \(HueBridge.format(lux)) lux"
        }
        if let sensor = ambient.selected, let reason = sensor.unavailable {
            return "\(sensor.name) is \(reason)"
        }
        return ambient.problem ?? "Waiting for the light sensor…"
    }

    /// Why a change made now would not reach the monitors yet, briefly.
    var waitingNote: String? {
        switch engine.gate.state {
        case .open: return nil
        case let .settling(remaining): return "applies in \(Int(remaining.rounded(.up))) s"
        case let .held(reason), let .paused(reason): return "paused: \(reason)"
        }
    }

    /// True when the chosen sensor is not on offer, e.g. in another room.
    var sensorMissing: Bool {
        guard let id = Preferences.sourceSensor else { return false }
        return !ambient.sensors.contains { $0.id == id }
    }

    /// "Following DELL U3225QE (58%)", when brightness follows a display.
    var followingLine: String? {
        guard !followsSensor, let source = displays.first(where: \.isSource) else { return nil }
        return "Following \(source.name)" + (source.percent.map { " (\($0)%)" } ?? "")
    }

    func describe(_ display: DisplayReading) -> String {
        var text = display.percent.map { "\($0)%" } ?? "not read yet"
        if syncColor, let preset = display.colorPreset {
            text += " · \(ColorPreset.describe(preset))"
        }
        if display.isSource {
            text += " · source"
        }
        return text
    }

    // MARK: - Actions

    /// A slider: how many points brighter or dimmer than the default curve,
    /// for one display or, when adjusted together, all of them.
    func setOffset(_ offset: Double, display: String?, finished: Bool) {
        ambient.setOffset(offset, display: display, finished: finished)
        objectWillChange.send()
    }

    func resetOffsets() {
        ambient.resetOffsets()
        objectWillChange.send()
    }

    func syncNow() {
        engine.syncNow()
    }

    /// For rendering Settings with made-up displays; see `--snapshot-settings`.
    func show(_ status: SyncStatus) {
        self.status = status
    }

    func revealLog() {
        NSWorkspace.shared.selectFile(Log.path, inFileViewerRootedAtPath: "")
    }
}
