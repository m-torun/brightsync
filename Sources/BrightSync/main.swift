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
            case let .garbled(reason), let .failed(reason): brightness = "unreadable (\(reason))"
            }
        }
        print("\(display.name)  id=\(display.id)  brightness=\(brightness)")
        print("  key: \(display.key)")
    }
    Log.flush()
    exit(0)
}

// `--read <code>...` reads the given VCP codes (hex) once from each display,
// e.g. `--read 0x14 0x0C`, to see what a monitor reports beyond brightness.
if let flag = CommandLine.arguments.firstIndex(of: "--read") {
    let codes = CommandLine.arguments.dropFirst(flag + 1).compactMap { Int32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
    let bus = DDCBus()
    for display in bus.enumerate() where bus.isAvailable(display) {
        for code in codes {
            let value: String
            switch bus.read(display, code) {
            case let .value(current, max): value = "\(current)/\(max)"
            case .unsupported: value = "unsupported"
            case let .garbled(reason), let .failed(reason): value = "unreadable (\(reason))"
            }
            print("\(display.name)  \(String(format: "0x%02X", code)) = \(value)")
        }
    }
    Log.flush()
    exit(0)
}

// `--sensors [seconds]` lists the light sensors on paired Hue bridges with
// their current reading, then keeps printing readings as they arrive for that
// many seconds. The same code path as the app, so it also checks pairing,
// the Keychain and the bridge's certificate.
if let flag = CommandLine.arguments.firstIndex(of: "--sensors") {
    let watch = CommandLine.arguments.dropFirst(flag + 1).first.flatMap(TimeInterval.init) ?? 0
    let hue = HueProvider()
    hue.start()
    guard hue.isPaired else {
        print("No Hue bridge is paired. Pair one from the menu: Brightness source → Pair Hue Bridge…")
        exit(1)
    }
    var shown: [String: String] = [:]
    var lastProblem: String?
    hue.onChange = {
        let time = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        for sensor in hue.sensors where shown[sensor.id] != HueBridge.format(sensor.lux) {
            shown[sensor.id] = HueBridge.format(sensor.lux)
            print("\(time)  \(sensor.name): \(HueBridge.format(sensor.lux)) lux  [\(sensor.id)]")
        }
        if hue.problem != lastProblem, let problem = hue.problem {
            print("\(time)  \(problem)")
        }
        lastProblem = hue.problem
        if watch == 0, !hue.sensors.isEmpty {
            Log.flush()
            exit(0)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(watch, 15)) {
        Log.flush()
        exit(hue.sensors.isEmpty ? 1 : 0)
    }
    dispatchMain()
}

// `--snapshot-settings <folder>` draws each Settings tab, filled with made-up
// displays and a demo sensor, into PNG files. For checking the layout without
// a screen recording permission. The demo settings live in the arguments
// domain, which is never saved, so the real preferences are not touched.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
   let folder = CommandLine.arguments.dropFirst(flag + 1).first {
    final class DemoSensors: LightSensorProvider {
        let name = "Philips Hue"
        let sensors = [LightSensor(id: "demo:desk", name: "Desk sensor", lux: 120, updated: Date())]
        let problem: String? = nil
        let activity: String? = nil
        var onChange: (() -> Void)?
        func start() {}
        func refresh() {}
        func addSensors() {}
    }
    // `--display` shows brightness following a display instead of the sensor,
    // `--separate` a slider per monitor.
    let following = CommandLine.arguments.contains("--display")
    let separate = CommandLine.arguments.contains("--separate")
    var demo: [String: Any] = [
        "sourceDisplayKey": "uuid-dell",
        "colorSourceKey": "uuid-dell",
        "syncColorTemperature": true,
        "adjustMonitorsTogether": !separate,
        "brightnessOffset": 10.0,
        "displayBrightnessOffsets": ["uuid-dell": 10.0, "uuid-lenovo": -5.0],
    ]
    if !following {
        demo["sourceSensorID"] = "demo:desk"
    }

    // `--not-reached` draws it before any display has been reached, as
    // just after a launch; the displays come from the ones seen last time.
    let notReached = CommandLine.arguments.contains("--not-reached")
    if notReached {
        demo["knownDisplays"] = [["uuid-dell", "DELL U3225QE"], ["uuid-lenovo", "LEN T27p-10"]]
    }
    UserDefaults.standard.setVolatileDomain(demo, forName: UserDefaults.argumentDomain)

    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = AppModel(providers: [DemoSensors()])
    model.show(SyncStatus(readings: notReached ? [] : [
        DisplayReading(key: "uuid-dell", name: "DELL U3225QE", percent: 80, colorPreset: 5, isSource: following),
        DisplayReading(key: "uuid-lenovo", name: "LEN T27p-10", percent: 80, colorPreset: 5, isSource: false),
    ]))
    let suffix = (following ? "-display" : "") + (separate ? "-separate" : "") + (notReached ? "-not-reached" : "")
    // Light mode on the window's own background, whatever the Mac is set to.
    func save(_ view: NSView, as name: String) {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let canvas = NSImage(size: view.bounds.size)
        canvas.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        image.draw(in: view.bounds)
        canvas.unlockFocus()
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)\(suffix).png")
        guard let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("\(url.path)  \(Int(view.bounds.width))×\(Int(view.bounds.height))")
    }
    NSApp.appearance = NSAppearance(named: .aqua)

    let window = AppController.settingsWindow(for: model)
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFrontRegardless()
    for tab in SettingsView.Tab.allCases {
        model.settingsTab = tab
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let view = window.contentView {
            save(view, as: "settings-\(tab)")
        }
    }

    // The menu's sliders, as the menu would stack them.
    let keys: [String?] = separate ? ["uuid-dell", "uuid-lenovo"] : [nil]
    let sliders = keys.enumerated().map { index, key -> NSView in
        let view = SliderMenuView(title: "Brightness", offsetRange: BrightnessOffsets.range, captioned: index == keys.count - 1)
        let name = key == "uuid-dell" ? "DELL U3225QE" : key == "uuid-lenovo" ? "LEN T27p-10" : "Brightness"
        view.show(offset: model.offsets.offset(for: key ?? ""), title: name + " · \(model.resultPercent(for: key) ?? 0)%",
                  caption: model.lightCaption + " — applies in 42 s")
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view.heightAnchor.constraint(equalToConstant: view.frame.height).isActive = true
        return view
    }
    let stack = NSStackView(views: sliders)
    stack.orientation = .vertical
    stack.spacing = 0
    let menuWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
    menuWindow.contentView = stack
    menuWindow.setContentSize(stack.fittingSize)
    menuWindow.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    save(stack, as: "menu-sliders")
    exit(0)
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory) // menu bar only, no Dock icon
application.run()
