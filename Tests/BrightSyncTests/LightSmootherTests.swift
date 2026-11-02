import Foundation
import Testing
@testable import BrightSync

struct LightSmootherTests {
    func near(_ a: Double?, _ b: Double, within tolerance: Double = 0.02) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance * b
    }

    @Test func aSteadyLightIsItself() {
        var smoother = LightSmoother()
        smoother.add(lux: 40, at: 0)
        #expect(near(smoother.lux(at: 1_000), 40))
        #expect(smoother.isSettled(at: 1_000))
    }

    @Test func aSmallChangeRampsInOverFiveMinutes() {
        var smoother = LightSmoother()
        smoother.add(lux: 10, at: 0)
        let jumped = smoother.add(lux: 20, at: 1_000)
        #expect(!jumped, "doubling is not a jump")
        // Halfway through the window it is halfway, in tenfold steps.
        #expect(near(smoother.lux(at: 1_150), sqrt(10 * 20)))
        #expect(!smoother.isSettled(at: 1_150))
        #expect(near(smoother.lux(at: 1_300), 20))
        #expect(smoother.isSettled(at: 1_300))
    }

    @Test func aBigChangeAppliesOnceItHasHeld() {
        var smoother = LightSmoother()
        smoother.add(lux: 2, at: 0)
        let first = smoother.add(lux: 120, at: 1_000)
        #expect(!first, "one reading proves nothing")
        let early = smoother.confirmJump(at: 1_059)
        #expect(!early)
        #expect(AmbientCurve.percent(at: smoother.lux(at: 1_059)!) - AmbientCurve.percent(at: 2) < 10, "it only eased up meanwhile")
        let held = smoother.confirmJump(at: 1_060)
        #expect(held, "sixty times brighter for a minute: a lamp went on")
        #expect(near(smoother.lux(at: 1_060), 120))
        #expect(smoother.isSettled(at: 1_060))
    }

    @Test func itHoldsOnTheWayDownToo() {
        var smoother = LightSmoother()
        smoother.add(lux: 120, at: 0)
        smoother.add(lux: 2, at: 1_000)
        let early = smoother.confirmJump(at: 1_059)
        #expect(!early)
        let held = smoother.confirmJump(at: 1_060)
        #expect(held)
        #expect(near(smoother.lux(at: 1_060), 2))
    }

    @Test func aFivefoldChangeRampsInRatherThanJumps() {
        // A few lux in a dim room, even when it lasts.
        var smoother = LightSmoother()
        smoother.add(lux: 1, at: 0)
        smoother.add(lux: 5, at: 1_000)
        var jumped = false
        for second in stride(from: 1_001.0, through: 1_300, by: 15) {
            let result = smoother.confirmJump(at: second)
            jumped = jumped || result
        }
        #expect(!jumped)
        #expect(near(smoother.lux(at: 1_300), 5))
    }

    @Test func goingFromAboveToBelowRestartsTheHold() {
        var smoother = LightSmoother()
        smoother.add(lux: 10, at: 0)
        smoother.add(lux: 200, at: 1_000)
        smoother.add(lux: 1, at: 1_040)
        let early = smoother.confirmJump(at: 1_061)
        #expect(!early, "61 s away from the average, but not on one side")
        let held = smoother.confirmJump(at: 1_100)
        #expect(held)
    }

    /// A sensor seen pulsing: 1 lux, with 5 or 10 lux for about 2 s in every 10. Raw, each pulse moved the monitors 17 to 25 points.
    @Test func aPulsingSensorDoesNotMoveTheMonitors() {
        var smoother = LightSmoother()
        smoother.add(lux: 1, at: 0)
        var brightness: [Double] = []
        for pulse in 0..<200 {
            let start = 10 + Double(pulse) * 10
            let result6 = smoother.add(lux: pulse.isMultiple(of: 3) ? 10 : 5, at: start)
            #expect(!result6)
            brightness.append(AmbientCurve.percent(at: smoother.lux(at: start + 1)!))
            let result7 = smoother.add(lux: 1, at: start + 2)
            #expect(!result7)
            brightness.append(AmbientCurve.percent(at: smoother.lux(at: start + 9)!))
        }
        let settled = brightness.suffix(100)
        #expect(settled.max()! - settled.min()! < 2, "under two points once the average has them all")
        #expect(brightness.max()! - brightness.min()! < 10, "and it only got there slowly")
    }

    @Test func anyReadingBackInRangeRestartsTheHold() {
        var smoother = LightSmoother()
        smoother.add(lux: 1, at: 0)
        smoother.add(lux: 30, at: 1_000)
        smoother.add(lux: 1, at: 1_040)
        smoother.add(lux: 30, at: 1_045)
        let early = smoother.confirmJump(at: 1_100)
        #expect(!early, "held for 55 s, not the 100 s since it first rose")
        let held = smoother.confirmJump(at: 1_105)
        #expect(held)
    }

    @Test func readingsMovingAroundUpThereStillCountAsHolding() {
        var smoother = LightSmoother()
        smoother.add(lux: 1, at: 0)
        smoother.add(lux: 14, at: 1_000)
        smoother.add(lux: 19, at: 1_020)
        smoother.add(lux: 14, at: 1_040)
        let held = smoother.add(lux: 19, at: 1_060)
        #expect(held)
        #expect(near(smoother.lux(at: 1_060), 19))
    }

    @Test func aPulseJustAfterAJumpOrAtTheStartWeighsNoMore() {
        var fresh = LightSmoother()
        fresh.add(lux: 1, at: 0)
        fresh.add(lux: 100, at: 5)
        fresh.add(lux: 1, at: 7)
        #expect(AmbientCurve.percent(at: fresh.lux(at: 7)!) - AmbientCurve.percent(at: 1) < 1, "2 s out of the whole window")

        var jumped = LightSmoother()
        jumped.add(lux: 1, at: 0)
        jumped.add(lux: 100, at: 1_000)
        jumped.confirmJump(at: 1_060)
        jumped.add(lux: 1, at: 1_065)
        jumped.add(lux: 100, at: 1_067)
        #expect(AmbientCurve.percent(at: jumped.lux(at: 1_067)!) > AmbientCurve.percent(at: 100) - 1)
    }

    @Test func aWobbleAveragesOut() {
        // Tonight's dim room: 1.3 and 3.3 lux in turn, every 30 s.
        var smoother = LightSmoother()
        var outputs: [Double] = []
        for step in 0..<40 {
            smoother.add(lux: step.isMultiple(of: 2) ? 1.3 : 3.3, at: Double(step) * 30)
            if step >= 10 {
                outputs.append(smoother.lux(at: Double(step) * 30 + 29)!)
            }
        }
        let brightness = outputs.map(AmbientCurve.percent(at:))
        #expect(brightness.max()! - brightness.min()! < 2, "under two points of brightness, where raw readings moved it about 10")
    }

    @Test func nothingBeforeTheFirstReading() {
        #expect(LightSmoother().lux(at: 100) == nil)
    }
}
