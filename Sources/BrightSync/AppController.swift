import AppKit
import ServiceManagement

/// Menu bar presence and the small settings menu.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let engine = SyncEngine()
    private var status = SyncStatus()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "BrightSync")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onStatus = { [weak self] status in
            self?.status = status
        }
        Log.write("launch: BrightSync started")
        engine.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func displaysChanged() {
        engine.displaysChanged()
    }

    // MARK: - Menu

    /// Rebuilt each time it opens so the readings are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let message = status.message {
            menu.addItem(disabledItem(message))
        }
        for reading in status.readings {
            var value = reading.percent.map { "\($0)%" } ?? "unreadable"
            if let preset = reading.colorPreset {
                value += " · \(ColorPreset.describe(preset))"
            }
            let label = reading.isSource ? "\(reading.name) — \(value)  (source)"
                                         : "\(reading.name) — \(value)"
            menu.addItem(disabledItem(label))
        }
        if status.readings.isEmpty, status.message == nil {
            menu.addItem(disabledItem("Looking for displays…"))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Sync brightness", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = Preferences.isEnabled ? .on : .off
        menu.addItem(toggle)

        let colorToggle = NSMenuItem(title: "Sync color temperature", action: #selector(toggleColor), keyEquivalent: "")
        colorToggle.target = self
        colorToggle.state = Preferences.syncColorTemperature ? .on : .off
        colorToggle.toolTip = "Mirrors the color preset (VCP 0x14). Preset numbering is only nominally standard, so two vendors may disagree about what a preset means."
        menu.addItem(colorToggle)

        menu.addItem(submenu(title: "Source display", items: sourceItems()))
        menu.addItem(submenu(title: "Check every", items: intervalItems()))

        let syncNow = NSMenuItem(title: "Sync now", action: #selector(syncNow), keyEquivalent: "")
        syncNow.target = self
        menu.addItem(syncNow)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let showLog = NSMenuItem(title: "Reveal log in Finder", action: #selector(revealLog), keyEquivalent: "")
        showLog.target = self
        menu.addItem(showLog)

        let quit = NSMenuItem(title: "Quit BrightSync", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func sourceItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let automatic = NSMenuItem(title: "Main display (automatic)", action: #selector(setAutomaticSource), keyEquivalent: "")
        automatic.target = self
        automatic.state = Preferences.sourceDisplay == nil ? .on : .off
        items.append(automatic)
        items.append(.separator())

        for reading in status.readings {
            let item = NSMenuItem(title: reading.name, action: #selector(setSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = reading.key
            item.state = Preferences.sourceDisplay == reading.key ? .on : .off
            items.append(item)
        }
        return items
    }

    private func intervalItems() -> [NSMenuItem] {
        Preferences.intervalChoices.map { seconds in
            let item = NSMenuItem(title: "\(seconds) seconds", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = Preferences.interval == seconds ? .on : .off
            return item
        }
    }

    private func submenu(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu()
        items.forEach { child.addItem($0) }
        parent.submenu = child
        return parent
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Preferences.isEnabled.toggle()
        engine.syncNow()
    }

    @objc private func toggleColor() {
        Preferences.syncColorTemperature.toggle()
        engine.syncNow()
    }

    @objc private func setAutomaticSource() {
        Preferences.sourceDisplay = nil
        engine.syncNow()
    }

    @objc private func setSource(_ sender: NSMenuItem) {
        Preferences.sourceDisplay = sender.representedObject as? String
        engine.syncNow()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        Preferences.interval = sender.tag
        engine.rescheduleTimer()
    }

    @objc private func syncNow() {
        engine.syncNow()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can also set this in System Settings → General → Login Items."
            alert.runModal()
        }
    }

    @objc private func revealLog() {
        NSWorkspace.shared.selectFile(Log.path, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
