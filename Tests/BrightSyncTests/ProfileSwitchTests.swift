import Foundation
import DDCKit
import Testing
@testable import BrightSync

/// Fixed sensors, by ID and lux.
private final class FakeSensors: LightSensorProvider {
    let name = "Fake"
    var sensors: [LightSensor]
    let problem: String? = nil
    let activity: String? = nil
    let isSetUp = true
    var onChange: (() -> Void)?

    init(_ readings: [(id: String, lux: Double)]) {
        sensors = readings.map { LightSensor(id: $0.id, name: $0.id, lux: $0.lux, updated: Date()) }
    }

    func start() {}
    func refresh() {}
    func addSensors() {}
}

/// The whole path together, on real queues and timers: the engine notices the
/// monitors changed, the model swaps the settings on the main queue, and only
/// then is anything written. Preferences are process-wide, hence serialized.
/// A test process has its own defaults, never the app's.
@Suite(.serialized) struct ProfileSwitchTests {
    let queue = DispatchQueue(label: "test.ddc")
    let bus = FakeBus("Dell", "Lenovo", "LG")
    let gate = DisplayGate(quietPeriod: 0.02)
    let dellAndLenovo: [FakeBus.Panel]
    let lg: [FakeBus.Panel]
    let engine: SyncEngine
    let model: AppModel

    /// 100 lux gives 60% on the default curve and 10 lux gives 35%.
    init() {
        #expect(Bundle.main.bundleIdentifier != "app.brightsync.BrightSync")
        Preferences.profileBook = ProfileBook()
        Preferences.roomSettings = ProfileSettings(smoothLight: false, rampBrightness: false)
        dellAndLenovo = Array(bus.panels[0...1])
        lg = [bus.panels[2]]
        bus.panels = dellAndLenovo
        // Ramps run fast here; the ramp's own pace has its tests with a fake clock.
        engine = SyncEngine(bus: bus, gate: gate, queue: queue,
                            settings: {
                                var settings = SyncSettings.current
                                settings.rampInterval = settings.rampInterval.map { _ in 0.05 }
                                return settings
                            },
                            ranges: [:], saveRanges: { _ in }, log: { _ in })
        model = AppModel(engine: engine, providers: [FakeSensors([("desk", 100), ("bedside", 10)])], log: { _ in })
    }

    /// What the displays have been sent, read on the queue that sends it.
    func writes() -> [String] {
        queue.sync { bus.transactions.filter { $0.hasPrefix("write") } }
    }

    func start() async {
        await MainActor.run {
            model.ambient.start()
            engine.schedule()
        }
    }

    func move(to panels: [FakeBus.Panel]) {
        queue.sync {
            bus.panels = panels
            bus.reset()
        }
        gate.record(.reconfigured)
        engine.schedule()
    }

    func choose(_ source: AppModel.Source) async {
        await MainActor.run { model.source = source }
    }

