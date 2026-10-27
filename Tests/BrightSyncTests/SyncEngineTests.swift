import Foundation
import DDCKit
import Testing
@testable import BrightSync

/// Each test asserts on the exact DDC transactions sent, since sending as
/// few as possible is the point.
final class SyncEngineTests {
    let clock = FakeClock()
    let bus = FakeBus("Dell", "Lenovo")
    var settings = SyncSettings(sourceKey: "uuid-Dell", interval: 30)
    var logged: [String] = []
    let gate: DisplayGate
    var engine: SyncEngine!

    /// Each test gets a fresh instance; the app counts as launched here.
    /// A condition the tests can switch, standing in for a call.
    let call = Flag()

    init() {
        gate = DisplayGate(quietPeriod: 60, now: { [clock] in clock.time },
                           conditions: [{ [call] in call.isOn ? "camera or microphone in use" : nil }])
        engine = SyncEngine(bus: bus, gate: gate,
                            now: { [clock] in clock.time },
                            settings: { [unowned self] in self.settings },
                            ranges: [:], saveRanges: { _ in },
                            log: { [unowned self] in self.logged.append($0) })
    }

    let brightness = DDCKIT_VCP_BRIGHTNESS
    let preset = DDCKIT_VCP_COLOR_PRESET

    /// Lets the launch quiet period pass and runs the first round.
    func settleAndSync() {
        clock.advance(60)
        engine.tick()
    }

    @Test func nothingIsSentBeforeTheLaunchQuietPeriodEnds() {
        engine.tick()
        clock.advance(59)
        engine.tick()
        #expect(bus.transactions.isEmpty)
        #expect(engine.nextDelay()! > 0.9 && engine.nextDelay()! < 1.2)
    }

    @Test func firstRoundReadsBothThenWritesTheTarget() {
        bus["Dell"].brightness = (70, 100)
        bus["Lenovo"].brightness = (20, 100)
        settleAndSync()
        #expect(bus.transactions == ["read Dell \(brightness)", "read Lenovo \(brightness)", "write Lenovo \(brightness)=70"])
    }

    @Test func steadyStateReadsOnlyTheSource() {
        settleAndSync()
        bus.reset()
        for _ in 0..<120 { // an hour at 30 s
            clock.advance(30)
            engine.tick()
        }
        #expect(bus.transactions == Array(repeating: "read Dell \(brightness)", count: 120))
    }

    @Test func aSourceChangeIsWrittenOnceWithoutReadingTheTargetAgain() {
        settleAndSync()
        bus.reset()
        bus["Dell"].brightness = (80, 100)
        engine.tick()
        engine.tick()
        #expect(bus.transactions == ["read Dell \(brightness)", "write Lenovo \(brightness)=80", "read Dell \(brightness)"])
    }

    @Test func brightnessIsMirroredAsAProportion() {
        bus["Dell"].brightness = (50, 100)
        bus["Lenovo"].brightness = (10, 200)
        settleAndSync()
        #expect(bus.transactions.last == "write Lenovo \(brightness)=100")
    }

    @Test func smallDifferencesAreLeftAlone() {
        bus["Dell"].brightness = (50, 100)
        bus["Lenovo"].brightness = (51, 100)
        settleAndSync()
        #expect(!bus.transactions.contains { $0.hasPrefix("write") })
    }

    @Test func nothingIsSentWithASingleDisplay() {
        bus.panels.removeLast()
        settleAndSync()
        engine.tick()
        #expect(bus.transactions.isEmpty)
        #expect(engine.lastStatus.message == "Only one display: nothing to sync")
    }

    @Test func nothingIsSentWhenSyncIsOff() {
        settings.isEnabled = false
        settleAndSync()
        #expect(bus.transactions.isEmpty)
    }

    @Test func nothingIsSentWhileDisplaysSleepNorUntilTheyHaveSettled() {
        settleAndSync()
        bus.reset()
        gate.record(.screensSlept)
        clock.advance(3_600)
        engine.tick()
        #expect(engine.nextDelay() == nil, "no timer runs while held")
        gate.record(.screensWoke)
        clock.advance(59)
        engine.tick()
        #expect(bus.transactions.isEmpty)
        clock.advance(1)
        engine.tick()
        // The picture of the displays was thrown away, so the target is read once more.
        #expect(bus.transactions == ["read Dell \(brightness)", "read Lenovo \(brightness)"])
    }

