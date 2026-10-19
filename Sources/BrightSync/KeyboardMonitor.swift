import AppKit
import ApplicationServices

/// Captures the keyboard's brightness keys.
///
/// They are not ordinary key presses but system-defined media events, so the
/// only way to see them is a CGEvent tap — which requires Accessibility
/// permission. Without the grant, `CGEvent.tapCreate` simply returns nil.
final class KeyboardMonitor {
    /// Fraction of full range to move, signed. macOS itself uses 16 steps.
    private static let step = 1.0 / 16.0
    private static let fineStep = 1.0 / 64.0

    private static let brightnessUp: Int32 = 2   // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown: Int32 = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let auxControlButtons = 8     // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Called with a signed fraction of the display's range.
    var onBrightnessKey: ((Double) -> Void)?

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility access. This is what puts the app into the
    /// Accessibility list, so the user has a switch to flip instead of having
    /// to add the bundle by hand.
    func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Safe to call repeatedly: it is a no-op while the tap is healthy, and
    /// rebuilds it when macOS has disabled it or when trust has just arrived.
    @discardableResult
    func start() -> Bool {
        if let existing = tap {
            if CGEvent.tapIsEnabled(tap: existing) {
                return true
            }
            Log.write("keyboard: tap was disabled, rebuilding it")
            stop()
        }
        guard AXIsProcessTrusted() else {
            return false // creating a tap untrusted yields a permanently dead one
        }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly, // we observe; macOS keeps handling the key
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("keyboard: tapCreate failed (no Accessibility permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.runLoopSource = source

        // A tap can be created and yet arrive disabled when the permission is
        // stale — typically after a rebuild, since an ad-hoc signature's
        // identity changes with every build.
        var enabled = CGEvent.tapIsEnabled(tap: tap)
        if !enabled {
            CGEvent.tapEnable(tap: tap, enable: true)
            enabled = CGEvent.tapIsEnabled(tap: tap)
        }
        Log.write("keyboard: tap created, trusted=\(AXIsProcessTrusted()) enabled=\(enabled)")
        return enabled
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap) // otherwise a dead tap lingers in the session
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap whose callback is too slow; ours only
        // dispatches, but re-enable defensively rather than go deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("keyboard: system disabled the tap (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // This runs for every system-defined event, including mouse buttons.
        // It must stay cheap: macOS disables a tap whose callback is slow, so
        // nothing here touches the disk.
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtons else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        guard keyCode == Self.brightnessUp || keyCode == Self.brightnessDown else {
            return Unmanaged.passUnretained(event) // volume, mute, play/pause…
        }
        Log.write("keyboard: brightness key code=\(keyCode) down=\(isKeyDown)")
        if isKeyDown {
            let fine = nsEvent.modifierFlags.contains(.shift)
            let magnitude = fine ? Self.fineStep : Self.step
            onBrightnessKey?(keyCode == Self.brightnessUp ? magnitude : -magnitude)
        }
        // Passed along rather than swallowed, so macOS still shows whatever
        // on-screen feedback it normally would for these keys.
        return Unmanaged.passUnretained(event)
    }
}
