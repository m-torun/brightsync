import Foundation

/// Evens out changes in light so the monitors do not keep nudging themselves,
/// while a lasting big change still applies at once.
///
/// Light is averaged over a time window, weighted by how long each reading
/// held, in tenfold steps (log lux) like the brightness curve, so a wobble
/// between 1.3 and 3.3 lux counts the same as one between 130 and 330.
///
/// A reading more than `jump` steps from the average that stays there for `hold`
/// seconds, such as a lamp switched on at night, replaces the average. The average
/// takes in the reading meanwhile, so by default that means about sixfold or more;
/// anything less just ramps in. Until it has held it is averaged like any other. A single reading
/// must not be enough: a sensor can pulse every couple of seconds, as a ThirdReality
/// R3 was seen to between 1 and 14 lux, and in a dim room a change of a few lux is
/// already fourfold.
struct LightSmoother {
    var window: TimeInterval = 300
    /// In tenfold steps: 0.6 is a factor of about 4.
    var jump = 0.6
    var hold: TimeInterval = 60

    /// Readings in time order. The oldest may predate the window, since it
    /// still held at the window's start.
    private var samples: [(time: TimeInterval, decades: Double)] = []
    /// Since when the readings have been `jump` from the average, and on which side.
    private var away: (since: TimeInterval, above: Bool)?

    /// Adds a reading. Returns true when that completes a jump.
    @discardableResult
    mutating func add(lux: Double, at time: TimeInterval) -> Bool {
        let decades = AmbientCurve.decades(lux)
        if samples.isEmpty {
            settle(on: decades, at: time)
            return false
        }
        samples.append((time, decades))
        trim(at: time)
        return confirmJump(at: time)
    }

    /// Returns true when the latest reading has now held long enough to be a
    /// jump, and applies it. Sensors only report changes, so a reading can
    /// complete its hold with nothing new arriving: call this now and then.
    @discardableResult
    mutating func confirmJump(at time: TimeInterval) -> Bool {
        guard let last = samples.last, let average = averageDecades(at: time),
              abs(last.decades - average) > jump else {
            away = nil
            return false
        }
        let above = last.decades > average
        if away?.above != above {
            away = (time, above)
        }
        guard let away, time - away.since >= hold else { return false }
        settle(on: last.decades, at: time)
        return true
    }

    /// Takes a level as having held for the whole window, so that a pulse right
    /// after it weighs as little as at any other time.
    private mutating func settle(on decades: Double, at time: TimeInterval) {
        samples = [(time - window, decades)]
        away = nil
    }

    /// The average light over the window, in lux.
    func lux(at time: TimeInterval) -> Double? {
        averageDecades(at: time).map { pow(10, $0) }
    }

    /// True once the average has caught up with the latest reading, so
    /// nothing changes until a new one arrives.
    func isSettled(at time: TimeInterval) -> Bool {
        guard let last = samples.last, let average = averageDecades(at: time) else { return true }
        return abs(average - last.decades) < 0.005
    }

    mutating func reset() {
        samples = []
        away = nil
    }

    private func averageDecades(at time: TimeInterval) -> Double? {
        guard let first = samples.first else { return nil }
        let start = max(time - window, first.time)
        guard time > start else { return samples.last?.decades }
        var total = 0.0
        for (index, sample) in samples.enumerated() {
            let from = max(sample.time, start)
            let to = index + 1 < samples.count ? min(samples[index + 1].time, time) : time
            if to > from {
                total += sample.decades * (to - from)
            }
        }
        return total / (time - start)
    }

    /// Drops readings that ended before the window began.
    private mutating func trim(at time: TimeInterval) {
        let start = time - window
        while samples.count > 1, samples[1].time <= start {
            samples.removeFirst()
        }
    }
}
