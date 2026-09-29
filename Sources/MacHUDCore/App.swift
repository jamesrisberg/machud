import AppKit
import HUDKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: LayoutStore!
    private var monitor: DragMonitor!
    private var statusMenu: StatusMenu!
    private var editor: LayoutEditorController!
    private var panels: PanelRegistry!
    private var engine: LoadoutEngine!
    private var control: ControlServer!
    private var hudHost: MacHUDPanelHost!
    private var router: HUDControlRouter!
    private var externals: ExternalPanels!
    private var machud: MacHUDServices!
    private var catalog: CatalogServices!
    private var displays: DisplayWatcher!
    private var menuBar: MenuBarManager!
    private var menuHost: MenuHostPublisher!
    private var toolDock: ToolDock!
    private var sessions: SessionsBroker!
    private var feed: FeedBroker!
    private var voice: VoiceServices!
    private var onboarding: OnboardingServices!
    private var startup: StartupLoadout?
    private var library: LoadoutLibrary!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HUDEditMenu.install(appName: "MacHUD")
        store = LayoutStore()
        panels = PanelRegistry()
        engine = LoadoutEngine(store: store, panels: panels)
        library = LoadoutLibrary(store: store)
        library.onEdit = { [weak engine] edit, result in engine?.loadoutEdited(edit, result) }
        monitor = DragMonitor(store: store)
        statusMenu = StatusMenu(store: store)
        editor = LayoutEditorController(store: store)
        control = ControlServer()
        // MacHUD contract (hello, panel, state, subscribe, settings, action, quit) first, so
        // MacHUD's own commands below extend it.
        hudHost = MacHUDPanelHost(registry: panels, parking: engine.parking)
        hudHost.ownSettings = MacHUDSettings(store: store, parking: engine.parking)
        router = HUDControlRouter(host: hudHost, server: control)
        router.install()
        registerControlCommands()
        // Other MacHUD-aware apps' panels, found through their machud.json.
        externals = ExternalPanels(registry: panels) { [weak store] in store?.config.discoveryApps ?? AppsConfig() }
        externals.placer = { [weak engine] app, placement in
            // Not `engine?.apply... ?? "gone"`: a nil (success) result would read as failure.
            guard let engine else { return "engine gone" }
            return engine.applyDefaultPlacement(app, placement)
        }
        externals.onAppStopped = { [weak engine] app in engine?.parking.forgetCooperative(socketPath: app.socketPath) }
        externals.autoLaunches = Env.autoApply
        externals.registerControl(control)
        externals.saveConfig = { [weak store] apps in
            guard let store else { return }
            var config = store.config
            var apps = apps
            // The externals see `discoveryApps` (catalog.installDir added to searchPaths);
            // keep the stored search paths as they were written.
            apps.searchPaths = config.apps?.searchPaths
            config.apps = apps
            store.save(config)
        }
        externals.rescan()
        externals.startWatching()
        sessions = SessionsBroker(externals: externals)
        sessions.registerControl(control)
        feed = FeedBroker(externals: externals)
        feed.registerControl(control)
        machud = MacHUDServices(externals: externals, host: hudHost)
        machud.registerControl(control)
        installCatalog()
        installVoice()
        installMenuBar()
        installToolDock()
        installMenuHost()
        installOnboarding()
        // Every visibility change (socket, hotkey, menu, close button, sibling push)
        // reaches `subscribe`rs, not only the ones made through the socket.
        panels.onStateChange = { [weak router, weak toolDock] in
            router?.publishState()
            toolDock?.refresh()
        }
        // An announced, forgotten or newly installed app: push `state` and rebuild the dock
        // now, even when no panel's visibility changed.
        externals.onAppsChanged = { [weak router, weak toolDock] in
            router?.publishState()
            toolDock?.refresh()
        }
        control.start()
        displays = DisplayWatcher { [weak self] in self?.displaysChanged() }
        displays.start()
        editor.panelChoicesProvider = { [weak panels] in panels.map { PanelChoice.all(in: $0) } ?? [] }
        editor.captureProvider = { [weak engine] layout in engine?.capture(name: "", layout: layout).slots ?? [] }
        if !Env.noHotkeys {
            if let hk = store.hotkeys.dock {
                HotKeyCenter.shared.register(hk, onPress: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let dock = self?.toolDock else { return }
                        dock.setEnabled(!dock.config().isEnabled)
                    }
                })
            }
        }
        statusMenu.hudSections.append { [weak onboarding] in onboarding.map { [$0.menuItem()] } ?? [] }
        statusMenu.hudSections.append { [weak menuBar] in menuBar?.menuItems() ?? [] }
        statusMenu.hudSections.append { [weak voice] in voice.map { [$0.menuItem()] } ?? [] }
        statusMenu.hudSections.append { [weak panels] in
            // Sibling apps' panels are in the Apps section below.
            (panels?.panels ?? []).filter { !($0 is ExternalPanel) && !($0 is MenuBarPanel) && !($0 is ToolDock) }.map { p in
                let item = NSMenuItem(title: (p.isVisible ? "Hide " : "Show ") + p.title, action: #selector(PanelMenuTarget.toggle(_:)), keyEquivalent: "")
                item.target = PanelMenuTarget.shared
                item.representedObject = p.id
                return item
            }
        }
        PanelMenuTarget.shared.registry = panels
        statusMenu.toolDockSection = { [weak toolDock] in toolDock?.statusMenuItems() ?? [] }
        statusMenu.appsSection = { [weak machud] in machud?.menuItems() ?? [] }
        statusMenu.openSettings = { [weak machud] in machud?.settingsWindow.show() }
        AXWindow.ownWindowFilter = { [weak panels] w in panels?.panels.contains { $0.window === w } ?? false }
        editor.onClose = { [weak self] in self?.monitor.suspended = false }
        let openEditor: () -> Void = { [weak self] in
            guard let self else { return }
            self.monitor.suspended = true
            self.editor.open()
        }
        statusMenu.openEditor = openEditor
        monitor.onNoLayout = {
            Toast.ask("No layout, open the editor?", button: "Open Editor", seconds: 5) { openEditor() }
        }

        let loadoutMenu = LoadoutMenu.install(store: store, engine: engine, statusMenu: statusMenu, control: control)
        loadoutMenu.openEditor = openEditor
        loadoutMenu.openNewLayout = { [weak self] in
            guard let self else { return }
            self.monitor.suspended = true
            self.editor.openNew()
        }
        loadoutMenu.editLoadout = { [weak self] name in
            guard let self else { return }
            self.monitor.suspended = true
            self.editor.open(loadout: name)
        }
        loadoutMenu.library = library
        installLoadoutsTab(loadoutMenu)
        scheduleStartupLoadout()

        if CommandLine.arguments.contains("--edit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.statusMenu.openEditor?() }
        }

        if !Env.dragMonitor {
            NSLog("MacHUD: isolated instance, not watching window drags (MACHUD_DRAG=1 to enable)")
        // An isolated dev/test instance never raises the system prompt; it just waits. Neither
        // does a launch that shows the onboarding: its Permissions step asks.
        } else if Env.isIsolated || onboarding.wantsLaunch ? Accessibility.isTrusted : Accessibility.requestTrust() {
            monitor.start()
        } else {
            // Wait for the user to grant access in System Settings, then start.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, Accessibility.isTrusted else { return }
                    t.invalidate()
                    self.monitor.start()
                }
            }
        }
    }
}

