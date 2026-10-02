import AppKit
import HUDKit

/// The umbrella bits of MacHUD that sit on top of the external panel registry:
/// the shared settings window (`settings-window`), the status menu's "Apps" section
/// (Launch All, Quit All and Relaunch Outdated, then each discovered app with Show, its own
/// status menu fetched live, park/reveal, its settings, Relaunch and Quit/Launch), and the
/// toast for a panel that opened somewhere the user cannot see it.
@MainActor
final class MacHUDServices: NSObject {
    let externals: ExternalPanels
    let host: MacHUDPanelHost
    let settingsWindow = SettingsWindowController()

    init(externals: ExternalPanels, host: MacHUDPanelHost) {
        self.externals = externals
        self.host = host
        super.init()
        settingsWindow.sources = { [weak self] in self?.settingsSources() ?? [] }
        settingsWindow.launch = { [weak self] id in
            guard let self, let app = self.externals.app(matching: id) else { return }
            _ = self.externals.launch(app, manual: true)
        }
        externals.supervisor.onShowMissed = { [weak self] appID, _, outcome in self?.showMissed(appID, outcome) }
    }

    /// A clicked or summoned panel is not on this desktop: say where it went and what fixes it.
    private func showMissed(_ appID: String, _ outcome: ShowOutcome) {
        let name = externals.app(matching: appID)?.name ?? appID
        let outdated = externals.supervisor.buildStatus(appID)?.outdated != nil
        Toast.show(MacHUDMenuModel.missedText(name, outcome),
                   detail: "Fix: Relaunch \(name) (MacHUD menu › \(name))" + (outdated ? ", it runs an older build" : ""),
                   seconds: 4)
    }

