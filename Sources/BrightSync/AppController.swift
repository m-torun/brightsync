import AppKit
import Combine
import SwiftUI

/// The menu bar item: a short menu for the everyday controls, and the
/// Settings window for everything else.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var changes: AnyCancellable?
    /// Kept while the menu is open, so readings can update in place.
    private var menuIsOpen = false
    private var sliderView: SliderMenuView?
    private var followingItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "BrightSync")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        model.start()
        changes = model.objectWillChange.sink { [weak self] _ in
            // Sent before the change lands, so look once it has.
            DispatchQueue.main.async { self?.refreshOpenMenu() }
        }
    }

    // MARK: - Menu

    /// Rebuilt each time it opens so the readings are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sliderView = nil
        followingItem = nil
        // Whatever was wrong may just have been fixed (a permission granted,
        // the bridge plugged back in), so try now rather than after the back-off.
        if model.ambient.problem != nil {
            model.ambient.refresh()
        }

        if let paused = model.pausedReason {
            menu.addItem(disabledItem(paused))
        }
        if model.followsSensor {
            let view = SliderMenuView(title: "Brightness")
            view.onChange = { [weak self] percent, finished in
                self?.model.setBrightness(percent, finished: finished)
            }
            sliderView = view
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            // A problem while there is still a reading would not fit the caption.
            if let problem = model.ambient.problem, model.ambient.selected?.lux != nil {
                menu.addItem(disabledItem(problem))
            }
        } else if let line = model.followingLine {
            followingItem = disabledItem(line)
            menu.addItem(followingItem!)
        }
        if let message = model.status.message, !model.followsSensor {
            menu.addItem(disabledItem(message))
        }
        refreshOpenMenu()

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Sync brightness", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = model.isEnabled ? .on : .off
        menu.addItem(toggle)

        let color = NSMenuItem(title: "Sync color", action: #selector(toggleColor), keyEquivalent: "")
        color.target = self
        color.state = model.syncColor ? .on : .off
        color.toolTip = "Copies the color preset from the display chosen in Settings → Color to the others."
        menu.addItem(color)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit BrightSync", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        sliderView = nil
        followingItem = nil
    }

    /// Updates readings in place while the menu is open, instead of leaving
    /// what was true when it opened.
    private func refreshOpenMenu() {
        sliderView?.show(percent: model.brightness, caption: model.sensorCaption)
        if let line = model.followingLine {
            followingItem?.title = line
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        model.isEnabled.toggle()
    }

    @objc private func toggleColor() {
        model.syncColor.toggle()
    }

    /// Opening the app again while it runs (from Finder or Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.settingsWindow(for: model)
            settingsWindow?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Sized by its content, one tab at a time, and not resizable.
    static func settingsWindow(for model: AppModel) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "BrightSync Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        return window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
