import AppKit
import CoreGraphics

/// Feeds macOS display and power events into the gate, and logs each one so
/// that the log shows what the displays went through next to what was sent.
final class DisplayEvents {
    private let gate: DisplayGate
    private let onEvent: () -> Void
    private var observers: [NSObjectProtocol] = []

    init(gate: DisplayGate, onEvent: @escaping () -> Void) {
        self.gate = gate
        self.onEvent = onEvent
    }

    func start() {
        let workspace: [(Notification.Name, DisplayGate.Event)] = [
            (NSWorkspace.screensDidSleepNotification, .screensSlept),
            (NSWorkspace.screensDidWakeNotification, .screensWoke),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            (NSWorkspace.willPowerOffNotification, .poweringOff),
        ]
        let center = NSWorkspace.shared.notificationCenter
        for (name, event) in workspace {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handle(event, detail: nil)
            })
        }
        // Called once before and once after every change, for each display
        // involved: plugging, unplugging, mode changes, mirroring, and the
        // reconnects some displays go through when they wake.
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())

        // Sleep and wake are only announced when they happen, so a launch
        // while the displays are already dark has to look for itself.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            handle(.screensSlept, detail: "already asleep at launch")
        }
    }

    func stop() {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    fileprivate func handle(_ event: DisplayGate.Event, detail: String?) {
        gate.record(event)
        Log.write("event: \(event.rawValue)\(detail.map { " (\($0))" } ?? "")")
        onEvent()
    }
}

private func displayReconfigured(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags,
                                 userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let events = Unmanaged<DisplayEvents>.fromOpaque(userInfo).takeUnretainedValue()
    let event: DisplayGate.Event = flags.contains(.beginConfigurationFlag) ? .reconfigurationBegan : .reconfigured
    events.handle(event, detail: "display \(display), flags 0x\(String(flags.rawValue, radix: 16))")
}