extension AppDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        voice?.stop()
        toolDock?.withdraw()
        menuHost?.withdraw()
    }

    /// `startupLoadout`, about two seconds in, once the siblings it names are listening.
    fileprivate func scheduleStartupLoadout() {
        guard let name = store.config.startupLoadout, !name.isEmpty else { return }
        guard Env.autoApply else {
            NSLog("MacHUD: isolated instance, not applying startup loadout '%@' (MACHUD_APPLY_STARTUP=1 to apply)", name)
            return
        }
        let supervisor = externals.supervisor
        let startup = StartupLoadout(schedule: supervisor.schedule, loadout: { [weak store] in
            store?.config.startupLoadout.flatMap { store?.loadout(named: $0) }
        }, isRunning: { [weak supervisor] id in !(supervisor?.livePIDs(id).isEmpty ?? true) },
           isReachable: { [weak supervisor] id in supervisor?.record(id)?.health == .running },
           apply: { [weak engine] loadout in
            NSLog("MacHUD: applying startup loadout '%@'", loadout.name)
            engine?.apply(loadout, clear: false) { report in
                NSLog("MacHUD: startup loadout '%@': %@", loadout.name, "\(report.json)")
            }
        })
        startup.start()
        self.startup = startup
    }
}

/// Menu target for "Show/Hide <panel>" items contributed to the status menu.
@MainActor
final class PanelMenuTarget: NSObject {
    static let shared = PanelMenuTarget()
    var registry: PanelRegistry?
    @objc func toggle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        registry?.toggle(id)
    }
}

