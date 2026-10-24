import CoreGraphics
import DDCKit
import Foundation

struct DisplayReading: Equatable {
    let key: String
    let name: String
    let percent: Int?
    let colorPreset: Int?
    let isSource: Bool
}

struct SyncStatus {
    var readings: [DisplayReading] = []
    var message: String?
    var lastSync: Date?
}

/// Nominal meanings of VCP 0x14 from the MCCS standard. Vendors are free to
/// deviate, so these are shown as hints rather than treated as facts.
enum ColorPreset {
    static func describe(_ value: Int) -> String {
        switch value {
        case 1: return "sRGB"
        case 2: return "native"
        case 3: return "4000K"
        case 4: return "5000K"
        case 5: return "6500K"
        case 6: return "7500K"
        case 7: return "8200K"
        case 8: return "9300K"
        case 9: return "10000K"
        case 10: return "11500K"
        case 11: return "user 1"
        case 12: return "user 2"
        case 13: return "user 3"
        default: return "preset \(value)"
        }
    }
}

/// The brightness a light sensor asks for, in percent.
struct AmbientTarget: Equatable {
    /// For any display not listed in `perDisplay`.
    var percent: Double
    /// By display key, when monitors are adjusted separately.
    var perDisplay: [String: Double] = [:]
    /// Chosen with a slider, so even a one-point change is written.
    var exact = false

    func percent(for display: Display) -> Double {
        perDisplay[display.key] ?? percent
    }
}

/// The settings a round needs, read fresh at the start of each one.
struct SyncSettings {
    var isEnabled = true
    var syncColor = false
    /// The display whose colour preset the others copy; nil for the main display.
    var colorSourceKey: String?
    var sourceKey: String?
    /// Follow a light sensor's brightness target instead of a display.
    var followsSensor = false
    var deadband = 1
    var interval: TimeInterval = 30

    static var current: SyncSettings {
        SyncSettings(isEnabled: Preferences.isEnabled,
                     syncColor: Preferences.syncColorTemperature,
                     colorSourceKey: Preferences.colorSource,
                     sourceKey: Preferences.sourceDisplay,
                     followsSensor: Preferences.sourceSensor != nil,
                     deadband: Preferences.deadband,
                     interval: TimeInterval(Preferences.interval))
    }
}

/// Mirrors the source display's brightness, and optionally its colour preset,
/// onto the other displays, or sets every display to the brightness a light
/// sensor asks for, while sending as little over DDC as it can:
///
/// - nothing while the gate is closed: during sleep, wake and display
///   changes, and for a quiet period after each;
/// - nothing when sync is off or there is no second display;
/// - each round reads only the source. The other displays are read once
///   after they settle, then only written to, and only when the value moves;
/// - a failed transaction is never retried on the spot. That display is left
///   alone for a while, twice as long after each further failure.
///
/// All DDC traffic happens on one serial queue, since a read takes about 100 ms.
final class SyncEngine {
    static let maxBackoff: TimeInterval = 30 * 60
    /// How often a pause (a call, the idle timer running out) is checked again.
    static let pauseRecheck: TimeInterval = 15

    let gate: DisplayGate
    private let bus: DisplayBus
    private let queue: DispatchQueue
    private let now: () -> TimeInterval
    private let settings: () -> SyncSettings
    private let log: (String) -> Void
    private var timer: DispatchSourceTimer?

    private var round = SyncSettings()
    private var aborted = false
    private var settledGeneration: Int?
    private var displays: [Display] = []
    /// Last value read or written, per display and VCP code. Forgotten
    /// whenever the gate sees an event.
    private var known: [String: (current: Int, max: Int)] = [:]
    private var unsupported: Set<String> = []
    /// Each display's brightness range. Unlike its current value, it does not
    /// change, so it is kept across events and launches, and a display whose
    /// range is known is written to without being read first.
    private var ranges: [String: Int]
    private let saveRanges: ([String: Int]) -> Void
    /// Colour preset lists are sparse: a display may ignore a value or swap in
    /// another. Those are remembered so they are not rewritten every round.
    private var rejectedPresets: Set<String> = []
    private var backoff: [String: (failures: Int, until: TimeInterval)] = [:]
    /// Readings that came back unusable, per display and VCP code. Only that
    /// reading waits; writes to the display carry on.
    private var readBackoff: [String: (failures: Int, until: TimeInterval)] = [:]
    /// The brightness a light sensor asks for.
    private var ambient: AmbientTarget?
    private var ambientRoundPending = false
    /// The pause last logged, so each one is logged once.
    private var pausedFor: String?

