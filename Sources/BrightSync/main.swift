import AppKit
import DDCKit

// `--list` prints the displays BrightSync can see, with the identifiers it
// stores in preferences, and reads each one's brightness once. Useful for
// checking what the app is actually matching. Each read is logged like any other.
if CommandLine.arguments.contains("--list") {
    let bus = DDCBus()
    let displays = bus.enumerate()
    if displays.isEmpty {
        print("No DDC-capable displays found.")
    }
    for display in displays {
        let brightness: String
        if !bus.isAvailable(display) {
            brightness = "asleep or offline, not read"
        } else {
            switch bus.read(display, DDCKIT_VCP_BRIGHTNESS) {
            case let .value(current, max): brightness = "\(current)/\(max)"
            case .unsupported: brightness = "unsupported"
            case let .failed(reason): brightness = "unreadable (\(reason))"
            }
        }
        print("\(display.name)  id=\(display.id)  brightness=\(brightness)")
        print("  key: \(display.key)")
    }
    Log.flush()
    exit(0)
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory) // menu bar only, no Dock icon
application.run()
