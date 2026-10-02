import AppKit
import HUDKit
import ServiceManagement

/// The menu bar menu. Top to bottom: MacHUD itself (snapping, login item, permissions,
/// settings), the menu bar manager and MacHUD's own panels, Loadouts, the apps with the tool
/// dock they live on, Advanced, Quit.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let store: LayoutStore
    private let item: NSStatusItem
    private let menu = NSMenu()
    var openEditor: (() -> Void)?
    /// The settings window.
    var openSettings: (() -> Void)?
    /// MacHUD's own HUD: the menu bar manager and its own panels. Each closure is invoked
    /// every time the menu opens.
    var hudSections: [() -> [NSMenuItem]] = []
    /// Loadouts.
    var primarySection: (() -> [NSMenuItem])?
    /// The sibling apps (their own menus included) and Get Apps….
    var appsSection: (() -> [NSMenuItem])?
    /// The tool dock the apps sit on, right after them.
    var toolDockSection: (() -> [NSMenuItem])?
    /// The Widgets submenu, after Tool Dock.
    var widgetsSection: (() -> [NSMenuItem])?

    init(store: LayoutStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let img = HUDStatusIcon.image(fallbackSymbol: "rectangle.3.group", accessibilityDescription: "MacHUD") {
            item.button?.image = img
        } else {
            item.button?.title = "⌗"
        }
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // MacHUD itself.
        let trig = store.trigger
        let enabledTitle = trig == .always ? "Snap While Dragging" : "Snap While Dragging with \(trig.symbol) Held"
        let enabled = NSMenuItem(title: enabledTitle, action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = store.enabled ? .on : .off
        menu.addItem(enabled)

        let triggerItem = NSMenuItem(title: "Trigger Key", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for t in Trigger.allCases {
            let mi = NSMenuItem(title: t.title, action: #selector(selectTrigger(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.rawValue
            mi.state = (t == trig) ? .on : .off
            triggerMenu.addItem(mi)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        for item in Permissions.menuItems() { menu.addItem(item) }
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        if let err = store.loadError {
            let e = NSMenuItem(title: "Config error: \(err.prefix(80))", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
            menu.addItem(.separator())
        }

        // The HUD: menu bar manager, MacHUD's own panels.
        var hudItems: [NSMenuItem] = []
        for section in hudSections { hudItems += section() }
        if !hudItems.isEmpty {
            for item in hudItems { menu.addItem(item) }
            menu.addItem(.separator())
        }

        // Loadouts.
        if let items = primarySection?(), !items.isEmpty {
            for item in items { menu.addItem(item) }
            menu.addItem(.separator())
        }

        // The tool dock, then the apps that live on it under their own header.
        var appItems = toolDockSection?() ?? []
        appItems += widgetsSection?() ?? []
        appItems += appsSection?() ?? []
        if !appItems.isEmpty {
            for item in appItems { menu.addItem(item) }
            menu.addItem(.separator())
        }

        menu.addItem(advancedItem())
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// The config file itself.
    private func advancedItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, selector, key) in [("Edit layouts.json…", #selector(editLayouts), ""),
                                       ("Reveal layouts.json in Finder", #selector(revealLayouts), ""),
                                       ("Reload Config", #selector(reload), "r")] {
            let mi = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            mi.target = self
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func toggleEnabled() { store.enabled.toggle() }
    @objc private func showSettings() { openSettings?() }
    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = Trigger(rawValue: raw) else { return }
        store.setTrigger(t)
    }
    @objc private func editLayouts() { NSWorkspace.shared.open(LayoutStore.configURL) }
    @objc private func revealLayouts() { NSWorkspace.shared.activateFileViewerSelecting([LayoutStore.configURL]) }
    @objc private func reload() { store.load() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MacHUD: launch at login failed: %@", "\(error)")
        }
    }
}
