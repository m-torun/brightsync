import Foundation
import CoreGraphics
import DDCKit
@testable import BrightSync

/// A switch a test flips, read by a closure the gate holds.
final class Flag {
    var isOn = false
}

final class FakeClock {
    var time: TimeInterval = 1_000

    func advance(_ seconds: TimeInterval) {
        time += seconds
    }
}

/// A desk of displays that records every DDC transaction sent to it.
final class FakeBus: DisplayBus {
    struct Panel {
        var display: Display
        var brightness: (current: Int, max: Int) = (50, 100)
        var preset: (current: Int, max: Int)? = (5, 12)
        /// Presets the panel silently ignores when written.
        var ignoredPresets: Set<Int> = []
        var asleep = false
        /// Nothing gets through: the request cannot be sent.
        var failing = false
        /// The display answers these codes with an unusable reply.
        var garbled: Set<Int32> = []
    }

    var panels: [Panel]
    private(set) var transactions: [String] = []
    /// Runs after each transaction, to let a test fire an event mid-round.
    var afterTransaction: (() -> Void)?

    init(_ names: String...) {
        panels = names.enumerated().map { index, name in
            Panel(display: Display(id: CGDirectDisplayID(100 + index), name: name, edidUUID: "uuid-\(name)"))
        }
    }

    subscript(name: String) -> Panel {
        get { panels.first { $0.display.name == name }! }
        set { panels[panels.firstIndex { $0.display.name == name }!] = newValue }
    }

    func enumerate() -> [Display] {
        panels.map(\.display)
    }

    func isAvailable(_ display: Display) -> Bool {
        !self[display.name].asleep
    }

    func read(_ display: Display, _ vcp: Int32) -> ReadResult {
        defer { record("read \(display.name) \(vcp)") }
        let panel = self[display.name]
        if panel.failing {
            return .failed("request not sent")
        }
        if panel.garbled.contains(vcp) {
            return .garbled("invalid reply")
        }
        switch vcp {
        case DDCKIT_VCP_BRIGHTNESS:
            return .value(current: panel.brightness.current, max: panel.brightness.max)
        case DDCKIT_VCP_COLOR_PRESET:
            guard let preset = panel.preset else { return .unsupported }
            return .value(current: preset.current, max: preset.max)
        default:
            return .unsupported
        }
    }

    func write(_ display: Display, _ vcp: Int32, _ value: Int) -> Bool {
        defer { record("write \(display.name) \(vcp)=\(value)") }
        var panel = self[display.name]
        if panel.failing {
            return false
        }
        if vcp == DDCKIT_VCP_BRIGHTNESS {
            panel.brightness.current = value
        } else if vcp == DDCKIT_VCP_COLOR_PRESET, !panel.ignoredPresets.contains(value) {
            panel.preset?.current = value
        }
        self[display.name] = panel
        return true
    }

    func reset() {
        transactions = []
    }

    private func record(_ transaction: String) {
        transactions.append(transaction)
        afterTransaction?()
    }
}
