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
        guard let sourceBrightness = source.readBrightness() else {
            status.readings = [DisplayReading(key: source.key, name: source.name, percent: nil,
                                              colorPreset: nil, isSource: true)]
            status.message = "Could not read \(source.name)"
            publish(status)
            return
        }

        // Only pay for the extra round trip when colour syncing is on.
        let sourceColor = Preferences.syncColorTemperature ? source.read(DDCKIT_VCP_COLOR_PRESET) : nil

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
