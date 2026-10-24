import Foundation

/// The default brightness for a light level, before the user's offset.
///
/// Eyes judge light roughly logarithmically, so brightness rises 25 points for
/// every tenfold increase in light: 10% at 1 lux, 60% at 100 lux, 100% from
/// about 1800 lux. The slider moves everything up or down from here.
enum AmbientCurve {
    /// Brightness points per tenfold increase in light.
    static let slope = 25.0

    static func percent(at lux: Double) -> Double {
        min(max(60 + slope * (decades(lux) - 2), 0), 100)
    }

    /// Tenfold steps above 1 lux; anything darker counts as 1 lux.
    static func decades(_ lux: Double) -> Double {
        log10(max(lux, 1))
    }
}

/// How far the user wants brightness moved from the default curve, in points.
/// One offset for every monitor, or one each, like a car's dual-zone climate
/// control with its SYNC button.
struct BrightnessOffsets: Equatable {
    static let range: ClosedRange<Double> = -50...50

    /// Use `shared` for every monitor.
    var together = true
    var shared = 0.0
    /// By display key, used when not together. A monitor without one starts
    /// from `shared`.
    var perDisplay: [String: Double] = [:]

    func offset(for display: String) -> Double {
        together ? shared : perDisplay[display] ?? shared
    }

    /// The brightness a monitor gets at `lux`.
    func percent(for display: String, at lux: Double) -> Double {
        min(max(AmbientCurve.percent(at: lux) + offset(for: display), 0), 100)
    }

    /// Turning "together" off gives each monitor its own copy of the shared
    /// offset, so nothing jumps; turning it back on uses the shared one again.
    mutating func setTogether(_ on: Bool, displays: [String]) {
        if !on {
            for display in displays where perDisplay[display] == nil {
                perDisplay[display] = shared
            }
        }
        together = on
    }
}
