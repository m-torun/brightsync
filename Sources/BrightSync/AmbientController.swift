import Foundation

/// Turns the chosen light sensor's readings into a brightness target for the
/// engine, through the user's curve for that sensor.
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
    private var lastTarget: Int?

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

    var curve: AmbientCurve {
        Preferences.sourceSensor.flatMap { Preferences.curves[$0] } ?? AmbientCurve()
    }

    /// The brightness the curve asks for at the current reading.
    var target: Double? {
        selected?.lux.map { curve.percent(at: $0) }
    }

    /// Recomputes the target after a reading or a settings change.
    func update() {
        if Preferences.sourceSensor != nil, let target, let lux = selected?.lux {
            let rounded = Int(target.rounded())
            if rounded != lastTarget {
                log("ambient: \(HueBridge.format(lux)) lux → \(rounded)%")
                lastTarget = rounded
            }
            engine.setAmbientTarget(target)
        } else {
            lastTarget = nil
            engine.setAmbientTarget(nil)
        }
        onChange?()
    }

    /// The slider: the curve now passes through `percent` at the current
    /// light, and the displays follow straight away.
    func setBrightness(_ percent: Double, finished: Bool) {
        guard let id = Preferences.sourceSensor, let lux = selected?.lux else { return }
        var curve = self.curve
        curve.set(percent, at: lux)
        var curves = Preferences.curves
        curves[id] = curve
        Preferences.curves = curves
        lastTarget = Int(percent.rounded())
        engine.setAmbientTarget(percent, exact: true)
        if finished {
            let points = curve.points.map { "\(Int($0.percent.rounded()))% at \(HueBridge.format($0.lux)) lux" }
            log("curve: \(points.joined(separator: ", "))")
        }
    }

    func resetCurve() {
        guard let id = Preferences.sourceSensor else { return }
        var curves = Preferences.curves
        curves[id] = nil
        Preferences.curves = curves
        log("curve: reset to the default")
        update()
    }
}