    @Test func anEventInTheMiddleOfARoundStopsTheRest() {
        bus["Dell"].brightness = (70, 100)
        bus.afterTransaction = { [unowned self] in self.gate.record(.reconfigurationBegan) }
        settleAndSync()
        #expect(bus.transactions == ["read Dell \(brightness)"])
    }

    @Test func aDisplayMacOSReportsAsleepIsSkipped() {
        bus["Lenovo"].asleep = true
        settleAndSync()
        #expect(bus.transactions == ["read Dell \(brightness)"])
    }

    @Test func aFailedReadBacksOffInsteadOfRetrying() {
        bus["Dell"].failing = true
        settleAndSync()
        #expect(bus.transactions.count == 1)
        // 30 s interval: wait 60 s, then 120 s, then 240 s.
        for (wait, expected) in [(59.0, 1), (1, 2), (119, 2), (1, 3), (239, 3), (1, 4)] {
            clock.advance(wait)
            engine.tick()
            #expect(bus.transactions.count == expected, "after waiting \(wait) s")
        }
    }

    @Test func backOffIsCappedAtHalfAnHour() {
        bus["Dell"].failing = true
        settleAndSync()
        for _ in 0..<20 {
            clock.advance(SyncEngine.maxBackoff)
            engine.tick()
        }
        bus.reset()
        clock.advance(SyncEngine.maxBackoff - 1)
        engine.tick()
        #expect(bus.transactions.isEmpty)
        clock.advance(1)
        engine.tick()
        #expect(bus.transactions.count == 1)
    }