extension AppDelegate {
    /// Control-socket commands that only need the store and engine.
    fileprivate func registerControlCommands() {
        control.register("ping") { _, done in done(["ok": true, "pid": Int(getpid())]) }
        control.register("reload") { [store] _, done in store!.load(); done(["ok": true]) }
        control.register("layouts") { [store] _, done in
            done(["ok": true, "active": store!.activeLayout?.name ?? "",
                  "layouts": store!.layouts.map { ["name": $0.name, "hidden": $0.hidden ?? false, "regions": $0.regions.map { r in
                    ["id": r.id ?? "", "name": r.name ?? "", "x": r.x, "y": r.y, "w": r.w, "h": r.h] }] }])
        }
        control.register("loadouts") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            done(self.library.handle(args))
        }
        control.register("select-layout") { [store] args, done in
            guard let name = args["name"], let i = store!.layouts.firstIndex(where: { $0.name == name }) else {
                done(["ok": false, "error": "no such layout"]); return
            }
            store!.select(index: i); done(["ok": true])
        }
        // `edit` opens the editor; `loadout=<name>` on that loadout's layout, `new=1` on a blank one.
        control.register("edit") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            if let name = args["loadout"] {
                guard self.store.loadout(named: name) != nil else { done(["ok": false, "error": "no such loadout"]); return }
                LoadoutMenu.shared?.editLoadout?(name)
            } else if ["1", "true", "yes"].contains((args["new"] ?? "0").lowercased()) {
                LoadoutMenu.shared?.openNewLayout?()
            } else {
                self.statusMenu.openEditor?()
            }
            done(["ok": true])
        }
        control.register("apply") { [weak self] args, done in
            guard let self, let name = args["loadout"], let loadout = self.store.loadout(named: name) else {
                done(["ok": false, "error": "no such loadout"]); return
            }
            let clear = ["1", "true", "yes"].contains((args["clear"] ?? "0").lowercased())
            let screen = args["screen"].flatMap { ScreenRef.parse($0)?.resolve() }
            if ["1", "true", "yes"].contains((args["plan"] ?? "0").lowercased()) {
                done(self.engine.planJSON(loadout, screen: screen)); return
            }
            self.engine.apply(loadout, clear: clear, screen: screen) { report in done(report.json) }
        }
        control.register("windows") { [weak self] _, done in
            done(["ok": true, "windows": self?.engine.windows().map { $0.json } ?? []])
        }
        control.register("panels") { [weak self] _, done in
            done(["ok": true, "panels": self?.panels.panels.map { panel -> [String: Any] in
                if let external = panel as? ExternalPanel { return external.json }
                return ["id": panel.id, "title": panel.title, "visible": panel.isVisible]
            } ?? []])
        }
        // The contract's `panel` verb, also accepting an external panel's short id
        // (`portal` for `xyz.viawormhole.wormhole/portal`) when it is unambiguous.
        control.register("panel") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            var args = args
            if let id = args["id"], let panel = self.panels.panel(id: id) { args["id"] = panel.id }
            self.router.handle("panel", args: args, done: done)
        }
        control.register("permissions") { args, done in
            let request = ["1", "true", "yes"].contains((args["request"] ?? "0").lowercased())
            done((request ? Permissions.requestAll() : Permissions.report()).json)
        }
        engine.registerControl(control)
    }
}