    /// Called on the main queue after each round.
    var onStatus: ((SyncStatus) -> Void)?
    /// The last round's status, on the engine's queue.
    private(set) var lastStatus = SyncStatus()

    init(bus: DisplayBus = DDCBus(),
         gate: DisplayGate = DisplayGate(),
         queue: DispatchQueue = DispatchQueue(label: "app.brightsync.ddc", qos: .utility),
         now: @escaping () -> TimeInterval = DisplayGate.uptime,
         settings: @escaping () -> SyncSettings = { .current },
         ranges: [String: Int] = Preferences.displayRanges,
         saveRanges: @escaping ([String: Int]) -> Void = { Preferences.displayRanges = $0 },
         log: @escaping (String) -> Void = Log.write) {
        self.bus = bus
        self.gate = gate
        self.queue = queue
        self.now = now
        self.settings = settings
        self.ranges = ranges
        self.saveRanges = saveRanges
        self.log = log
    }

    /// Plans the next round. Call again after any gate event or settings change.
    func schedule() {
        queue.async { self.planNextRound() }
    }

    /// Runs a round as soon as the gate allows, giving displays that failed
    /// another chance.
    func syncNow() {
        queue.async {
            self.backoff = [:]
            self.tick()
        }
    }

    /// Sets the brightness to follow a light sensor, or nil when there is no
    /// reading. Rapid changes, such as a slider being dragged, are coalesced
    /// into one round, and the gate still decides whether it may run.
    func setAmbientTarget(_ target: AmbientTarget?) {
        queue.async {
            self.receiveAmbient(target)
            guard !self.ambientRoundPending else { return }
            self.ambientRoundPending = true
            self.queue.asyncAfter(deadline: .now() + 0.1) {
                self.ambientRoundPending = false
                self.tick()
                self.planNextRound()
            }
        }
    }

    /// Runs on the queue; the tests call it directly.
    func receiveAmbient(_ target: AmbientTarget?) {
        ambient = target
    }

    /// The same target for every display.
    func receiveAmbient(_ percent: Double?, exact: Bool) {
        receiveAmbient(percent.map { AmbientTarget(percent: $0, exact: exact) })
    }

    /// Seconds until the next round, or nil to wait for the event that ends a hold.
    func nextDelay() -> TimeInterval? {
        switch gate.state {
        case .held: return nil
        case .paused: return Self.pauseRecheck
        case let .settling(remaining): return remaining + 0.1
        case .open: return settledGeneration == gate.generation ? settings().interval : 0
        }
    }