    /// Waits for a condition, on the main queue since that is where the model lives.
    func wait(_ what: Comment, until condition: @escaping () -> Bool) async {
        for _ in 0..<500 {
            if await MainActor.run(body: condition) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record(what)
    }

    @Test func eachCombinationOfMonitorsGetsItsOwnSensorBack() async {
        await start()
        await wait("first profile") { model.profileName == "Dell + Lenovo" }
        await choose(.sensor("desk"))
        await wait("desk target") { writes().contains("write Dell \(DDCKIT_VCP_BRIGHTNESS)=60") }

        // A new room: the desk sensor stays behind, and nothing is written.
        move(to: lg)
        await wait("new profile") { model.profileName == "LG" }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run { #expect(model.source == .mainDisplay) }
        #expect(writes() == [], "nothing reached the new room's monitor")
        await choose(.sensor("bedside"))
        await wait("bedside target") { writes() == ["write LG \(DDCKIT_VCP_BRIGHTNESS)=35"] }

        // Back at the desk: its own sensor, and not one write of the bedside's value.
        move(to: dellAndLenovo)
        await wait("desk profile") { model.profileName == "Dell + Lenovo" }
        await wait("desk target again") { writes().count == 2 }
        await MainActor.run { #expect(model.source == .sensor("desk")) }
        #expect(writes() == ["write Dell \(DDCKIT_VCP_BRIGHTNESS)=60", "write Lenovo \(DDCKIT_VCP_BRIGHTNESS)=60"])

        // And the bedroom again.
        move(to: lg)
        await wait("bedroom profile") { model.profileName == "LG" }
        await wait("bedside target again") { !writes().isEmpty }
        await MainActor.run { #expect(model.source == .sensor("bedside")) }
        #expect(writes() == ["write LG \(DDCKIT_VCP_BRIGHTNESS)=35"])
        #expect(Preferences.profileBook.names == ["Dell + Lenovo", "LG"])
    }

    @Test func aRampRunsByItselfOnTheEnginesOwnTimer() async {
        Preferences.rampBrightness = true
        await start()
        await wait("first profile") { model.profileName == "Dell + Lenovo" }
        let started = DispatchTime.now()
        await choose(.sensor("desk")) // 50 to 60, nothing else calling the engine
        await wait("ramp arrives") { writes().contains("write Dell \(DDCKIT_VCP_BRIGHTNESS)=60") }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        let dell = writes().filter { $0.hasPrefix("write Dell") }
        #expect(dell == (51...60).map { "write Dell \(DDCKIT_VCP_BRIGHTNESS)=\($0)" }, "every step, in order")
        #expect(seconds >= 9 * 0.05, "at the ramp's pace, not faster")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes().filter { $0.hasPrefix("write Dell") }.count == 10, "and then it stops")
    }

    /// Sensors only report changes, so the hold has to end with no new reading.
    @Test func aLastingChangeIsFollowedWithNothingNewArriving() {
        Preferences.sourceSensor = "desk"
        Preferences.smoothLight = true
        let clock = FakeClock()
        let sensors = FakeSensors([("desk", 1)])
        var logged: [String] = []
        let ambient = AmbientController(engine: engine, providers: [sensors], now: { clock.time }, log: { logged.append($0) })
        ambient.update()
        sensors.sensors[0].lux = 100
        clock.advance(1)
        ambient.update()
        #expect(ambient.lux! < 2, "one reading moves nothing")
        clock.advance(59)
        ambient.update()
        #expect(ambient.lux! < 4)
        clock.advance(1)
        ambient.update()
        #expect(ambient.lux! > 95, "and at a minute, it applies")
        #expect(logged.contains { $0.contains("and stayed; following at once") })
    }

    @Test func rampingIsOnByDefaultAtOnePercentEveryTenSeconds() {
        UserDefaults.standard.removeObject(forKey: "rampBrightness")
        UserDefaults.standard.removeObject(forKey: "rampSeconds")
        #expect(SyncSettings.current.rampInterval == 10)
        Preferences.rampSeconds = 3
        #expect(SyncSettings.current.rampInterval == 3)
        Preferences.rampBrightness = false
        #expect(SyncSettings.current.rampInterval == nil)
    }

    /// Twice, with every value different, so a setting that is never saved or
    /// loaded cannot pass by already holding the right value.
    @Test func everyRoomSettingIsSavedAndLoaded() {
        let first = ProfileSettings(sourceDisplay: "a", sourceSensor: "b", colorSource: "c", isEnabled: false,
                                    syncColor: true, interval: 60, offsetsTogether: false, sharedOffset: 7,
                                    displayOffsets: ["a": -3], smoothLight: true, rampBrightness: true, rampSeconds: 20)
        let second = ProfileSettings(sourceDisplay: "d", sourceSensor: "e", colorSource: "f", isEnabled: true,
                                     syncColor: false, interval: 120, offsetsTogether: true, sharedOffset: -4,
                                     displayOffsets: ["d": 9], smoothLight: false, rampBrightness: false, rampSeconds: 5)
        for settings in [first, second, first] {
            Preferences.roomSettings = settings
            #expect(Preferences.roomSettings == settings)
        }
        #expect(SyncSettings.current.isEnabled == false)
        #expect(SyncSettings.current.followsSensor)
        #expect(SyncSettings.current.interval == 60)
    }
}