extension AppDelegate {
    /// Menu bar management: the `menubar` verb and panel, the ⌃⌥B hotkey, and the status
    /// items (only while `menuBar.enabled`). Follows layouts.json edits.
    fileprivate func installMenuBar() {
        let manager = MenuBarManager(items: StatusBarItems(), probe: SystemMenuBarProbe())
        if !Env.noHotkeys {
            manager.registerHotkey = { hk, press in HotKeyCenter.shared.register(hk, onPress: press) }
            manager.unregisterHotkey = { HotKeyCenter.shared.unregister($0) }
        }
        manager.persist = { [weak store] config in
            guard let store else { return }
            var c = store.config
            c.menuBar = config
            store.save(c)
        }
        manager.onChange = { [weak panels] in panels?.noteChange() }
        manager.registerControl(control)
        panels.register(MenuBarPanel(manager: manager))
        manager.configure(store.menuBar, hotkeys: store.config.hotkeys)
        // DragMonitor and the loadout menu chain onChange too; keep theirs.
        let previous = store.onChange
        store.onChange = { [weak store, weak manager] in
            previous?()
            guard let store else { return }
            MainActor.assumeIsolated { manager?.configure(store.menuBar, hotkeys: store.config.hotkeys) }
        }
        menuBar = manager
    }

    /// The settings window's Loadouts tab: reads the store, edits through the library, and
    /// applies, previews, captures and edits through the loadout menu's own entry points.
    fileprivate func installLoadoutsTab(_ menu: LoadoutMenu) {
        let tab = LoadoutsTabModel(services: .init(
            config: { [weak store] in store?.config ?? .defaults },
            displays: { LoadoutSketch.Display.attached() },
            activeLoadout: { [weak engine] in engine?.activeLoadout },
            perform: { [weak library] edit in
                guard let library else { throw LoadoutEditError.noSuchLoadout("") }
                return try library.perform(edit)
            },
            apply: { [weak menu, weak store] name in
                guard let loadout = store?.loadout(named: name) else { return }
                menu?.apply(loadout, clear: false)
            },
            preview: { [weak menu, weak store] name in
                guard let loadout = store?.loadout(named: name) else { return }
                menu?.preview(loadout)
            },
            edit: { [weak menu] name in menu?.editLoadout?(name) },
            capture: { [weak menu] in menu?.captureCurrent() },
            drawNew: { [weak menu] in menu?.openNewLayout?() }))
        machud.settingsWindow.model.loadouts = tab
        let previous = store.onChange
        store.onChange = { [weak tab] in
            previous?()
            MainActor.assumeIsolated { tab?.reload() }
        }
        tab.reload()
    }

    /// The app catalog, the installer (`catalog`, `apps install`) and the Apps tab.
    fileprivate func installCatalog() {
        let appCatalog = AppCatalog { [weak store] in store?.config.catalog ?? CatalogConfig() }
        catalog = CatalogServices(externals: externals, catalog: appCatalog)
        catalog.showTab = { [weak machud] in machud?.settingsWindow.show(select: AppsTabModel.tabID) }
        machud.settingsWindow.model.apps = catalog.tab
        machud.settingsWindow.onShow = { [weak catalog] in
            catalog?.reloadTab()
            catalog?.catalog.refreshIfStale()
        }
        externals.installActions = { [weak catalog] action, args, done in
            guard let catalog else { done(["ok": false, "error": "app gone"]); return }
            catalog.handleApps(action, args, done: done)
        }
        catalog.registerControl(control)
        appCatalog.start()
    }

    /// The built-in voice host: MacHUD runs it as a child process (`VoiceHostSupervisor`),
    /// forwards `voice …` to its socket, and adds the Voice and Brain settings tabs and the
    /// status menu's Voice submenu.
    fileprivate func installVoice() {
        let services = VoiceServices.live()
        services.openSettings = { [weak machud] tab in machud?.settingsWindow.show(select: tab) }
        services.registerControl(control)
        machud.settingsWindow.model.voice = services.settingsModel
        voice = services
        services.start()
    }

