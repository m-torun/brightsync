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

    @Test func aBigChangeAppliesAtOnce() {
        var smoother = LightSmoother()
        smoother.add(lux: 2, at: 0)
        let jumped = smoother.add(lux: 120, at: 1_000)
        #expect(jumped, "sixty times brighter: a lamp went on")
        #expect(near(smoother.lux(at: 1_000), 120))
        #expect(smoother.isSettled(at: 1_000))
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
