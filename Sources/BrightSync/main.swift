import AppKit

// `--list` prints the displays BrightSync can see, with the identifiers it
// stores in preferences. Useful for checking what the app is actually matching.
if CommandLine.arguments.contains("--list") {
    let store = DisplayStore()
    store.refresh()
    if store.displays.isEmpty {
        print("No DDC-capable displays found.")
    }
    for display in store.displays {
        let brightness = display.readBrightness()
            .map { "\($0.current)/\($0.max)" } ?? "unreadable"
        print("\(display.name)  id=\(display.id)  brightness=\(brightness)")
        print("  key: \(display.key)")
    }
    store.release()
    exit(0)
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory) // menu bar only, no Dock icon
application.run()