    private func planNextRound() {
        timer?.cancel()
        timer = nil
        guard let delay = nextDelay() else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.tick()
            self?.planNextRound()
        }
        timer.resume()
        self.timer = timer
    }

    /// Waits, up to `timeout`, for a transaction already under way. For the
    /// sleep hook, after the gate has closed, so nothing new starts.
    func finishTransactions(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// One round. Runs on the queue; the tests call it directly.
    func tick() {
        let state = gate.state
        if case let .paused(reason) = state, reason != pausedFor {
            log("holding off: \(reason)")
            pausedFor = reason
        } else if state == .open, let reason = pausedFor {
            log("resuming: no longer \(reason)")
            pausedFor = nil
        }
        guard state == .open else { return }
        round = settings()
        aborted = false
        if settledGeneration != gate.generation {
            settle()
        }
        var status = SyncStatus()
        defer { publish(status) }

        guard round.isEnabled else {
            status.message = "Sync is off"
            status.readings = displays.map { reading($0, isSource: false) }
            return
        }
        // Brightness and colour have separate sources: brightness may follow a
        // light sensor while the colour preset follows a display.
        let brightnessSource = round.followsSensor ? nil : source(from: displays)
        let synced = round.followsSensor ? followSensor(&status) : followDisplay(brightnessSource, &status)
        syncColor()

        status.readings = displays.map { reading($0, isSource: $0.key == brightnessSource?.key) }
        if synced, !aborted {
            status.lastSync = Date()
        }
    }

    /// Mirrors the source display's brightness onto the others. Each round
    /// reads only the source.
    private func followDisplay(_ source: Display?, _ status: inout SyncStatus) -> Bool {
        guard let source, displays.count > 1 else {
            status.message = displays.isEmpty ? "No DDC-capable displays found" : "Only one display: nothing to sync"
            return false
        }
        guard let brightness = read(source, DDCKIT_VCP_BRIGHTNESS, fresh: true) else {
            if !aborted {
                status.message = bus.isAvailable(source) ? "Could not read \(source.name)" : "\(source.name) is asleep or offline"
            }
            return false
        }
        for target in displays where target.key != source.key {
            follow(target, fraction: Double(brightness.current) / Double(brightness.max), deadband: round.deadband)
        }
        return true
    }

    /// A light sensor sets the target, so every display follows it, a single
    /// display included, and nothing needs reading but each display's range.
    private func followSensor(_ status: inout SyncStatus) -> Bool {
        guard !displays.isEmpty else {
            status.message = "No DDC-capable displays found"
            return false
        }
        guard let ambient else {
            status.message = "Waiting for a light reading"
            return false
        }
        for display in displays {
            follow(display, fraction: ambient.percent(for: display) / 100, deadband: ambient.exact ? 0 : round.deadband, writeBlind: true)
        }
        return true
    }

    /// Copies the colour preset from its source display to the others, when
    /// that is switched on. The preset is enumerated, so it is copied
    /// verbatim, and only when the target's list goes that far.
    private func syncColor() {
        guard round.syncColor, displays.count > 1,
              let source = displays.first(where: { $0.key == round.colorSourceKey }) ?? mainDisplay(),
              let sourceColor = read(source, DDCKIT_VCP_COLOR_PRESET, fresh: true) else { return }
        for target in displays where target.key != source.key {
            guard let current = read(target, DDCKIT_VCP_COLOR_PRESET, fresh: false) else { continue }
            let wanted = sourceColor.current
            let rejected = rejectedPresets.contains(presetKey(target, wanted))
            if wanted != current.current, wanted <= current.max, !rejected,
               write(target, DDCKIT_VCP_COLOR_PRESET, wanted) {
                // On some panels each preset carries its own brightness.
                known[cacheKey(target, DDCKIT_VCP_BRIGHTNESS)] = nil
                // Confirm it took: an unsupported preset is silently ignored
                // or swapped for another.
                if let after = read(target, DDCKIT_VCP_COLOR_PRESET, fresh: true), after.current != wanted {
                    rejectedPresets.insert(presetKey(target, wanted))
                    log("\(target.name) does not take colour preset \(wanted); it shows \(after.current)")
                }
            }
        }
    }

    /// Brightness is continuous and each panel has its own range, so the
    /// proportion is what is matched, not the raw value. A display is read
    /// once after it settles; after that, only written to.
    private func follow(_ display: Display, fraction: Double, deadband: Int, writeBlind: Bool = false) {
        let key = cacheKey(display, DDCKIT_VCP_BRIGHTNESS)
        if writeBlind, known[key] == nil, let max = ranges[key] {
            // A sensor sets the target, so after an event the display most
            // likely needs it anyway: one write, and no read first that
            // might come back garbled. Following a display, the follower
            // usually still has the right value, so it is read instead of
            // being written to for nothing.
            write(display, DDCKIT_VCP_BRIGHTNESS, Int((fraction * Double(max)).rounded()))
            return
        }
        guard let current = read(display, DDCKIT_VCP_BRIGHTNESS, fresh: false) else { return }
        let wanted = Int((fraction * Double(current.max)).rounded())
        if abs(current.current - wanted) > deadband {
            write(display, DDCKIT_VCP_BRIGHTNESS, wanted)
        }
    }

    /// Re-resolves the displays after the gate has been through an event.
    /// Only the I/O registry is consulted; nothing goes over DDC.
    private func settle() {
        displays = bus.enumerate()
        known = [:]
        unsupported = []
        settledGeneration = gate.generation
        let names = displays.isEmpty ? "no DDC-capable displays" : displays.map(\.name).joined(separator: ", ")
        log("displays settled: \(names)")
    }

    /// Picks the configured source, falling back to the main display.
    private func source(from displays: [Display]) -> Display? {
        if let key = round.sourceKey, let match = displays.first(where: { $0.key == key }) {
            return match
        }
        return mainDisplay()
    }

    private func mainDisplay() -> Display? {
        let main = CGMainDisplayID()
        return displays.first(where: { $0.id == main }) ?? displays.first
    }

    // MARK: - Guarded transactions

    @discardableResult
    private func read(_ display: Display, _ vcp: Int32, fresh: Bool) -> (current: Int, max: Int)? {
        let key = cacheKey(display, vcp)
        if !fresh, let value = known[key] {
            return value
        }
        if let wait = readBackoff[key], now() < wait.until {
            return nil
        }
        guard !unsupported.contains(key), mayTalk(to: display) else { return nil }
        switch bus.read(display, vcp) {
        case let .value(current, max):
            backoff[display.key] = nil
            readBackoff[key] = nil
            known[key] = (current, max)
            if vcp == DDCKIT_VCP_BRIGHTNESS, ranges[key] != max {
                ranges[key] = max
                saveRanges(ranges)
            }
            return (current, max)
        case .unsupported:
            unsupported.insert(key)
            return nil
        case .garbled:
            garbled(display, vcp)
            return nil
        case .failed:
            failed(display)
            return nil
        }
    }

    @discardableResult
    private func write(_ display: Display, _ vcp: Int32, _ value: Int) -> Bool {
        guard mayTalk(to: display) else { return false }
        guard bus.write(display, vcp, value) else {
            failed(display)
            return false
        }
        backoff[display.key] = nil
        let key = cacheKey(display, vcp)
        if let max = known[key]?.max ?? (vcp == DDCKIT_VCP_BRIGHTNESS ? ranges[key] : nil) {
            known[key] = (value, max)
        }
        return true
    }

    /// Checked before every single transaction, so an event that arrives in
    /// the middle of a round stops the rest of it.
    private func mayTalk(to display: Display) -> Bool {
        if aborted {
            return false
        }
        guard gate.isOpen, gate.generation == settledGeneration else {
            aborted = true
            return false
        }
        if let wait = backoff[display.key], now() < wait.until {
            return false
        }
        return bus.isAvailable(display)
    }

    /// An unusable reply is read again next round, then less and less often
    /// while it keeps happening.
    private func garbled(_ display: Display, _ vcp: Int32) {
        let key = cacheKey(display, vcp)
        let failures = (readBackoff[key]?.failures ?? 0) + 1
        let delay = min(round.interval * pow(2, Double(failures - 1)), Self.maxBackoff)
        readBackoff[key] = (failures, now() + delay)
        if failures > 1 {
            log("reading \(display.name) \(String(format: "0x%02X", vcp)) again in \(Int(delay)) s after \(failures) unusable replies")
        }
    }

    private func failed(_ display: Display) {
        let failures = (backoff[display.key]?.failures ?? 0) + 1
        let delay = min(round.interval * pow(2, Double(failures)), Self.maxBackoff)
        backoff[display.key] = (failures, now() + delay)
        log("leaving \(display.name) alone for \(Int(delay)) s after \(failures) failed attempt\(failures == 1 ? "" : "s")")
    }

    // MARK: - Helpers

    private func reading(_ display: Display, isSource: Bool) -> DisplayReading {
        let brightness = known[cacheKey(display, DDCKIT_VCP_BRIGHTNESS)]
        return DisplayReading(key: display.key, name: display.name,
                              percent: brightness.map { Int((Double($0.current) / Double($0.max) * 100).rounded()) },
                              colorPreset: known[cacheKey(display, DDCKIT_VCP_COLOR_PRESET)]?.current,
                              isSource: isSource)
    }

    private func cacheKey(_ display: Display, _ vcp: Int32) -> String {
        "\(display.key)#\(vcp)"
    }

    private func presetKey(_ display: Display, _ value: Int) -> String {
        "\(display.key)#preset:\(value)"
    }

    private func publish(_ status: SyncStatus) {
        lastStatus = status
        DispatchQueue.main.async { self.onStatus?(status) }
    }
}