    @Test func aSuccessfulReadClearsTheBackOff() {
        bus["Dell"].failing = true
        settleAndSync()
        clock.advance(60)
        bus["Dell"].failing = false
        engine.tick()
        bus.reset()
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions == ["read Dell \(brightness)"])
    }

    @Test func aPresetTheTargetIgnoresIsTriedOnce() {
        settings.syncColor = true
        bus["Dell"].preset = (4, 12)
        bus["Lenovo"].preset = (5, 12)
        bus["Lenovo"].ignoredPresets = [4]
        settleAndSync()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } == ["write Lenovo \(preset)=4"])
        bus.reset()
        for _ in 0..<10 {
            clock.advance(30)
            engine.tick()
        }
        #expect(!bus.transactions.contains { $0.hasPrefix("write") })
        #expect(logged.contains { $0.contains("does not take colour preset 4") })
    }

    @Test func colourIsOnlyReadWhenColourSyncIsOn() {
        settleAndSync()
        #expect(!bus.transactions.contains { $0.contains("\(preset)") })
    }

    // MARK: - Following a light sensor

    @Test func aSensorTargetIsWrittenToEveryDisplayEvenASingleOne() {
        bus.panels.removeLast()
        settings.followsSensor = true
        bus["Dell"].brightness = (20, 100)
        engine.receiveAmbient(72, exact: false)
        settleAndSync()
        #expect(bus.transactions == ["read Dell \(brightness)", "write Dell \(brightness)=72"])
    }

    @Test func aSteadySensorSendsNothingAfterTheFirstRound() {
        settings.followsSensor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        for _ in 0..<120 {
            clock.advance(30)
            engine.tick()
        }
        #expect(bus.transactions.isEmpty)
    }

    @Test func aNewTargetIsOnlyWrittenNotReadAgain() {
        settings.followsSensor = true
        bus["Lenovo"].brightness = (40, 200)
        engine.receiveAmbient(50, exact: false)
        settleAndSync()
        bus.reset()
        engine.receiveAmbient(80, exact: false)
        engine.tick()
        #expect(bus.transactions == ["write Dell \(brightness)=80", "write Lenovo \(brightness)=160"])
    }

    @Test func theSliderIsExactButTheSensorHasADeadband() {
        settings.followsSensor = true
        bus["Dell"].brightness = (60, 100)
        bus["Lenovo"].brightness = (60, 100)
        engine.receiveAmbient(61, exact: false)
        settleAndSync()
        #expect(!bus.transactions.contains { $0.hasPrefix("write") })
        engine.receiveAmbient(61, exact: true)
        engine.tick()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } == ["write Dell \(brightness)=61", "write Lenovo \(brightness)=61"])
    }

    @Test func withoutAReadingNothingIsSent() {
        settings.followsSensor = true
        settleAndSync()
        #expect(bus.transactions.isEmpty)
        #expect(engine.lastStatus.message == "Waiting for a light reading")
    }

    @Test func aSensorTargetWaitsForTheGate() {
        settings.followsSensor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        gate.record(.screensSlept)
        engine.receiveAmbient(90, exact: true)
        engine.tick()
        #expect(bus.transactions.isEmpty)
        gate.record(.screensWoke)
        clock.advance(60)
        engine.tick()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } == ["write Dell \(brightness)=90", "write Lenovo \(brightness)=90"])
    }

    @Test func colourCanFollowADisplayWhileBrightnessFollowsASensor() {
        settings.followsSensor = true
        settings.syncColor = true
        settings.colorSourceKey = "uuid-Dell"
        bus["Dell"].preset = (8, 12)
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } ==
                ["write Dell \(brightness)=60", "write Lenovo \(brightness)=60", "write Lenovo \(preset)=8"])
        clock.advance(30)
        engine.tick() // re-reads the Lenovo's brightness once, since a preset can carry its own
        bus.reset()
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions == ["read Dell \(preset)"], "steady state: only the colour source is read")
    }

    // MARK: - The gate covers colour and the sensor too

    @Test func colourIsNotSentWhileDisplaysSleep() {
        settings.syncColor = true
        settleAndSync()
        bus.reset()
        gate.record(.screensSlept)
        bus["Dell"].preset = (8, 12)
        for _ in 0..<10 {
            clock.advance(30)
            engine.tick()
        }
        #expect(bus.transactions.isEmpty)
        gate.record(.screensWoke)
        clock.advance(59)
        engine.tick()
        #expect(bus.transactions.isEmpty, "not before the quiet period ends")
    }

    @Test func anEventDuringTheColourPassStopsIt() {
        settings.syncColor = true
        bus["Dell"].preset = (8, 12)
        bus.afterTransaction = { [unowned self] in
            if bus.transactions.last == "read Dell \(preset)" {
                gate.record(.reconfigurationBegan)
            }
        }
        settleAndSync()
        #expect(bus.transactions.last == "read Dell \(preset)", "nothing after the event")
        #expect(!bus.transactions.contains { $0.hasPrefix("write Lenovo \(preset)") })
    }

    @Test func aFailedColourReadBacksOffThatDisplay() {
        settings.syncColor = true
        settleAndSync()
        bus.reset()
        bus["Dell"].failing = true
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions == ["read Dell \(brightness)"], "the first failure ends that display's round")
        bus.reset()
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions.isEmpty, "brightness and colour wait out the back-off together")
    }

    @Test func aSensorChangeWhileAsleepIsWrittenOnlyAfterTheQuietPeriod() {
        settings.followsSensor = true
        settings.syncColor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        gate.record(.systemWillSleep)
        engine.receiveAmbient(20, exact: false)
        engine.tick()
        gate.record(.systemDidWake)
        engine.tick()
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions.isEmpty)
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions.contains("write Dell \(brightness)=20"))
    }

    @Test func anEventMidwayThroughSensorWritesStopsTheRest() {
        settings.followsSensor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        bus.afterTransaction = { [unowned self] in gate.record(.screensSlept) }
        engine.receiveAmbient(90, exact: true)
        engine.tick()
        #expect(bus.transactions == ["write Dell \(brightness)=90"])
    }

    // MARK: - Unusable replies

    @Test func anUnusableColourReplyDoesNotHoldUpBrightness() {
        settings.followsSensor = true
        settings.syncColor = true
        settings.colorSourceKey = "uuid-Dell"
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus["Dell"].garbled = [preset]
        clock.advance(30)
        engine.tick()
        bus.reset()
        engine.receiveAmbient(12, exact: false)
        engine.tick()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } == ["write Dell \(brightness)=12", "write Lenovo \(brightness)=12"])
    }

    @Test func anUnusableReplyIsReadAgainNextRoundThenLessOften() {
        settleAndSync()
        bus["Dell"].garbled = [brightness]
        bus.reset()
        var readsAt: [Int] = []
        for second in stride(from: 30, through: 600, by: 30) {
            clock.advance(30)
            let before = bus.transactions.count
            engine.tick()
            if bus.transactions.count > before {
                readsAt.append(second)
            }
        }
        // 30 s interval: again after 30, then 60, 120 and 240 s.
        #expect(readsAt == [30, 60, 120, 240, 480])
    }

    // MARK: - Pauses

    @Test func aCallPausesEverythingAndBrightnessCatchesUpAfter() {
        settings.followsSensor = true
        settings.syncColor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        call.isOn = true
        engine.receiveAmbient(30, exact: true)
        for _ in 0..<20 {
            clock.advance(15)
            engine.tick()
        }
        #expect(bus.transactions.isEmpty)
        #expect(engine.nextDelay() == SyncEngine.pauseRecheck, "checked again every 15 s, with no DDC")
        call.isOn = false
        engine.tick()
        #expect(bus.transactions.contains("write Dell \(brightness)=30"))
        #expect(logged.contains("holding off: camera or microphone in use"))
        #expect(logged.contains("resuming: no longer camera or microphone in use"))
    }

    @Test func aCallStartingMidRoundStopsTheRest() {
        settings.followsSensor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        bus.afterTransaction = { [unowned self] in call.isOn = true }
        engine.receiveAmbient(90, exact: true)
        engine.tick()
        #expect(bus.transactions == ["write Dell \(brightness)=90"])
    }

    // MARK: - Known ranges

    @Test func afterWakeASensorTargetIsOneWriteWhenTheRangeIsKnown() {
        settings.followsSensor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        bus.reset()
        gate.record(.screensSlept)
        gate.record(.screensWoke)
        engine.receiveAmbient(12, exact: false)
        clock.advance(60)
        engine.tick()
        #expect(bus.transactions == ["write Dell \(brightness)=12", "write Lenovo \(brightness)=12"],
                "no read, so no garbled first read to wait out")
    }

    @Test func aGarbledFirstReadDoesNotDelayAKnownDisplay() {
        settings.followsSensor = true
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        gate.record(.reconfigured)
        bus["Dell"].garbled = [brightness]
        bus.reset()
        engine.receiveAmbient(12, exact: false)
        clock.advance(60)
        engine.tick()
        #expect(bus.transactions.contains("write Dell \(brightness)=12"))
    }

    // MARK: - Displays that cannot be read

    @Test func aDisplayThatNeverAnswersIsWrittenAsZeroToAHundred() {
        settings.followsSensor = true
        bus["Dell"].garbled = [brightness]
        engine.receiveAmbient(60, exact: false)
        settleAndSync()
        #expect(!bus.transactions.contains { $0.hasPrefix("write Dell") }, "one unusable reply may be a glitch")
        bus.reset()
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions == ["read Dell \(brightness)", "write Dell \(brightness)=60"])
        #expect(logged.contains("Dell does not answer brightness reads; writing to it as 0–100"))
        bus.reset()
        engine.receiveAmbient(25, exact: false)
        engine.tick()
        #expect(bus.transactions == ["write Dell \(brightness)=25", "write Lenovo \(brightness)=25"], "not read again")
        bus.reset()
        gate.record(.screensSlept)
        gate.record(.screensWoke)
        engine.receiveAmbient(12, exact: false)
        clock.advance(60)
        engine.tick()
        #expect(bus.transactions == ["write Dell \(brightness)=12", "write Lenovo \(brightness)=12"])
    }

    @Test func aFollowerThatNeverAnswersStillMirrorsTheSource() {
        bus["Lenovo"].garbled = [brightness]
        settleAndSync()
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } == ["write Lenovo \(brightness)=50"])
        bus.reset()
        bus["Dell"].brightness.current = 80
        clock.advance(30)
        engine.tick()
        #expect(bus.transactions == ["read Dell \(brightness)", "write Lenovo \(brightness)=80"])
    }

    @Test func aFollowerThatStopsAnsweringKeepsTheRangeItWasReadWith() {
        bus["Lenovo"].brightness = (40, 80)
        settleAndSync()
        gate.record(.reconfigured)
        bus["Lenovo"].garbled = [brightness]
        bus["Dell"].brightness.current = 25
        clock.advance(60)
        engine.tick()
        clock.advance(30)
        bus.reset()
        engine.tick()
        #expect(bus.transactions == ["read Dell \(brightness)", "read Lenovo \(brightness)", "write Lenovo \(brightness)=20"])
        #expect(!logged.contains { $0.contains("does not answer") }, "its own range, not an assumed one")
    }

    // MARK: - Per-monitor targets

    @Test func eachMonitorCanHaveItsOwnTarget() {
        settings.followsSensor = true
        engine.receiveAmbient(AmbientTarget(percent: 60, perDisplay: ["uuid-Lenovo": 45]))
        settleAndSync()
        #expect(bus.transactions.filter { $0.hasPrefix("write") } == ["write Dell \(brightness)=60", "write Lenovo \(brightness)=45"])
    }
}
