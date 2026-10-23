import AppKit
import CoreGraphics
import IOKit.pwr_mgt

// iokit_common_msg(0x270) and (0x280); the macros do not reach Swift.
private let canSystemSleep: UInt32 = 0xE000_0270
private let systemWillSleep: UInt32 = 0xE000_0280

/// Feeds macOS display and power events into the gate, and logs each one so
/// that the log shows what the displays went through next to what was sent.
final class DisplayEvents {
    private let gate: DisplayGate
    private let onEvent: (DisplayGate.Event) -> Void
    /// Waits for a DDC transaction already under way to finish.
    private let finishTransactions: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var rootPort: io_connect_t = 0
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    init(gate: DisplayGate, finishTransactions: @escaping () -> Void = {},
         onEvent: @escaping (DisplayGate.Event) -> Void) {
        self.gate = gate
        self.finishTransactions = finishTransactions
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
        // Not announced through NSWorkspace. Nobody needs brightness changed
        // behind a lock screen, and the displays may go dark soon after.
        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [("com.apple.screenIsLocked", DisplayGate.Event.screenLocked),
                              ("com.apple.screenIsUnlocked", .screenUnlocked)] {
            lockObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.handle(event, detail: nil)
            })
        }

        // macOS waits for this answer before the Mac sleeps, so the gate can
        // close and a transaction already on the wire can finish first.
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerPort, systemPowerChanged, &powerNotifier)
        if rootPort != 0, let powerPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(powerPort).takeUnretainedValue(), .commonModes)
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
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockObservers = []
        if rootPort != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(powerPort)
            rootPort = 0
        }
    }

    fileprivate func powerMessage(_ type: UInt32, argument: Int) {
        switch type {
        case canSystemSleep:
            IOAllowPowerChange(rootPort, argument)
        case systemWillSleep:
            gate.record(.systemWillSleep)
            let started = DispatchTime.now()
            finishTransactions()
            let waited = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            Log.write("event: \(DisplayGate.Event.systemWillSleep.rawValue) (sleep held \(waited) ms for DDC to finish)")
            Log.flush()
            IOAllowPowerChange(rootPort, argument)
        default:
            break
        }
    }

    fileprivate func handle(_ event: DisplayGate.Event, detail: String?) {
        gate.record(event)
        Log.write("event: \(event.rawValue)\(detail.map { " (\($0))" } ?? "")")
        onEvent(event)
    }
}

private func displayReconfigured(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags,
                                 userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let events = Unmanaged<DisplayEvents>.fromOpaque(userInfo).takeUnretainedValue()
    let event: DisplayGate.Event = flags.contains(.beginConfigurationFlag) ? .reconfigurationBegan : .reconfigured
    events.handle(event, detail: "display \(display), flags 0x\(String(flags.rawValue, radix: 16))")
}

private func systemPowerChanged(refcon: UnsafeMutableRawPointer?, service: io_service_t, messageType: UInt32,
                                messageArgument: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let events = Unmanaged<DisplayEvents>.fromOpaque(refcon).takeUnretainedValue()
    events.powerMessage(messageType, argument: Int(bitPattern: messageArgument))
}
