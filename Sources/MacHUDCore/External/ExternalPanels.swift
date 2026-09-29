import AppKit
import HUDKit

/// Discovers MacHUD-aware apps, registers their panels in the `PanelRegistry` and serves
/// the `apps` control command.
@MainActor
final class ExternalPanels {
    let registry: PanelRegistry
    let supervisor: AppSupervisor
    /// The apps' own status menus (`menu`/`menu-invoke` on their sockets).
    let menus: AppMenus
    /// Current `apps` config (read from layouts.json on every scan).
    var config: () -> AppsConfig
    private(set) var apps: [ExternalApp] = []
    private(set) var failures: [HUDManifestScanner.Failure] = []
    /// Ids declared by more than one bundle (the one in use first), from the last scan.
    private(set) var duplicates: [String: [URL]] = [:]
    var excluding: Set<String> = ExternalAppCatalog.ownIDs
    /// The bundles an app is running from, for choosing between duplicates (tests replace it).
    var runningBundles: (String) -> [URL] = ExternalAppCatalog.runningBundleURLs
    /// Persists a changed `apps` config (`known` after an announce, forget or vanished
    /// bundle). Wired to the layout store; nil in tests that do not care.
    var saveConfig: ((AppsConfig) -> Void)?
    /// Called after an announce or forget changed what is registered, so the app pushes a
    /// `state` event and the tool dock rebuilds at once.
    var onAppsChanged: (() -> Void)?
    /// false: `autoLaunch` apps are neither launched, relaunched nor placed (an isolated
    /// instance; see `Env.autoApply`).
    var autoLaunches = true
    /// Rescans when an app appears in, leaves or is replaced in a watched directory.
    private(set) var watcher: AppDirectoryWatcher?
    /// Puts an app's panel where its `apps.<id>.placement` says (wired to the loadout
    /// engine). Returns why it could not, or nil.
    var placer: ((ExternalApp, AppPlacement) -> String?)?
    /// Apps MacHUD launched that get their default placement once they are listening,
    /// with when the launch was asked for.
    private(set) var pendingPlacement: [String: Date] = [:]
    /// Outcome of the last default placement per app, for `apps`.
    private(set) var placementResults: [String: String] = [:]
    /// How long a launched app has to start listening before its placement is dropped.
    static let placementTimeout: TimeInterval = 30
    /// Pause between the app listening and placing it, so its window exists.
    static let placementDelay: TimeInterval = 0.4

    init(registry: PanelRegistry, supervisor: AppSupervisor? = nil, config: @escaping () -> AppsConfig) {
        self.registry = registry
        let supervisor = supervisor ?? AppSupervisor()
        self.supervisor = supervisor
        menus = AppMenus(supervisor: supervisor)
        self.config = config
        supervisor.onChange = { [weak self, weak registry] id in
            registry?.noteChange()
            self?.supervisorChanged(id)
        }
    }

    // MARK: - Default placement

    /// Launches a discovered app (as `apps launch` does). A launch that starts the app
    /// queues its configured placement. Returns the launch error, or what happens next
    /// with the placement: `pending`, `none` (not configured) or `running` (already up,
    /// left where it is).
    func launch(_ app: ExternalApp, manual: Bool) -> Result<String, AppSupervisor.LaunchError> {
        let wasRunning = !supervisor.livePIDs(app.id).isEmpty
        if let error = supervisor.launch(app.id, manual: manual) { return .failure(error) }
        if wasRunning { return .success("running") }
        guard config().placement(for: app.id) != nil else { return .success("none") }
        pendingPlacement[app.id] = supervisor.now()
        supervisorChanged(app.id)
        return .success("pending")
    }

    /// Applies the app's configured placement now. Returns the error, if any.
    func place(_ app: ExternalApp) -> String? {
        pendingPlacement[app.id] = nil
        guard let placement = config().placement(for: app.id) else { return "no placement configured for \(app.id)" }
        guard let placer else { return "placement is not available" }
        let error = placer(app, placement)
        placementResults[app.id] = error ?? "applied"
        if let error { NSLog("MacHUD: default placement of %@ failed: %@", app.id, error) }
        return error
    }

