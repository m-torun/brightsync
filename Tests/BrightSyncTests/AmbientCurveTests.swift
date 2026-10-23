import Foundation
import Testing
@testable import BrightSync

struct AmbientCurveTests {
    func near(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.01
    }

    @Test func theDefaultRisesTwentyFivePointsPerTenfoldStep() {
        let curve = AmbientCurve()
        #expect(near(curve.percent(at: 1), 10))
        #expect(near(curve.percent(at: 10), 35))
        #expect(near(curve.percent(at: 100), 60))
        #expect(near(curve.percent(at: 1000), 85))
        #expect(curve.percent(at: 5000) == 100)
        #expect(near(curve.percent(at: 0), 10), "darker than 1 lux counts as 1 lux")
    }

    @Test func onePointMovesTheWholeLineThroughIt() {
        var curve = AmbientCurve()
        curve.set(90, at: 12)
        #expect(near(curve.percent(at: 12), 90))
        #expect(near(curve.percent(at: 120), 100), "clamped")
        #expect(near(curve.percent(at: 1.2), 65))
    }

    @Test func betweenTwoPointsItIsAStraightLineInLogLux() {
        var curve = AmbientCurve()
        curve.set(40, at: 10)
        curve.set(80, at: 1000)
        #expect(near(curve.percent(at: 100), 60))
        #expect(near(curve.percent(at: 1), 15), "the default slope below the lowest point")
        #expect(near(curve.percent(at: 10_000), 100))
    }

    @Test func aNewPointReplacesOnesCloseToIt() {
        var curve = AmbientCurve()
        curve.set(50, at: 100)
        curve.set(70, at: 130)
        #expect(curve.points == [.init(lux: 130, percent: 70)])
    }

    @Test func theCurveNeverDipsAsTheLightRises() {
        var curve = AmbientCurve()
        curve.set(30, at: 10)
        curve.set(60, at: 100)
        curve.set(90, at: 1000)
        // Wanting it brighter in the dark than at 100 lux overrides the 100 lux point.
        curve.set(70, at: 10)
        #expect(curve.points.map(\.percent) == [70, 90])
        // And dimmer in bright light drops anything brighter below it.
        curve.set(50, at: 1000)
        #expect(curve.points.map(\.percent) == [50])
    }

    @Test func survivesARoundTripThroughPreferences() throws {
        var curve = AmbientCurve()
        curve.set(42, at: 7)
        let data = try JSONEncoder().encode(["sensor": curve])
        #expect(try JSONDecoder().decode([String: AmbientCurve].self, from: data)["sensor"] == curve)
    }
}
