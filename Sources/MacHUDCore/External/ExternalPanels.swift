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
    /// Apps kept running like `autoLaunch` ones besides the configured: those with widgets
    /// placed (wired to the widget layer).
    var keepRunning: () -> Set<String> = { [] }
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
        supervisor.bundles = { [weak self] id in self?.duplicates[id] ?? [] }
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

    /// Whether the app is up or on its way: what Quit applies to, and what Launch skips.
    func isUp(_ id: String) -> Bool {
        [.running, .socketUnreachable, .launching].contains(supervisor.record(id)?.health ?? .notRunning)
    }

    /// Launches every discovered app that is not up (`apps launch-all`, the menu's Launch
    /// All). Returns `launch`'s result per app id it tried.
    @discardableResult
    func launchAll() -> [String: Result<String, AppSupervisor.LaunchError>] {
        var out: [String: Result<String, AppSupervisor.LaunchError>] = [:]
        for app in apps where !isUp(app.id) { out[app.id] = launch(app, manual: true) }
        return out
    }

    /// Quits every app that is up (`apps quit-all`, the menu's Quit All). Completes once
    /// each has answered, with per app id `quit` or the error.
    func quitAll(completion: @escaping ([String: String]) -> Void = { _ in }) {
        let ids = apps.map(\.id).filter(isUp)
        var out: [String: String] = [:]
        guard !ids.isEmpty else { completion(out); return }
        for id in ids {
            supervisor.quit(id) { result in
                switch result {
                case .success: out[id] = "quit"
                case .failure(let error): out[id] = "\(error)"
                }
                if out.count == ids.count { completion(out) }
            }
        }
    }

    /// Relaunches one app (`apps relaunch`, the menu's Relaunch): quit, wait for it to exit,
    /// launch the same bundle again, wait for it to listen. Completes with
    /// `{id, previousPID?, pid, health}` or `{id, previousPID?, error}`.
    func relaunch(_ id: String, completion: @escaping ([String: Any]) -> Void) {
        let previous = supervisor.livePIDs(id).first
        supervisor.relaunch(id) { result in
            var d: [String: Any] = ["id": id]
            if let previous { d["previousPID"] = Int(previous) }
            switch result {
            case .success(let up):
                d["pid"] = Int(up.pid)
                d["health"] = up.health.rawValue
            case .failure(let error):
                d["error"] = error.description
            }
            completion(d)
        }
    }

    /// Relaunches every app that is up, or only the outdated ones (`apps relaunch-all
    /// [outdated=1]`, the menu's Relaunch Outdated Apps). Completes once each is back, with
    /// `relaunch`'s result per app id.
    func relaunchAll(outdatedOnly: Bool, completion: @escaping ([String: [String: Any]]) -> Void = { _ in }) {
        let outdated = Set(supervisor.outdatedIDs)
        let ids = apps.map(\.id).filter { isUp($0) && (!outdatedOnly || outdated.contains($0)) }
        var out: [String: [String: Any]] = [:]
        guard !ids.isEmpty else { completion(out); return }
        for id in ids {
            relaunch(id) { result in
                out[id] = result
                if out.count == ids.count { completion(out) }
            }
        }
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

    /// Registers `apps` (replacing any earlier set) and their hover and windowed panels; widget
    /// types and unknown kinds are not panels. Split from `rescan` for tests.
    func install(_ apps: [ExternalApp], autoLaunch configured: Set<String>) {
        let autoLaunch = autoLaunches ? configured.union(keepRunning()) : []
        self.apps = apps
        let wanted = Set(apps.flatMap { app in app.manifest.presentedPanels.map { ExternalPanel.id(app: app.id, panel: $0.id) } })
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
            for descriptor in app.manifest.presentedPanels {
                let id = ExternalPanel.id(app: app.id, panel: descriptor.id)
                if let existing = registry.panel(id: id) as? ExternalPanel, existing.app == app,
                   existing.descriptor == descriptor { continue }
                registry.register(ExternalPanel(app: app, descriptor: descriptor, supervisor: supervisor))
            }
        }
    }

    /// Applies a change in `keepRunning` (a widget placed for an app, or its last one removed);
    /// an app the user quit stays quit.
    func refreshKeepRunning() {
        supervisor.setAutoLaunch(autoLaunches ? Set(config().autoLaunch ?? []).union(keepRunning()) : [])
    }

    /// Bundle id, or app name (case-insensitive).
    func app(matching key: String) -> ExternalApp? {
        apps.first { $0.id == key } ?? apps.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    var json: [[String: Any]] {
        supervisor.all.map { record in
            var d = record.json
            if let status = supervisor.buildStatus(record.app.id) { d.merge(status.json) { a, _ in a } }
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
    /// `apps launch-all`, `apps quit-all`, `apps relaunch id=`, `apps relaunch-all [outdated=1]`,
    /// `apps menu id=` (the app's status menu, fetched now),
    /// `apps menu-invoke id= item= [title=]` (perform one of its items),
    /// `apps perform app= verb= [key=value ...]` (one of the app's own `action` verbs),
    /// `apps announce path=`, `apps forget path=`, and
    /// `apps install|update|uninstall id=` (the catalog installer, see `installActions`).
    func registerControl(_ control: HUDSocketServer) {
        control.register("apps") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "apps gone"]); return }
            let actions = ["rescan", "relaunch-all", "launch-all", "quit-all", "relaunch", "launch", "place", "quit", "menu",
                           "menu-invoke", "perform", "announce", "forget", "install", "update", "uninstall", "list"]
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
            case "perform":
                self.perform(args, done: done)
            case "launch-all":
                let launched = self.launchAll().mapValues { result -> String in
                    switch result {
                    case .success(let placement): return placement
                    case .failure(let error): return error.description
                    }
                }
                done(["ok": true, "launched": launched])
            case "quit-all":
                self.quitAll { done(["ok": true, "quit": $0]) }
            case "relaunch-all":
                let outdatedOnly = ["1", "true", "yes"].contains((args["outdated"] ?? "0").lowercased())
                self.relaunchAll(outdatedOnly: outdatedOnly) { done(["ok": true, "relaunched": $0]) }
            case "relaunch":
                guard let key = args["id"] ?? args["name"], let app = self.app(matching: key) else {
                    done(["ok": false, "error": "id=<bundle id or name> of a discovered app required"]); return
                }
                self.relaunch(app.id) { result in
                    var r = result
                    r["ok"] = result["error"] == nil
                    if let row = self.json.first(where: { $0["id"] as? String == app.id }) { r["app"] = row }
                    done(r)
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
                done(["ok": false, "error": "apps action must be list, rescan, launch, launch-all, place, quit, quit-all, relaunch, relaunch-all, menu, menu-invoke, perform, announce, forget, install, update or uninstall"])
            }
        }
    }

    /// Keys of `apps perform` that address MacHUD, not the app; every other key goes to the app.
    static let performKeys: Set<String> = ["action", "_", "perform", "app", "verb"]

    /// `apps perform app=<bundle id or name> verb=<verb> [key=value ...]`: sends the app
    /// `action name=<verb>` with the other keys (launching it first if it is not running, as
    /// `panel show` does). The target is `app=`, not `id=`, so an action's own `id=` passes
    /// through. Replies with the app's reply plus `app` (its bundle id).
    func perform(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        guard let key = args["app"], let app = app(matching: key) else {
            done(["ok": false, "error": "app=<bundle id or name> of a discovered app required"]); return
        }
        guard let verb = args["verb"], !verb.isEmpty else {
            done(["ok": false, "error": "apps perform needs verb=<action verb>"]); return
        }
        var forwarded = args.filter { !Self.performKeys.contains($0.key) }
        forwarded["name"] = verb
        supervisor.send(app.id, command: "action", args: forwarded) { result in
            switch result {
            case .success(var reply):
                reply["app"] = app.id
                done(reply)
            case .failure(let error):
                done(["ok": false, "app": app.id, "error": "\(error)"])
            }
        }
    }
}