    /// First-run onboarding: the full-screen overlay at launch until it is finished or skipped,
    /// Setup Guide… in the menu, and the `onboarding` verb. After the tool dock, which its
    /// Tool dock section drives.
    fileprivate func installOnboarding() {
        let model = OnboardingModel(voice: voice, apps: catalog.tab, permissions: LiveOnboardingPermissions())
        model.hotkeys = OnboardingHotkeys(radialWheel: store.hotkeys.loadoutMenu?.display ?? "the wheel hotkey",
                                          toolDock: store.hotkeys.dock?.display ?? "the dock hotkey")
        model.toolDock = LiveOnboardingToolDock(dock: toolDock)
        model.loadouts = LiveOnboardingLoadouts(engine: engine, store: store)
        let services = OnboardingServices(model: model, presenter: OnboardingWindowController())
        services.prepareApps = { [weak catalog] in
            catalog?.preselectBundled()
            catalog?.reloadTab()
        }
        services.registerControl(control)
        onboarding = services
        // After the catalog and the voice host have had a moment to come up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak services] in
            MainActor.assumeIsolated { _ = services?.showIfNeeded() }
        }
    }

    /// The tool dock: registered as the `tooldock` panel, with its socket verbs, following
    /// layouts.json edits, the discovered apps and what is parked.
    fileprivate func installToolDock() {
        let dock = ToolDock(registry: panels, externals: externals, config: { [weak store] in
            store?.toolDock ?? ToolDockConfig()
        }, saveConfig: { [weak store] config in
            guard let store else { return }
            var c = store.config
            c.toolDock = config
            store.save(c)
        })
        dock.host = hudHost
        dock.dockRegistry = HUDDockRegistry(url: ToolDock.registryURL)
        dock.parking = engine.parking
        dock.regions = { [weak store] in
            (store?.activeLayout?.regions ?? []).enumerated().map { i, r in (r.name ?? "Region \(i + 1)", r.frame) }
        }
        dock.openSettings = { [weak machud] id in machud?.settingsWindow.show(select: id) }
        dock.registerControl(control)
        panels.register(dock)
        engine.parking.onParkedChange = { [weak dock] in dock?.refresh() }
        let previous = store.onChange
        store.onChange = { [weak dock] in
            previous?()
            MainActor.assumeIsolated { dock?.refresh() }
        }
        toolDock = dock
        engine.hudEngine = HUDLoadoutEngine(externals: externals, dockPosition: { [weak dock] in
            dock?.config().dockPosition
        }, setDockPosition: { [weak dock] position in dock?.position(position) })
        dock.refresh()
    }

    /// Menu bar consolidation: `host.json` tells the siblings whether to hide their status
    /// items (`menuBar.consumeSiblings`), the Apps section shows their menus, and "Show <App>"
    /// summons through the tool dock. `menu-host` reports it.
    fileprivate func installMenuHost() {
        let publisher = MenuHostPublisher()
        publisher.start(hostsMenus: store.menuBar.consumesSiblings)
        menuHost = publisher
        machud.liveMenus = { [weak store] in store?.menuBar.consumesSiblings ?? true }
        machud.summon = { [weak toolDock, weak panels] id in
            guard let panel = panels?.panel(id: id) else { return }
            if let toolDock { _ = toolDock.summon(panel) } else { _ = panels?.show(id) }
        }
        externals.menus.onUpdate = { [weak machud] id in machud?.appMenuUpdated(id) }
        let previous = store.onChange
        store.onChange = { [weak store, weak publisher] in
            previous?()
            guard let store else { return }
            MainActor.assumeIsolated { publisher?.update(hostsMenus: store.menuBar.consumesSiblings) }
        }
        control.register("menu-host") { [weak store, weak publisher] _, done in
            var r: [String: Any] = ["ok": true, "consumeSiblings": store?.menuBar.consumesSiblings ?? true]
            if let publisher { r.merge(publisher.json) { a, _ in a } }
            done(r)
        }
    }

    /// The set of attached displays changed: pin by-name references to the displays now
    /// present, then put the active loadout back where it belongs (not in an isolated
    /// instance; see `Env.autoApply`).
    fileprivate func displaysChanged() {
        toolDock.refresh()
        store.pinDisplays()
        guard Env.autoApply, let name = engine.activeLoadout, let loadout = store.loadout(named: name) else { return }
        engine.apply(loadout, clear: false) { report in
            NSLog("MacHUD: displays changed, re-applied %@: %d placed, %d failed",
                  name, report.placed.count, report.failed.count)
            Toast.show("Displays changed", detail: "Re-applied \(name)")
        }
    }
}

/// Process entry point, called from the thin `MacHUD` executable.
public enum MacHUDApp {
    public static func main() -> Never {
        // `MacHUD ctl <command> [key=value...]` talks to the running instance and exits.
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "ctl" {
            exit(ControlClient.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
        exit(0)
    }
}
