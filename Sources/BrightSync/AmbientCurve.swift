import Foundation

/// Maps ambient light to a brightness percentage.
///
/// Eyes judge light roughly logarithmically, so the curve works in tenfold
/// steps of lux. Out of the box brightness rises 25 points per tenfold
/// increase: 10% at 1 lux, 60% at 100 lux, 100% from about 1800 lux. Each
/// time the slider is moved, the brightness chosen at the current light
/// becomes a point the curve passes through. Between points it is a straight
/// line; beyond the outermost ones it keeps the default slope.
struct AmbientCurve: Codable, Equatable {
    struct Point: Codable, Equatable {
        var lux: Double
        var percent: Double
    }

    /// Brightness points per tenfold increase in light, outside the user's points.
    static let slope = 25.0
    /// The line used before the user has set anything.
    static let fallback = Point(lux: 100, percent: 60)
    /// A new point replaces any within this many tenfold steps (a factor of 1.6).
    static let spacing = 0.2

    /// Sorted by light. Brightness never falls as the light rises.
    private(set) var points: [Point] = []

    func percent(at lux: Double) -> Double {
        let x = Self.decades(lux)
        let anchors = points.isEmpty ? [Self.fallback] : points
        let first = anchors[0], last = anchors[anchors.count - 1]
        let value: Double
        if x <= Self.decades(first.lux) {
            value = first.percent + Self.slope * (x - Self.decades(first.lux))
        } else if x >= Self.decades(last.lux) {
            value = last.percent + Self.slope * (x - Self.decades(last.lux))
        } else {
            let upper = anchors.firstIndex { Self.decades($0.lux) > x }!
            let a = anchors[upper - 1], b = anchors[upper]
            let (xa, xb) = (Self.decades(a.lux), Self.decades(b.lux))
            value = a.percent + (b.percent - a.percent) * (x - xa) / (xb - xa)
        }
        return min(max(value, 0), 100)
    }

    /// Makes the curve pass through `percent` at `lux`. Points too close to
    /// it, or that would make the curve dip as the light rises, are dropped:
    /// the newest choice wins.
    mutating func set(_ percent: Double, at lux: Double) {
        let x = Self.decades(lux)
        points.removeAll { point in
            let px = Self.decades(point.lux)
            return abs(px - x) < Self.spacing
                || (px < x && point.percent > percent)
                || (px > x && point.percent < percent)
        }
        points.append(Point(lux: lux, percent: percent))
        points.sort { $0.lux < $1.lux }
    }

    mutating func reset() {
        points = []
    }

    /// Tenfold steps above 1 lux; anything darker counts as 1 lux.
    static func decades(_ lux: Double) -> Double {
        log10(max(lux, 1))
    }
}
