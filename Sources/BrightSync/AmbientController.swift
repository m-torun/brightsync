import Foundation

/// Turns the chosen light sensor's readings into a brightness target for each
/// display: the default curve for the light, moved by the user's offset.
final class AmbientController {
    /// Every kind of sensor on offer. A new kind is added here.
    static func defaultProviders() -> [LightSensorProvider] {
        [HueProvider()]
    }

    let providers: [LightSensorProvider]
    /// Called on the main queue when sensors or readings change.
    var onChange: (() -> Void)?

    private let engine: SyncEngine
    private let log: (String) -> Void
    private var lastLogged: String?

    init(engine: SyncEngine, providers: [LightSensorProvider] = AmbientController.defaultProviders(),
         log: @escaping (String) -> Void = Log.write) {
        self.engine = engine
        self.providers = providers
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

    var lux: Double? {
        selected?.lux
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
        guard Preferences.sourceSensor != nil, let lux else {
            lastLogged = nil
            engine.setAmbientTarget(nil)
            onChange?()
            return
        }
        let offsets = self.offsets
        let target = AmbientTarget(percent: offsets.percent(for: "", at: lux),
                                   perDisplay: offsets.together ? [:] : offsets.perDisplay.mapValues { min(max(AmbientCurve.percent(at: lux) + $0, 0), 100) },
                                   exact: exact)
        let summary = "\(HueBridge.format(lux)) lux → \(Int(AmbientCurve.percent(at: lux).rounded()))%" + describe(offsets)
        if !exact, summary != lastLogged {
            log("ambient: \(summary)")
            lastLogged = summary
        }
        engine.setAmbientTarget(target)
        onChange?()
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
