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

    /// The displays seen in the last round.
    var displays: [DisplayReading] {
        status.readings
    }

    /// Why nothing is being sent right now, if that is the case.
    var pausedReason: String? {
        switch engine.gate.state {
        case let .held(reason), let .paused(reason): return "Paused: \(reason)"
        case let .settling(remaining): return "Waiting for displays to settle (\(Int(remaining.rounded(.up))) s)"
        case .open: return nil
        }
    }

    /// The brightness the curve asks for at the current light.
    var brightness: Double? {
        ambient.target
    }

    var sensorCaption: String {
        if let sensor = ambient.selected, let lux = sensor.lux {
            return "\(sensor.name) reads \(HueBridge.format(lux)) lux"
        }
        return ambient.problem ?? "Waiting for the light sensor…"
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

    /// The slider: pins the curve to `percent` at the current light.
    func setBrightness(_ percent: Double, finished: Bool) {
        ambient.setBrightness(percent, finished: finished)
        objectWillChange.send()
    }

    func resetCurve() {
        ambient.resetCurve()
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