    /// `apps install|update|uninstall` (the catalog installer), when wired up.
    var installActions: ((String, [String: String], @escaping ([String: Any]) -> Void) -> Void)?

    /// Called when an app stops running (quit, crashed), so what MacHUD holds for its
    /// panels (parked slots, orbs) can go.
    var onAppStopped: ((ExternalApp) -> Void)?

    private func supervisorChanged(_ id: String) {
        if let health = supervisor.record(id)?.health, health == .notRunning || health == .notInstalled,
           let app = apps.first(where: { $0.id == id }) {
            onAppStopped?(app)
        }
        guard let asked = pendingPlacement[id] else { return }
        if supervisor.now().timeIntervalSince(asked) > Self.placementTimeout {
            pendingPlacement[id] = nil
            placementResults[id] = "timed out waiting for the app to listen"
            return
        }
        guard supervisor.record(id)?.health == .running, let app = apps.first(where: { $0.id == id }) else { return }
        pendingPlacement[id] = nil
        placementResults[id] = "pending"
        supervisor.schedule(Self.placementDelay) { [weak self] in _ = self?.place(app) }
    }

    /// Scan the search directories and known bundles and bring the registry and supervisor
    /// in line. Known bundles that are gone are dropped from the config (logged, not an error).
    func rescan() {
        var config = self.config()
        let result = ExternalAppCatalog.discover(config, excluding: excluding, running: runningBundles)
        failures = result.failures
        duplicates = result.duplicates
        for failure in result.failures {
            NSLog("MacHUD: bad machud.json in %@: %@", failure.bundleURL.path, failure.reason)
        }
        if !result.vanished.isEmpty {
            for path in result.vanished { NSLog("MacHUD: known app %@ is gone; forgetting it", path) }
            let gone = Set(result.vanished)
            config.known = (config.known ?? []).filter { !gone.contains($0) }
            if config.known?.isEmpty == true { config.known = nil }
            saveConfig?(config)
        }
        install(result.apps, autoLaunch: Set(config.autoLaunch ?? []))
        watcher?.watch(ExternalAppCatalog.watchedDirectories(config))
    }

    /// Starts rescanning on changes in the app directories (debounced by `debounce` s).
    func startWatching(debounce: TimeInterval = 1) {
        let watcher = AppDirectoryWatcher(debounce: debounce) { [weak self] in
            guard let self else { return }
            let before = self.apps
            self.rescan()
            if self.apps != before { self.onAppsChanged?() }
        }
        self.watcher = watcher
        watcher.watch(ExternalAppCatalog.watchedDirectories(config()))
    }

    // MARK: - Announce / forget

