import CoreGraphics
import DDCKit
import Foundation

struct DisplayReading {
    let key: String
    let name: String
    let percent: Int?
    let isSource: Bool
}

struct SyncStatus {
    var readings: [DisplayReading] = []
    var message: String?
    var lastSync: Date?
}

/// Polls the source display and mirrors its brightness onto the others.
///
/// All DDC traffic happens on a serial background queue: a single read takes
/// roughly 150 ms, so doing this on the main thread would stutter the menu.
final class SyncEngine {
    private let queue = DispatchQueue(label: "app.brightsync.ddc", qos: .utility)
    private let store = DisplayStore()
    private var timer: DispatchSourceTimer?
    private var lastWritten: [String: Int] = [:]

    /// Called on the main queue whenever readings change.
    var onStatus: ((SyncStatus) -> Void)?

    func start() {
        queue.async {
            self.store.refresh()
            self.tick()
        }
        rescheduleTimer()
    }

    func rescheduleTimer() {
        queue.async {
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .seconds(Preferences.interval),
                           repeating: .seconds(Preferences.interval))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Displays were plugged, unplugged or rearranged.
    func displaysChanged() {
        queue.async {
            self.store.refresh()
            self.lastWritten = [:]
            self.tick()
        }
    }

    func syncNow() {
        queue.async { self.tick() }
    }

    /// Picks the configured source, falling back to the main display.
    private func source(from displays: [Display]) -> Display? {
        if let configured = Preferences.sourceDisplay,
           let match = displays.first(where: { $0.key == configured }) {
            return match
        }
        let main = CGMainDisplayID()
        return displays.first(where: { $0.id == main }) ?? displays.first
    }

    private func tick() {
        var status = SyncStatus()
        let displays = store.displays

        guard !displays.isEmpty else {
            status.message = "No DDC-capable displays found"
            publish(status)
            return
        }
        guard let source = source(from: displays) else {
            publish(status)
            return
        }
        guard let sourceValue = source.readBrightness() else {
            status.readings = [DisplayReading(key: source.key, name: source.name, percent: nil, isSource: true)]
            status.message = "Could not read \(source.name)"
            publish(status)
            return
        }

        let sourcePercent = Int((Double(sourceValue.current) / Double(sourceValue.max) * 100).rounded())
        status.readings.append(DisplayReading(key: source.key, name: source.name, percent: sourcePercent, isSource: true))

        for target in displays where target.key != source.key {
            // Each panel has its own range, so mirror the proportion rather
            // than the raw value.
            guard let targetValue = target.read(Int32(DDCKIT_VCP_BRIGHTNESS)) else {
                status.readings.append(DisplayReading(key: target.key, name: target.name, percent: nil, isSource: false))
                continue
            }
            let wanted = Int((Double(sourceValue.current) / Double(sourceValue.max) * Double(targetValue.max)).rounded())
            var shown = targetValue.current

            if Preferences.isEnabled, abs(targetValue.current - wanted) > Preferences.deadband,
               lastWritten[target.key] != wanted {
                if target.writeBrightness(wanted) {
                    lastWritten[target.key] = wanted
                    shown = wanted
                }
            }
            let percent = Int((Double(shown) / Double(targetValue.max) * 100).rounded())
            status.readings.append(DisplayReading(key: target.key, name: target.name, percent: percent, isSource: false))
        }

        status.lastSync = Date()
        publish(status)
    }

    private func publish(_ status: SyncStatus) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }
}
