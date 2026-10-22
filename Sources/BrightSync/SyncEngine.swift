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

/// The settings a round needs, read fresh at the start of each one.
struct SyncSettings {
    var isEnabled = true
    var syncColor = false
    var sourceKey: String?
    var deadband = 1
    var interval: TimeInterval = 30

    static var current: SyncSettings {
        SyncSettings(isEnabled: Preferences.isEnabled,
                     syncColor: Preferences.syncColorTemperature,
                     sourceKey: Preferences.sourceDisplay,
                     deadband: Preferences.deadband,
                     interval: TimeInterval(Preferences.interval))
    }
}

/// Mirrors the source display's brightness, and optionally its colour preset,
/// onto the other displays, while sending as little over DDC as it can:
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
    /// Colour preset lists are sparse: a display may ignore a value or swap in
    /// another. Those are remembered so they are not rewritten every round.
    private var rejectedPresets: Set<String> = []
    private var backoff: [String: (failures: Int, until: TimeInterval)] = [:]

    /// Called on the main queue after each round.
    var onStatus: ((SyncStatus) -> Void)?
    /// The last round's status, on the engine's queue.
    private(set) var lastStatus = SyncStatus()

    init(bus: DisplayBus = DDCBus(),
         gate: DisplayGate = DisplayGate(),
         queue: DispatchQueue = DispatchQueue(label: "app.brightsync.ddc", qos: .utility),
         now: @escaping () -> TimeInterval = DisplayGate.uptime,
         settings: @escaping () -> SyncSettings = { .current },
         log: @escaping (String) -> Void = Log.write) {
        self.bus = bus
        self.gate = gate
        self.queue = queue
        self.now = now
        self.settings = settings
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

    /// Seconds until the next round, or nil to wait for the event that ends a hold.
    func nextDelay() -> TimeInterval? {
        switch gate.state {
        case .held: return nil
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

    /// One round. Runs on the queue; the tests call it directly.
    func tick() {
        guard gate.isOpen else { return }
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
        guard displays.count > 1 else {
            status.message = displays.isEmpty ? "No DDC-capable displays found" : "Only one display: nothing to sync"
            status.readings = displays.map { reading($0, isSource: false) }
            return
        }

        let source = self.source(from: displays)
        let targets = displays.filter { $0.key != source.key }
        status.readings = displays.map { reading($0, isSource: $0.key == source.key) }

        guard let brightness = read(source, DDCKIT_VCP_BRIGHTNESS, fresh: true) else {
            if !aborted {
                status.message = bus.isAvailable(source) ? "Could not read \(source.name)" : "\(source.name) is asleep or offline"
            }
            return
        }
        // Only pay for the extra read when colour syncing is on.
        let sourceColor = round.syncColor ? read(source, DDCKIT_VCP_COLOR_PRESET, fresh: true) : nil

        for target in targets {
            // Brightness is continuous and each panel has its own range, so
            // mirror the proportion rather than the raw value.
            if let current = read(target, DDCKIT_VCP_BRIGHTNESS, fresh: false) {
                let wanted = Int((Double(brightness.current) / Double(brightness.max) * Double(current.max)).rounded())
                if abs(current.current - wanted) > round.deadband {
                    write(target, DDCKIT_VCP_BRIGHTNESS, wanted)
                }
            }
            // The colour preset is enumerated, so it is copied verbatim, and
            // only when this panel's list goes that far.
            if let sourceColor, let current = read(target, DDCKIT_VCP_COLOR_PRESET, fresh: false) {
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

        status.readings = displays.map { reading($0, isSource: $0.key == source.key) }
        if !aborted {
            status.lastSync = Date()
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
    private func source(from displays: [Display]) -> Display {
        if let key = round.sourceKey, let match = displays.first(where: { $0.key == key }) {
            return match
        }
        let main = CGMainDisplayID()
        return displays.first(where: { $0.id == main }) ?? displays[0]
    }

    // MARK: - Guarded transactions

    @discardableResult
    private func read(_ display: Display, _ vcp: Int32, fresh: Bool) -> (current: Int, max: Int)? {
        let key = cacheKey(display, vcp)
        if !fresh, let value = known[key] {
            return value
        }
        guard !unsupported.contains(key), mayTalk(to: display) else { return nil }
        switch bus.read(display, vcp) {
        case let .value(current, max):
            backoff[display.key] = nil
            known[key] = (current, max)
            return (current, max)
        case .unsupported:
            unsupported.insert(key)
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
        if let max = known[key]?.max {
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