    /// `apps announce path=`: registers the bundle now (even outside the search paths) and
    /// remembers it in `apps.known`. Announcing a bundle that is already known and in use is
    /// a no-op (`changed: false`), which is what an app's own launch announcement usually is.
    func announce(path rawPath: String) -> [String: Any] {
        let bundle = ExternalAppCatalog.bundleURL(rawPath)
        let manifestURL = HUDManifest.manifestURL(inBundleAt: bundle)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return ["ok": false, "error": "no Contents/Resources/machud.json in \(bundle.path)"]
        }
        let manifest: HUDManifest
        do { manifest = try HUDManifest.load(fromBundleAt: bundle) } catch {
            return ["ok": false, "error": "bad machud.json in \(bundle.path): \(error)"]
        }
        if excluding.contains(manifest.id) {
            return ["ok": true, "id": manifest.id, "changed": false, "ignored": "MacHUD itself"]
        }
        var config = self.config()
        let target = ExternalAppCatalog.canonicalPath(bundle)
        let isKnown = (config.known ?? []).contains { ExternalAppCatalog.canonicalPath(ExternalAppCatalog.bundleURL($0)) == target }
        if !isKnown {
            config.known = (config.known ?? []) + [bundle.path]
            saveConfig?(config)
        }
        let before = apps
        rescan()
        let changed = !isKnown || apps != before
        if changed { onAppsChanged?() }
        var r: [String: Any] = ["ok": true, "id": manifest.id, "changed": changed]
        if let app = apps.first(where: { $0.id == manifest.id }) {
            r["bundle"] = app.bundleURL.path
            r["active"] = ExternalAppCatalog.canonicalPath(app.bundleURL) == target
        }
        if let dups = duplicates[manifest.id] { r["duplicates"] = dups.map(\.path) }
        return r
    }

    /// `apps forget path=`: drops the bundle from `apps.known` and rescans (it stays
    /// registered only if a search directory still finds it).
    func forget(path rawPath: String) -> [String: Any] {
        var config = self.config()
        let target = ExternalAppCatalog.canonicalPath(ExternalAppCatalog.bundleURL(rawPath))
        let known = config.known ?? []
        let kept = known.filter { ExternalAppCatalog.canonicalPath(ExternalAppCatalog.bundleURL($0)) != target }
        let forgotten = kept.count != known.count
        if forgotten {
            config.known = kept.isEmpty ? nil : kept
            saveConfig?(config)
        }
        let before = apps
        rescan()
        if forgotten || apps != before { onAppsChanged?() }
        return ["ok": true, "forgotten": forgotten, "apps": json]
    }

    /// `duplicates` for `apps`: id → every bundle declaring it, the one in use first.
    var duplicatesJSON: [String: [String]] { duplicates.mapValues { $0.map(\.path) } }

    /// Registers `apps` (replacing any earlier set). Split from `rescan` for tests.
    func install(_ apps: [ExternalApp], autoLaunch configured: Set<String>) {
        let autoLaunch = autoLaunches ? configured : []
        self.apps = apps
        let wanted = Set(apps.flatMap { app in app.manifest.panels.map { ExternalPanel.id(app: app.id, panel: $0.id) } })
        registry.unregister { panel in
            guard let external = panel as? ExternalPanel else { return false }
            // Re-register panels whose app moved or whose manifest changed.
            return !wanted.contains(external.id) || !apps.contains(external.app)
        }
        // autoLaunch apps MacHUD is about to start get their default placement too.
        let placements = config()
        for app in apps where autoLaunch.contains(app.id) && placements.placement(for: app.id) != nil
            && supervisor.livePIDs(app.id).isEmpty && supervisor.record(app.id)?.health != .launching {
            pendingPlacement[app.id] = supervisor.now()
        }
        supervisor.update(apps: apps, autoLaunch: autoLaunch)
        for app in apps {
            for descriptor in app.manifest.panels {
                let id = ExternalPanel.id(app: app.id, panel: descriptor.id)
                if let existing = registry.panel(id: id) as? ExternalPanel, existing.app == app,
                   existing.descriptor == descriptor { continue }
                registry.register(ExternalPanel(app: app, descriptor: descriptor, supervisor: supervisor))
            }
        }
    }

    /// Bundle id, or app name (case-insensitive).
    func app(matching key: String) -> ExternalApp? {
        apps.first { $0.id == key } ?? apps.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    var json: [[String: Any]] {
        supervisor.all.map { record in
            var d = record.json
            if let placement = config().placement(for: record.app.id),
               let data = try? JSONEncoder().encode(placement),
               let object = try? JSONSerialization.jsonObject(with: data) { d["placement"] = object }
            if let dups = duplicates[record.app.id] { d["duplicates"] = dups.map(\.path) }
            if pendingPlacement[record.app.id] != nil { d["placementResult"] = "pending" }
            else if let result = placementResults[record.app.id] { d["placementResult"] = result }
            return d
        }
    }

    // MARK: - Control

    /// `apps`, `apps rescan`, `apps launch id=`, `apps place id=`, `apps quit id=`,
    /// `apps menu id=` (the app's status menu, fetched now),
    /// `apps menu-invoke id= item= [title=]` (perform one of its items),
    /// `apps announce path=`, `apps forget path=`, and
    /// `apps install|update|uninstall id=` (the catalog installer, see `installActions`).
    func registerControl(_ control: HUDSocketServer) {
        control.register("apps") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "apps gone"]); return }
            let actions = ["rescan", "launch", "place", "quit", "menu", "menu-invoke", "announce", "forget",
                           "install", "update", "uninstall", "list"]
            let action = args["action"] ?? actions.first { args[$0] != nil } ?? "list"
            switch action {
            case "list":
                var r: [String: Any] = ["ok": true, "apps": self.json, "known": self.config().known ?? []]
                if !self.failures.isEmpty {
                    r["failures"] = self.failures.map { ["bundle": $0.bundleURL.path, "reason": $0.reason] }
                }
                if !self.duplicates.isEmpty { r["duplicates"] = self.duplicatesJSON }
                done(r)
            case "rescan":
                let before = self.apps
                self.rescan()
                if self.apps != before { self.onAppsChanged?() }
                var r: [String: Any] = ["ok": true, "apps": self.json]
                if !self.duplicates.isEmpty { r["duplicates"] = self.duplicatesJSON }
                done(r)
            case "announce", "forget":
                guard let path = args["path"], !path.isEmpty else {
                    done(["ok": false, "error": "path=<.app bundle path> required"]); return
                }
                done(action == "announce" ? self.announce(path: path) : self.forget(path: path))
            case "menu", "menu-invoke":
                guard let key = args["id"] ?? args["name"], let app = self.app(matching: key) else {
                    done(["ok": false, "error": "id=<bundle id or name> of a discovered app required"]); return
                }
                if action == "menu" {
                    self.menus.refresh(app.id, force: true) { result in
                        switch result {
                        case .success(let items): done(["ok": true, "id": app.id, "items": items.map(\.json)])
                        case .failure(let error): done(["ok": false, "id": app.id, "error": "\(error)"])
                        }
                    }
                } else {
                    guard let item = args["item"], !item.isEmpty else {
                        done(["ok": false, "error": "apps menu-invoke needs item=<menu item id>"]); return
                    }
                    self.menus.invoke(app.id, item: item, title: args["title"]) { result in
                        switch result {
                        case .success(let reply): done(["ok": true, "id": app.id, "item": item, "title": reply["title"] ?? ""])
                        case .failure(let error): done(["ok": false, "id": app.id, "error": "\(error)"])
                        }
                    }
                }
            case "launch", "place", "quit":
                guard let key = args["id"] ?? args["name"], let app = self.app(matching: key) else {
                    done(["ok": false, "error": "id=<bundle id or name> of a discovered app required"]); return
                }
                if action == "launch" {
                    switch self.launch(app, manual: true) {
                    case .failure(let error):
                        done(["ok": false, "error": error.description])
                    case .success(let placement):
                        done(["ok": true, "app": self.supervisor.record(app.id)?.json ?? [:], "placement": placement])
                    }
                } else if action == "place" {
                    if let error = self.place(app) { done(["ok": false, "error": error]); return }
                    done(["ok": true, "id": app.id, "placement": "applied"])
                } else {
                    self.supervisor.quit(app.id) { result in
                        switch result {
                        case .success(let wasRunning): done(["ok": true, "id": app.id, "wasRunning": wasRunning])
                        case .failure(let error): done(["ok": false, "error": "\(error)"])
                        }
                    }
                }
            case "install", "update", "uninstall":
                guard let installActions = self.installActions else { done(["ok": false, "error": "the installer is not available"]); return }
                installActions(action, args, done)
            default:
                done(["ok": false, "error": "apps action must be list, rescan, launch, place, quit, menu, menu-invoke, announce, forget, install, update or uninstall"])
            }
        }
    }
}
