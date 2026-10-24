import Foundation

/// Evens out small changes in light so the monitors do not keep nudging
/// themselves, while big changes still apply at once.
///
/// Light is averaged over a time window, weighted by how long each reading
/// held, in tenfold steps (log lux) like the brightness curve, so a wobble
/// between 1.3 and 3.3 lux counts the same as one between 130 and 330. A
/// reading more than `jump` steps from the average (fourfold by default),
/// such as a lamp switched on at night, replaces the average outright.
struct LightSmoother {
    var window: TimeInterval = 300
    /// In tenfold steps: 0.6 is a factor of about 4.
    var jump = 0.6

    /// Readings in time order. The oldest may predate the window, since it
    /// still held at the window's start.
    private var samples: [(time: TimeInterval, decades: Double)] = []

    /// Adds a reading. Returns true when it was a jump and applies at once.
    @discardableResult
    mutating func add(lux: Double, at time: TimeInterval) -> Bool {
        let decades = AmbientCurve.decades(lux)
        if let average = averageDecades(at: time), abs(decades - average) > jump {
            samples = [(time, decades)]
            return true
        }
        samples.append((time, decades))
        trim(at: time)
        return false
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
