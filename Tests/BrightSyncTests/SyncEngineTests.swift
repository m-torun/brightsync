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
    init() {
        gate = DisplayGate(quietPeriod: 60, now: { [clock] in clock.time })
        engine = SyncEngine(bus: bus, gate: gate,
                            now: { [clock] in clock.time },
                            settings: { [unowned self] in self.settings },
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
}
