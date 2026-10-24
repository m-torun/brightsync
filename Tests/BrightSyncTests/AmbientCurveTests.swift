import Foundation
import Testing
@testable import BrightSync

struct AmbientCurveTests {
    func near(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.01
    }

    @Test func theDefaultRisesTwentyFivePointsPerTenfoldStep() {
        #expect(near(AmbientCurve.percent(at: 1), 10))
        #expect(near(AmbientCurve.percent(at: 10), 35))
        #expect(near(AmbientCurve.percent(at: 100), 60))
        #expect(near(AmbientCurve.percent(at: 1000), 85))
        #expect(AmbientCurve.percent(at: 5000) == 100)
        #expect(near(AmbientCurve.percent(at: 0), 10), "darker than 1 lux counts as 1 lux")
    }
}

struct BrightnessOffsetsTests {
    @Test func togetherEveryMonitorGetsTheSharedOffset() {
        let offsets = BrightnessOffsets(together: true, shared: 10, perDisplay: ["dell": -20])
        #expect(offsets.percent(for: "dell", at: 100) == 70)
        #expect(offsets.percent(for: "lenovo", at: 100) == 70)
    }

    @Test func separatelyEachMonitorHasItsOwn() {
        let offsets = BrightnessOffsets(together: false, shared: 10, perDisplay: ["dell": -20])
        #expect(offsets.percent(for: "dell", at: 100) == 40)
        #expect(offsets.percent(for: "lenovo", at: 100) == 70, "a monitor without its own starts from the shared one")
    }

    @Test func theResultStaysWithinZeroAndAHundred() {
        let offsets = BrightnessOffsets(together: true, shared: 50)
        #expect(offsets.percent(for: "dell", at: 5000) == 100)
        #expect(BrightnessOffsets(together: true, shared: -50).percent(for: "dell", at: 1) == 0)
    }

    @Test func goingSeparateCopiesTheSharedOffsetSoNothingJumps() {
        var offsets = BrightnessOffsets(together: true, shared: 15)
        offsets.setTogether(false, displays: ["dell", "lenovo"])
        #expect(offsets.perDisplay == ["dell": 15, "lenovo": 15])
        offsets.perDisplay["dell"] = 30
        offsets.setTogether(true, displays: ["dell", "lenovo"])
        #expect(offsets.offset(for: "dell") == 15, "together again uses the shared one")
        offsets.setTogether(false, displays: ["dell", "lenovo"])
        #expect(offsets.offset(for: "dell") == 30, "and separate again remembers each monitor's own")
    }
}