    /// MacHUD itself first, then every discovered app by name.
    func settingsSources() -> [SettingsSource] {
        var out = [SettingsSource(id: "machud", title: "MacHUD", symbol: "rectangle.3.group",
                                  socketPath: ControlServer.socketPath, bundleSchema: MacHUDSettings.schema,
                                  isRunning: true, canLaunch: false)]
        for app in externals.apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            out.append(SettingsSource(id: app.id, title: app.name, symbol: app.manifest.panels.first?.symbol ?? "app",
                                      socketPath: app.socketPath,
                                      bundleSchema: HUDSettingsSchema.load(manifest: app.manifest, bundleURL: app.bundleURL),
                                      isRunning: externals.supervisor.record(app.id)?.health == .running,
                                      canLaunch: true))
        }
        return out
    }

    // MARK: - Control

    /// `settings-window show|hide|toggle|state [tab=<id, name, voice, brain or apps>] [activate=0]`. `show`
    /// answers once every tab has loaded, with what each tab shows.
    func registerControl(_ control: HUDSocketServer) {
        control.register("settings-window") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            let action = args["action"] ?? ["show", "hide", "toggle", "state"].first { args[$0] != nil } ?? "state"
            let activate = !["0", "false", "no"].contains((args["activate"] ?? "1").lowercased())
            let show = { self.settingsWindow.show(select: args["tab"], activate: activate) {
                done(["ok": true].merging(self.settingsWindow.json) { a, _ in a })
            } }
            switch action {
            case "show": show()
            case "toggle":
                if self.settingsWindow.isVisible { self.settingsWindow.hide(); done(["ok": true, "visible": false]) } else { show() }
            case "hide":
                self.settingsWindow.hide()
                done(["ok": true, "visible": false])
            case "state":
                done(["ok": true].merging(self.settingsWindow.json) { a, _ in a })
            default:
                done(["ok": false, "error": "settings-window action must be show, hide, toggle or state"])
            }
        }
    }

    // MARK: - Menu

    /// Brings an app's panel forward (the tool dock's summon); falls back to showing it.
    var summon: ((String) -> Void)?
    /// Whether the Apps section shows each app's own menu (`menuBar.consumeSiblings`).
    var liveMenus: () -> Bool = { true }
    /// Per-app submenu delegates of the menu currently built, by app id.
    private var submenus: [String: AppSubmenu] = [:]
    /// Each running app's build status, read once per menu build (it reads files) and
    /// reused as its submenu is filled and refilled.
    private var buildStatuses: [String: AppBuildStatus] = [:]
    private func cachedStatus(_ id: String) -> AppBuildStatus? { buildStatuses[id] }

    /// The status menu's Apps section: Launch All and Quit All (and Relaunch Outdated Apps
    /// while an app runs an older build than its bundle on disk), then a submenu per
    /// discovered app with "Show <App>", the app's own status menu (fetched live), MacHUD's
    /// controls for it, Relaunch, and Quit or Launch.
    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        let bulk = MacHUDMenuModel.bulk(externals: externals)
        buildStatuses = [:]
        for app in externals.apps {
            if let status = externals.supervisor.buildStatus(app.id) { buildStatuses[app.id] = status }
        }
        var bulkItems = [("Launch All Apps", bulk.canLaunch, #selector(launchAll)),
                         ("Quit All Apps", bulk.canQuit, #selector(quitAll))]
        if MacHUDMenuModel.hasOutdated(externals: externals, buildStatus: cachedStatus) {
            bulkItems.append(("Relaunch Outdated Apps", true, #selector(relaunchOutdated)))
        }
        for (title, enabled, selector) in bulkItems {
            let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            mi.target = self
            mi.isEnabled = enabled
            items.append(mi)
        }
        let live = liveMenus()
        let entries = MacHUDMenuModel.entries(externals: externals, liveMenus: live, buildStatus: cachedStatus,
                                              mode: { [host] in host.mode(of: $0) })
        if entries.isEmpty {
            let none = NSMenuItem(title: "No MacHUD apps found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        submenus = [:]
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            let controller = AppSubmenu(appID: entry.appID, menu: sub, services: self)
            sub.delegate = controller
            submenus[entry.appID] = controller
            fill(sub, appID: entry.appID)
            item.submenu = sub
            items.append(item)
        }
        let getApps = NSMenuItem(title: "Get Apps…", action: #selector(openApps), keyEquivalent: "")
        getApps.target = self
        items.append(getApps)
        // Ask every running app for its menu now, so it is there when a submenu opens.
        if live { externals.menus.refreshRunning() }
        return items
    }

    /// (Re)builds one app's submenu from the model and the cached app menu.
    func fill(_ menu: NSMenu, appID: String) {
        menu.removeAllItems()
        let live = liveMenus()
        guard let entry = MacHUDMenuModel.entries(externals: externals, liveMenus: live, buildStatus: cachedStatus,
                                                  mode: { [host] in host.mode(of: $0) }).first(where: { $0.appID == appID })
        else { return }
        for action in entry.actions {
            switch action.kind {
            case .separator:
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            case .status:
                let status = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
            case .appMenu:
                let cached = externals.menus.entry(appID)
                let items = AppMenus.filtered(cached?.items ?? [])
                if cached == nil {
                    let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
                    loading.isEnabled = false
                    menu.addItem(loading)
                }
                for mi in AppMenus.menuItems(items, appID: appID, target: self, action: #selector(appMenuAction(_:))) {
                    menu.addItem(mi)
                }
            default:
                let mi = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = action
                if let on = action.isOn { mi.state = on ? .on : .off }
                mi.isEnabled = action.isEnabled
                menu.addItem(mi)
            }
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    /// An app's menu arrived: refresh its submenu if it is part of the menu on screen.
    func appMenuUpdated(_ appID: String) {
        guard let controller = submenus[appID] else { return }
        fill(controller.menu, appID: appID)
    }

    /// The submenu is opening: show what is cached and fetch a fresh copy if it is stale.
    fileprivate func submenuWillOpen(_ appID: String) {
        guard liveMenus(), !externals.menus.isFresh(appID) else { return }
        externals.menus.refresh(appID)
    }

    @objc private func openApps() { settingsWindow.show(select: AppsTabModel.tabID) }

    @objc private func launchAll() {
        let failed = externals.launchAll().compactMapValues { result -> String? in
            if case .failure(let error) = result { return error.description } else { return nil }
        }
        guard !failed.isEmpty else { return }
        let names = failed.keys.map { externals.app(matching: $0)?.name ?? $0 }.sorted()
        Toast.show("Could not launch \(names.joined(separator: ", "))", detail: failed.values.sorted().joined(separator: "\n"))
    }

    @objc private func quitAll() { externals.quitAll() }

    @objc private func relaunchOutdated() {
        externals.relaunchAll(outdatedOnly: true) { [weak self] results in self?.reportRelaunch(results) }
    }

    /// Toasts the apps a relaunch could not bring back; a clean relaunch is its own feedback.
    private func reportRelaunch(_ results: [String: [String: Any]]) {
        let failed = results.compactMapValues { $0["error"] as? String }
        guard !failed.isEmpty else { return }
        let names = failed.keys.map { externals.app(matching: $0)?.name ?? $0 }.sorted()
        Toast.show("Could not relaunch \(names.joined(separator: ", "))", detail: failed.values.sorted().joined(separator: "\n"))
    }

    @objc private func appMenuAction(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? AppMenuRef else { return }
        let name = externals.app(matching: ref.appID)?.name ?? ref.appID
        externals.menus.invoke(ref.appID, item: ref.item.id, title: ref.item.title) { result in
            if case .failure(let error) = result {
                NSLog("MacHUD: %@ menu item '%@' failed: %@", name, ref.item.title, "\(error)")
                Toast.show("\(name): \(ref.item.title)", detail: "\(error)")
            }
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MacHUDMenuModel.Action,
              let app = externals.app(matching: action.appID) else { return }
        switch action.kind {
        case .status, .separator, .appMenu: break
        case .launch: _ = externals.launch(app, manual: true)
        case .quit: externals.supervisor.quit(app.id) { _ in }
        case .relaunch: externals.relaunch(app.id) { [weak self] in self?.reportRelaunch([app.id: $0]) }
        case .summon:
            if let summon { summon(action.panelID ?? "") } else { externals.registry.show(action.panelID ?? "") }
        case .show: externals.registry.show(action.panelID ?? "")
        case .hide: externals.registry.hide(action.panelID ?? "")
        case .park, .reveal:
            guard let panelID = action.panelID else { return }
            let edge = externals.config().placement(for: app.id)?.edge
            let peek = externals.config().placement(for: app.id)?.peek.map { CGFloat($0) }
            do {
                try host.setPanelMode(panelID, mode: action.kind == .park ? .parked : .full,
                                      options: HUDPanelModeOptions(edge: edge, peek: peek))
            } catch {
                Toast.show("Could not \(action.kind == .park ? "park" : "reveal") \(app.name)", detail: "\(error)")
            }
        case .settings: settingsWindow.show(select: app.id)
        case .dockToggle:
            var config = externals.config()
            var entry = config.perApp[app.id] ?? AppEntryConfig()
            entry.dock = config.hiddenFromDock.contains(app.id) ? nil : false
            config.perApp[app.id] = entry == AppEntryConfig() ? nil : entry
            externals.saveConfig?(config)
        }
    }
}

/// Delegate of one app's submenu in the Apps section.
@MainActor
final class AppSubmenu: NSObject, NSMenuDelegate {
    let appID: String
    let menu: NSMenu
    private weak var services: MacHUDServices?

    init(appID: String, menu: NSMenu, services: MacHUDServices) {
        self.appID = appID
        self.menu = menu
        self.services = services
    }

    func menuNeedsUpdate(_ menu: NSMenu) { services?.fill(menu, appID: appID) }
    func menuWillOpen(_ menu: NSMenu) { services?.submenuWillOpen(appID) }
}

/// What the Apps section lists per app. Pure apart from reading the registry, so it is
/// unit tested.
enum MacHUDMenuModel {
    final class Action: NSObject {
        enum Kind: Equatable {
            case status, launch, quit, relaunch, summon, show, hide, park, reveal, settings
            /// "Show on Tool Dock": a checkmark item.
            case dockToggle
            /// Where the app's own menu goes; `separator` between groups.
            case appMenu, separator
        }
        let kind: Kind
        let title: String
        let appID: String
        let panelID: String?
        /// Checkmark state, for toggles.
        let isOn: Bool?
        let isEnabled: Bool

        init(_ kind: Kind, _ title: String, appID: String, panelID: String? = nil, isOn: Bool? = nil,
             isEnabled: Bool = true) {
            self.kind = kind
            self.title = title
            self.appID = appID
            self.panelID = panelID
            self.isOn = isOn
            self.isEnabled = isEnabled
        }
    }

    /// Whether Launch All and Quit All have anything to do.
    @MainActor
    static func bulk(externals: ExternalPanels) -> (canLaunch: Bool, canQuit: Bool) {
        let up = externals.apps.map { externals.isUp($0.id) }
        return (up.contains(false), up.contains(true))
    }

    struct Entry {
        var appID: String
        var title: String
        var symbol: String
        var actions: [Action]
    }

    /// Whether any app runs an older build than its bundle on disk (Relaunch Outdated Apps).
    /// `buildStatus` defaults to reading it now.
    @MainActor
    static func hasOutdated(externals: ExternalPanels, buildStatus: ((String) -> AppBuildStatus?)? = nil) -> Bool {
        let status = buildStatus ?? externals.supervisor.buildStatus
        return externals.apps.contains { status($0.id)?.outdated != nil }
    }

    /// The toast for a shown panel that is not on this desktop.
    static func missedText(_ name: String, _ outcome: ShowOutcome) -> String {
        outcome == .anotherDesktop ? "\(name)'s panel opened on another desktop" : "\(name)'s panel did not reach the screen"
    }

    /// Per app: "Show <App>" (summon) per panel; status lines (health unless simply running
    /// or stopped, an update waiting for a relaunch, an older contract, a panel that opened
    /// out of sight); the app's own menu (`liveMenus`, running apps only); hide/park/reveal
    /// per panel; whether it is on the tool dock; its settings; then Relaunch (while it is
    /// up, disabled while one runs) and Quit, or Launch. `buildStatus` defaults to reading it now.
    @MainActor
    static func entries(externals: ExternalPanels, liveMenus: Bool = true,
                        buildStatus: ((String) -> AppBuildStatus?)? = nil, mode: (Panel) -> HUDPanelMode) -> [Entry] {
        let hiddenFromDock = externals.config().hiddenFromDock
        let buildStatus = buildStatus ?? externals.supervisor.buildStatus
        return externals.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { app in
            let health = externals.supervisor.record(app.id)?.health ?? .notRunning
            let running = health == .running
            let panels = app.manifest.panels.compactMap {
                externals.registry.panel(id: ExternalPanel.id(app: app.id, panel: $0.id)) as? ExternalPanel
            }
            var actions: [Action] = []
            for panel in panels {
                let suffix = panels.count > 1 ? " \(panel.title)" : ""
                actions.append(Action(.summon, "Show \(app.name)\(suffix)", appID: app.id, panelID: panel.id))
            }
            if health != .running && health != .notRunning {
                actions.append(Action(.status, statusText(health), appID: app.id))
            }
            if let build = buildStatus(app.id) {
                if build.outdated != nil { actions.append(Action(.status, "Update ready, relaunch to apply", appID: app.id)) }
                if build.contract?.older == true { actions.append(Action(.status, "Built for an older MacHUD", appID: app.id)) }
            }
            let checks = externals.supervisor.record(app.id)?.showChecks ?? [:]
            for panel in panels where panel.isVisible {
                guard let check = checks[panel.panelID], !check.isOnScreen else { continue }
                actions.append(Action(.status, check == .anotherDesktop ? "Panel opened on another desktop" : "Panel is off screen",
                                      appID: app.id, panelID: panel.id))
            }
            actions.append(Action(.separator, "", appID: app.id))
            if liveMenus && running {
                actions.append(Action(.appMenu, "", appID: app.id))
                actions.append(Action(.separator, "", appID: app.id))
            }
            for panel in panels {
                let suffix = panels.count > 1 ? " \(panel.title)" : ""
                if mode(panel) == .parked {
                    actions.append(Action(.reveal, "Reveal\(suffix)", appID: app.id, panelID: panel.id))
                } else {
                    if panel.isVisible { actions.append(Action(.hide, "Hide\(suffix)", appID: app.id, panelID: panel.id)) }
                    // Parking needs the app to be listening; showing launches it.
                    if running { actions.append(Action(.park, "Park\(suffix)", appID: app.id, panelID: panel.id)) }
                }
            }
            actions.append(Action(.dockToggle, "Show on Tool Dock", appID: app.id, isOn: !hiddenFromDock.contains(app.id)))
            actions.append(Action(.settings, "\(app.name) Settings…", appID: app.id))
            actions.append(Action(.separator, "", appID: app.id))
            if externals.isUp(app.id) {
                actions.append(Action(.relaunch, "Relaunch \(app.name)", appID: app.id,
                                      isEnabled: externals.supervisor.record(app.id)?.relaunching != true))
                actions.append(Action(.quit, "Quit \(app.name)", appID: app.id))
            } else {
                actions.append(Action(.launch, "Launch \(app.name)", appID: app.id))
            }
            let dot = running ? "●" : "○"
            return Entry(appID: app.id, title: "\(dot) \(app.name)",
                         symbol: app.manifest.panels.first?.symbol ?? "app", actions: actions)
        }
    }

    static func statusText(_ health: AppSupervisor.Health) -> String {
        switch health {
        case .running: return "Running"
        case .socketUnreachable: return "Running (not answering)"
        case .launching: return "Launching…"
        case .notRunning: return "Not running"
        case .notInstalled: return "Not installed"
        }
    }
}
