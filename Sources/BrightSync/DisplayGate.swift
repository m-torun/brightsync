import Foundation
import os

/// Decides when BrightSync may talk to the displays at all.
///
/// On Apple Silicon every DDC transaction goes through the display
/// coprocessor, which also handles sleep, wake and mode changes, and DDC
/// traffic during those has been linked to hangs. So the gate closes on any
/// such event and reopens only after a quiet period with no further events.
/// Launching counts as an event, because a login item starts while the
/// displays may still be coming up.
final class DisplayGate {
    enum Event: String {
        case reconfigurationBegan = "display change starting"
        case reconfigured = "display changed"
        case screensSlept = "displays went to sleep"
        case screensWoke = "displays woke"
        case systemWillSleep = "Mac going to sleep"
        case systemDidWake = "Mac woke"
        case sessionResigned = "switched to another user"
        case sessionActivated = "switched back to this user"
        case screenLocked = "screen locked"
        case screenUnlocked = "screen unlocked"
        case poweringOff = "Mac shutting down"
    }

    enum State: Equatable {
        case open
        /// Closed until something wakes up; the quiet period starts after that.
        case held(String)
        /// Closed while a condition lasts, such as a call. Conditions end
        /// without an event, so whoever waits checks again now and then.
        case paused(String)
        case settling(remaining: TimeInterval)
    }

    private struct Inner {
        var screensAsleep = false
        var systemAsleep = false
        var sessionInactive = false
        var screenLocked = false
        var poweringOff = false
        var lastEvent: TimeInterval
        var generation = 0
    }

    let quietPeriod: TimeInterval
    private let now: () -> TimeInterval
    private let inner: OSAllocatedUnfairLock<Inner>
    /// Checked every time the state is asked for. Each returns why the gate
    /// should stay closed, or nil.
    private let conditions: [() -> String?]

    /// Seconds since boot. It stops while the Mac sleeps, which is fine: the
    /// gate is closed then, and the quiet period starts at wake.
    static func uptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    init(quietPeriod: TimeInterval = 60, now: @escaping () -> TimeInterval = DisplayGate.uptime,
         conditions: [() -> String?] = []) {
        self.quietPeriod = quietPeriod
        self.now = now
        self.conditions = conditions
        inner = OSAllocatedUnfairLock(initialState: Inner(lastEvent: now()))
    }

    /// Called from the main thread as events arrive; read from the DDC queue
    /// before every transaction, so it never waits behind a sync round.
    func record(_ event: Event) {
        let time = now()
        inner.withLock { state in
            switch event {
            case .screensSlept: state.screensAsleep = true
            case .screensWoke:
                // Screens can only wake on a running Mac.
                state.screensAsleep = false
                state.systemAsleep = false
            case .systemWillSleep: state.systemAsleep = true
            case .systemDidWake: state.systemAsleep = false
            case .sessionResigned: state.sessionInactive = true
            case .sessionActivated: state.sessionInactive = false
            case .screenLocked: state.screenLocked = true
            case .screenUnlocked: state.screenLocked = false
            case .poweringOff: state.poweringOff = true
            case .reconfigurationBegan, .reconfigured: break
            }
            // Locking holds the gate, but neither it nor unlocking changes
            // anything about the displays, so they do not restart the quiet
            // period or make the engine look at the displays afresh.
            if event != .screenLocked, event != .screenUnlocked {
                state.lastEvent = time
                state.generation += 1
            }
        }
    }

    var state: State {
        let time = now()
        let fromEvents: State = inner.withLock { state in
            if state.poweringOff { return .held(Event.poweringOff.rawValue) }
            if state.systemAsleep { return .held("Mac asleep") }
            if state.screensAsleep { return .held("displays asleep") }
            if state.sessionInactive { return .held("another user is active") }
            if state.screenLocked { return .held("screen locked") }
            let remaining = state.lastEvent + quietPeriod - time
            return remaining > 0 ? .settling(remaining: remaining) : .open
        }
        if case .held = fromEvents {
            return fromEvents
        }
        // Outside the lock: a condition may ask Core Audio or the system.
        if let reason = conditions.lazy.compactMap({ $0() }).first {
            return .paused(reason)
        }
        return fromEvents
    }

    var isOpen: Bool { state == .open }

    /// Changes with every event, so anything learned about the displays before
    /// it changed (handles, ranges, current values) can be thrown away.
    var generation: Int { inner.withLock { $0.generation } }
}
