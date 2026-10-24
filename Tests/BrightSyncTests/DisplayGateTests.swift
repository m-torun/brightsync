import Foundation
import Testing
@testable import BrightSync

struct DisplayGateTests {
    let clock = FakeClock()
    var gate: DisplayGate { DisplayGate(quietPeriod: 60, now: { [clock] in clock.time }) }

    @Test func launchWaitsOneQuietPeriod() {
        let gate = self.gate
        #expect(gate.state == .settling(remaining: 60))
        clock.advance(59.9)
        #expect(!gate.isOpen)
        clock.advance(0.1)
        #expect(gate.isOpen)
    }

    @Test func everyDisplayChangeRestartsTheQuietPeriod() {
        let gate = self.gate
        clock.advance(60)
        gate.record(.reconfigurationBegan)
        #expect(gate.state == .settling(remaining: 60))
        clock.advance(45)
        gate.record(.reconfigured)
        clock.advance(45)
        #expect(!gate.isOpen, "45 s after the last event is not quiet enough")
        clock.advance(15)
        #expect(gate.isOpen)
    }

    @Test func displaySleepHoldsUntilWakeThenSettles() {
        let gate = self.gate
        clock.advance(60)
        gate.record(.screensSlept)
        clock.advance(3_600)
        #expect(gate.state == .held("displays asleep"), "no quiet period ends a sleep")
        gate.record(.screensWoke)
        #expect(gate.state == .settling(remaining: 60))
        clock.advance(60)
        #expect(gate.isOpen)
    }

    @Test func macSleepHoldsUntilWake() {
        let gate = self.gate
        gate.record(.systemWillSleep)
        clock.advance(600)
        #expect(gate.state == .held("Mac asleep"))
        gate.record(.systemDidWake)
        #expect(gate.state == .settling(remaining: 60))
    }

    @Test func wakingTheMacWithDisplaysStillAsleepStaysHeld() {
        let gate = self.gate
        gate.record(.screensSlept)
        gate.record(.systemWillSleep)
        gate.record(.systemDidWake) // a dark wake, e.g. for Power Nap
        clock.advance(600)
        #expect(gate.state == .held("displays asleep"))
        gate.record(.screensWoke)
        clock.advance(60)
        #expect(gate.isOpen)
    }

    @Test func displaysWakingMeansTheMacIsAwakeEvenIfItsWakeWasMissed() {
        let gate = self.gate
        gate.record(.systemWillSleep)
        gate.record(.screensWoke)
        clock.advance(60)
        #expect(gate.isOpen)
    }

    @Test func anotherUserSessionHolds() {
        let gate = self.gate
        gate.record(.sessionResigned)
        clock.advance(600)
        #expect(gate.state == .held("another user is active"))
        gate.record(.sessionActivated)
        clock.advance(60)
        #expect(gate.isOpen)
    }

    @Test func shutdownHoldsForGood() {
        let gate = self.gate
        gate.record(.poweringOff)
        gate.record(.screensWoke)
        clock.advance(3_600)
        #expect(!gate.isOpen)
    }

    @Test func everyEventChangesTheGeneration() {
        let gate = self.gate
        let first = gate.generation
        gate.record(.reconfigured)
        #expect(gate.generation == first + 1)
    }

    // MARK: - Conditions

    @Test func aConditionPausesWithoutCountingAsADisplayChange() {
        var inCall = false
        let gate = DisplayGate(quietPeriod: 60, now: { [clock] in clock.time },
                               conditions: [{ inCall ? "camera or microphone in use" : nil }])
        clock.advance(60)
        let generation = gate.generation
        inCall = true
        #expect(gate.state == .paused("camera or microphone in use"))
        inCall = false
        #expect(gate.isOpen, "no quiet period after a call: the displays did not change")
        #expect(gate.generation == generation)
    }

    @Test func sleepOutranksAPause() {
        let gate = DisplayGate(quietPeriod: 60, now: { [clock] in clock.time }, conditions: [{ "displays about to sleep" }])
        gate.record(.screensSlept)
        #expect(gate.state == .held("displays asleep"))
    }

    @Test func aLockedScreenHoldsUntilUnlocked() {
        let gate = self.gate
        clock.advance(60)
        let generation = gate.generation
        gate.record(.screenLocked)
        clock.advance(3_600)
        #expect(gate.state == .held("screen locked"))
        gate.record(.screenUnlocked)
        #expect(gate.isOpen, "unlocking is not a display change: no quiet period")
        #expect(gate.generation == generation)
    }

    @Test func unlockingDoesNotRestartAQuietPeriodUnderWay() {
        let gate = self.gate
        clock.advance(60)
        gate.record(.reconfigured)
        clock.advance(15)
        gate.record(.screenUnlocked)
        clock.advance(45)
        #expect(gate.isOpen, "60 s after the display change, not after the unlock")
    }

    @Test func theDisplaySleepTimerIsReadFromPmset() {
        let output = """
        System-wide power settings:
        Currently in use:
         standby              0
         displaysleep         10 (display sleep prevented by Teams)
         sleep                1
        """
        #expect(IdleDisplaySleep.parseTimeout(output) == 600)
        #expect(IdleDisplaySleep.parseTimeout(" displaysleep         0") == nil, "0 means never")
        #expect(IdleDisplaySleep.parseTimeout("") == nil)
    }
}
