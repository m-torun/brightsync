import CoreGraphics
import DDCKit
import Foundation

struct DisplayReading {
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

/// Polls the source display and mirrors its brightness — and optionally its
/// colour preset — onto the others.
///
/// All DDC traffic happens on a serial background queue: a single read takes
/// roughly 150 ms, so doing this on the main thread would stutter the menu.
final class SyncEngine {
    private let queue = DispatchQueue(label: "app.brightsync.ddc", qos: .utility)
    private let store = DisplayStore()
    private var timer: DispatchSourceTimer?
    private var lastWritten: [String: Int] = [:]
    /// Colour preset lists are sparse: a display may ignore a value outright,
    /// or substitute a different one. Remember those so we do not rewrite the
    /// same rejected value on every tick.
    private var rejectedPresets: Set<String> = []
    /// Last known source reading, so a key press need not wait on a DDC read.
    private var cachedSource: (key: String, current: Int, max: Int)?
    private var propagateTask: DispatchWorkItem?

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
            self.rejectedPresets = []
            self.cachedSource = nil
            self.tick()
        }
    }

    func syncNow() {
        queue.async { self.tick() }
    }

    /// Moves the source display by a signed fraction of its own range.
    ///
    /// Only the source is written here — propagation to the other displays is
    /// debounced, so holding a brightness key does not queue up a read and a
    /// write per display per keystroke.
    func nudgeSource(by fraction: Double) {
        queue.async {
            guard let source = self.source(from: self.store.displays) else { return }

            let reading: (current: Int, max: Int)
            if let cached = self.cachedSource, cached.key == source.key {
                reading = (cached.current, cached.max)
            } else if let fresh = source.readBrightness() {
                reading = fresh
            } else {
                return
            }

            let step = max(1, Int((Double(reading.max) * abs(fraction)).rounded()))
            let wanted = min(reading.max, max(0, reading.current + (fraction > 0 ? step : -step)))
            guard wanted != reading.current, source.writeBrightness(wanted) else { return }

            self.cachedSource = (source.key, wanted, reading.max)
            self.lastWritten[self.cacheKey(source, DDCKIT_VCP_BRIGHTNESS)] = wanted
            self.schedulePropagation()
        }
    }

    private func schedulePropagation() {
        propagateTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.tick() }
        propagateTask = task
        queue.asyncAfter(deadline: .now() + 0.4, execute: task)
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
        guard let sourceBrightness = source.readBrightness() else {
            status.readings = [DisplayReading(key: source.key, name: source.name, percent: nil,
                                              colorPreset: nil, isSource: true)]
            status.message = "Could not read \(source.name)"
            publish(status)
            return
        }

        // Only pay for the extra round trip when colour syncing is on.
        let sourceColor = Preferences.syncColorTemperature ? source.read(DDCKIT_VCP_COLOR_PRESET) : nil

        cachedSource = (source.key, sourceBrightness.current, sourceBrightness.max)

        let sourcePercent = Int((Double(sourceBrightness.current) / Double(sourceBrightness.max) * 100).rounded())
        status.readings.append(DisplayReading(key: source.key, name: source.name, percent: sourcePercent,
                                              colorPreset: sourceColor?.current, isSource: true))

        for target in displays where target.key != source.key {
            var shownPercent: Int?
            var shownPreset: Int?

            // Brightness is continuous: each panel has its own range, so mirror
            // the proportion rather than the raw value.
            if let targetBrightness = target.readBrightness() {
                let wanted = Int((Double(sourceBrightness.current) / Double(sourceBrightness.max)
                                  * Double(targetBrightness.max)).rounded())
                var value = targetBrightness.current
                if Preferences.isEnabled, abs(targetBrightness.current - wanted) > Preferences.deadband,
                   lastWritten[cacheKey(target, DDCKIT_VCP_BRIGHTNESS)] != wanted {
                    if target.writeBrightness(wanted) {
                        lastWritten[cacheKey(target, DDCKIT_VCP_BRIGHTNESS)] = wanted
                        value = wanted
                    }
                }
                shownPercent = Int((Double(value) / Double(targetBrightness.max) * 100).rounded())
            }

            // The colour preset is enumerated, so it is copied verbatim — and
            // only when this panel's list actually goes that far.
            if let sourceColor, let targetColor = target.read(DDCKIT_VCP_COLOR_PRESET) {
                shownPreset = targetColor.current
                let wanted = sourceColor.current
                if Preferences.isEnabled, wanted != targetColor.current, wanted <= targetColor.max,
                   !rejectedPresets.contains(presetKey(target, wanted)) {
                    target.write(DDCKIT_VCP_COLOR_PRESET, wanted)
                    // Confirm it took: an unsupported preset is silently
                    // ignored or swapped for another, and without this check we
                    // would rewrite it on every tick.
                    if let after = target.read(DDCKIT_VCP_COLOR_PRESET) {
                        shownPreset = after.current
                        if after.current == wanted {
                            lastWritten[cacheKey(target, DDCKIT_VCP_COLOR_PRESET)] = wanted
                        } else {
                            rejectedPresets.insert(presetKey(target, wanted))
                        }
                    }
                }
            }

            status.readings.append(DisplayReading(key: target.key, name: target.name, percent: shownPercent,
                                                  colorPreset: shownPreset, isSource: false))
        }

        status.lastSync = Date()
        publish(status)
    }

    private func cacheKey(_ display: Display, _ vcp: Int32) -> String {
        "\(display.key)#\(vcp)"
    }

    private func presetKey(_ display: Display, _ value: Int) -> String {
        "\(display.key)#preset:\(value)"
    }

    private func publish(_ status: SyncStatus) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }
}
