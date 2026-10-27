import Foundation

/// Turns the chosen light sensor's readings into a brightness target for each
/// display: the default curve for the light, moved by the user's offset.
final class AmbientController {
    /// Every kind of sensor on offer. A new kind is added here.
    static func defaultProviders() -> [LightSensorProvider] {
        [HueProvider(), Zigbee2MQTTProvider()]
    }

    let providers: [LightSensorProvider]
    /// Called on the main queue when sensors or readings change.
    var onChange: (() -> Void)?

    private let engine: SyncEngine
    private let log: (String) -> Void
    private let now: () -> TimeInterval
    private var lastLogged: String?

    private var smoother = LightSmoother()
    /// The sensor and reading last given to the smoother, to add each once.
    private var smoothedSensor: String?
    private var lastReading: (lux: Double, updated: Date?)?
    /// Runs while the average is still catching up with the light.
    private var catchUp: Timer?

    init(engine: SyncEngine, providers: [LightSensorProvider] = AmbientController.defaultProviders(),
         now: @escaping () -> TimeInterval = DisplayGate.uptime,
         log: @escaping (String) -> Void = Log.write) {
        self.engine = engine
        self.providers = providers
        self.now = now
        self.log = log
    }

    func start() {
        for provider in providers {
            provider.onChange = { [weak self] in self?.update() }
            provider.start()
        }
        update()
    }

    /// Reconnects every provider, e.g. after the Mac wakes.
    func refresh() {
        providers.forEach { $0.refresh() }
    }

    struct Choice: Identifiable {
        let sensor: LightSensor
        let provider: String
        var id: String { sensor.id }
    }

    /// Every sensor on offer, from every provider.
    var sensors: [Choice] {
        providers.flatMap { provider in provider.sensors.map { Choice(sensor: $0, provider: provider.name) } }
    }

    var problem: String? {
        providers.compactMap(\.problem).first
    }

    var selected: LightSensor? {
        guard let id = Preferences.sourceSensor else { return nil }
        return providers.lazy.flatMap(\.sensors).first { $0.id == id }
    }

    /// The latest reading.
    var currentLux: Double? {
        selected?.lux
    }

    /// The light brightness follows: averaged when smoothing is on.
    var lux: Double? {
        guard let current = currentLux else { return nil }
        return Preferences.smoothLight ? smoother.lux(at: now()) ?? current : current
    }

    /// What the default curve gives at the current light, before any offset.
    var defaultPercent: Double? {
        lux.map(AmbientCurve.percent(at:))
    }

    var offsets: BrightnessOffsets {
        Preferences.offsets
    }

    /// What a display gets at the current light, offset included.
    func percent(for display: String) -> Double? {
        lux.map { offsets.percent(for: display, at: $0) }
    }

    /// Recomputes the targets after a reading or a settings change.
    func update(exact: Bool = false) {
        smooth()
        guard Preferences.sourceSensor != nil, let lux, let current = currentLux else {
            lastLogged = nil
            engine.setAmbientTarget(nil)
            onChange?()
            return
        }
        let offsets = self.offsets
        let target = AmbientTarget(percent: offsets.percent(for: "", at: lux),
                                   perDisplay: offsets.together ? [:] : offsets.perDisplay.mapValues { min(max(AmbientCurve.percent(at: lux) + $0, 0), 100) },
                                   exact: exact)
        let light = abs(lux - current) / current < 0.05 ? "\(HueBridge.format(current)) lux"
            : "\(HueBridge.format(current)) lux (averaging \(HueBridge.format(lux)))"
        let summary = "\(light) → \(Int(AmbientCurve.percent(at: lux).rounded()))%" + describe(offsets)
        // Log when the brightness changes, not every step of the average.
        let logKey = summary.components(separatedBy: " → ").last
        if !exact, logKey != lastLogged {
            log("ambient: \(summary)")
            lastLogged = logKey
        }
        engine.setAmbientTarget(target)
        onChange?()
    }

    /// Feeds each new reading to the smoother once, and keeps recomputing
    /// while the average catches up.
    private func smooth() {
        guard let sensor = selected, let current = sensor.lux else {
            // No reading (turned off, unreachable): start afresh when one
            // comes back, rather than count the old one as having held.
            catchUp?.invalidate()
            catchUp = nil
            smoother.reset()
            lastReading = nil
            return
        }
        if sensor.id != smoothedSensor {
            smoother.reset()
            smoothedSensor = sensor.id
            lastReading = nil
        }
        if lastReading?.lux != current || lastReading?.updated != sensor.updated {
            let before = smoother.lux(at: now())
            if smoother.add(lux: current, at: now()), Preferences.smoothLight, let before {
                log("ambient: light jumped from \(HueBridge.format(before)) to \(HueBridge.format(current)) lux; following at once")
            }
            lastReading = (current, sensor.updated)
        }
        let settled = !Preferences.smoothLight || smoother.isSettled(at: now())
        if settled {
            catchUp?.invalidate()
            catchUp = nil
        } else if catchUp == nil {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.update() }
            RunLoop.main.add(timer, forMode: .common)
            catchUp = timer
        }
    }

    /// A slider: moves one display, or every display when they are adjusted
    /// together, by `offset` points from the default curve.
    func setOffset(_ offset: Double, display: String?, finished: Bool) {
        var offsets = self.offsets
        if let display, !offsets.together {
            offsets.perDisplay[display] = offset
        } else {
            offsets.shared = offset
        }
        Preferences.offsets = offsets
        update(exact: true)
        if finished {
            log("offset: \(describe(offsets).isEmpty ? "none" : String(describe(offsets).dropFirst(1)))")
        }
    }

    func setTogether(_ together: Bool, displays: [String]) {
        var offsets = self.offsets
        offsets.setTogether(together, displays: displays)
        Preferences.offsets = offsets
        log("offset: monitors adjusted \(together ? "together" : "separately")")
        update(exact: true)
    }

    /// Back to the default curve for every monitor.
    func resetOffsets() {
        var offsets = self.offsets
        offsets.shared = 0
        offsets.perDisplay = [:]
        Preferences.offsets = offsets
        log("offset: reset to the default curve")
        update(exact: true)
    }

    private func describe(_ offsets: BrightnessOffsets) -> String {
        if offsets.together {
            return offsets.shared == 0 ? "" : " \(Self.signed(offsets.shared)) for all"
        }
        let parts = offsets.perDisplay.sorted { $0.key < $1.key }.map { "\(Self.signed($0.value))" }
        return parts.isEmpty ? "" : " " + parts.joined(separator: "/") + " per monitor"
    }

    static func signed(_ value: Double) -> String {
        let points = Int(value.rounded())
        return points > 0 ? "+\(points)" : points == 0 ? "±0" : "\(points)"
    }
}
