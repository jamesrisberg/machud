import AppKit
import HUDKit

/// Wires the catalog and installer to the rest of MacHUD: the `catalog` command, the
/// `apps install|update|uninstall` verbs, the settings window's Apps tab and the onboarding's
/// Apps step.
@MainActor
final class CatalogServices {
    let catalog: AppCatalog
    let installer: AppInstaller
    let externals: ExternalPanels
    let tab = AppsTabModel()
    /// MacHUD's own version, compared with the catalog's umbrella entry.
    var ownVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    /// Shows the settings window on the Apps tab.
    var showTab: (() -> Void)?

    init(externals: ExternalPanels, catalog: AppCatalog, installer: AppInstaller? = nil) {
        self.externals = externals
        self.catalog = catalog
        let installer = installer ?? AppInstaller()
        self.installer = installer
        catalog.onChange = { [weak self] in self?.reloadTab() }
        installer.onChange = { [weak self] _ in self?.reloadTab() }
        installer.configuredDirectory = { [weak catalog] in catalog?.config().installDirectory }
        let supervisor = externals.supervisor
        installer.hooks.rescan = { [weak self] in
            self?.externals.rescan()
            self?.reloadTab()
        }
        installer.hooks.quit = { [weak externals] bundleID, url, done in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if let record = externals?.supervisor.record(bundleID),
               record.app.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == path {
                // Over its socket when reachable (and it is not relaunched as autoLaunch).
                supervisor.quit(bundleID) { _ in done() }
            } else {
                AppInstaller.running(bundleID, at: url).forEach { $0.terminate() }
                done()
            }
        }
        installer.hooks.launch = { [weak self] bundleID in self?.open(bundleID) }
        tab.install = { [weak self] id in self?.install(id, launch: false) { _ in } }
        tab.update = { [weak self] id in self?.update(id) { _ in } }
        tab.remove = { [weak self] id in self?.uninstall(id) { _ in } }
        tab.open = { [weak self] id in self?.open(id) }
        tab.refresh = { [weak catalog] in catalog?.refresh() }
        tab.installBundled = { [weak self] in self?.installBundled() }
        tab.installSelected = { [weak self] in
            guard let self else { return }
            for row in self.tab.selectedToInstall { self.install(row.id, launch: false) { _ in } }
            self.tab.selected = []
        }
        reloadTab()
    }

    // MARK: - State

    func statuses() -> [CatalogAppStatus] {
        CatalogAppStatus.compare(catalog.installable, discovered: externals.apps,
                                 directories: installer.managedDirectories,
                                 running: installer.hooks.isRunning)
    }

    func status(_ key: String) -> CatalogAppStatus? {
        guard let entry = catalog.entry(matching: key) else { return nil }
        return statuses().first { $0.entry.id == entry.id }
    }

    /// MacHUD's entry when it is newer than this copy.
    var selfUpdate: AppsTabModel.SelfUpdate? {
        guard let entry = catalog.umbrella, CatalogVersion.isNewer(entry.version, than: ownVersion) else { return nil }
        return .init(available: entry.version, current: ownVersion, page: entry.releasePage)
    }

    func reloadTab() {
        tab.rows = statuses().map { status in
            .init(status: status, iconURL: catalog.resolve(status.entry.icon), phase: installer.phase(status.entry.id))
        }
        tab.selfUpdate = selfUpdate
        tab.refreshing = catalog.isRefreshing
        tab.catalogError = catalog.lastError.map { "Could not refresh: \($0)" }
        if catalog.document == nil {
            tab.catalogNote = catalog.isRefreshing ? "Fetching the app catalog…" : "No catalog yet."
        } else if let fetched = catalog.fetchedAt {
            let f = RelativeDateTimeFormatter()
            tab.catalogNote = "\(catalog.installable.count) apps · checked \(f.localizedString(for: fetched, relativeTo: Date()))"
        }
    }

    // MARK: - Actions

    typealias Reply = ([String: Any]) -> Void

    func install(_ key: String, launch: Bool, done: @escaping Reply) {
        guard let status = status(key) else { done(notFound(key)); return }
        guard status.installed == nil else {
            if status.state == .updateAvailable { update(key, done: done); return }
            done(["ok": true, "id": status.entry.id, "result": "already installed",
                  "app": status.json]); return
        }
        run(status, launch: launch, done: done)
    }

    func update(_ key: String, done: @escaping Reply) {
        guard let status = status(key) else { done(notFound(key)); return }
        guard status.installed != nil else { done(["ok": false, "error": "\(status.entry.name) is not installed"]); return }
        guard status.state == .updateAvailable else {
            done(["ok": true, "id": status.entry.id, "result": "up to date", "app": status.json]); return
        }
        // A running app is quit for the update and started again afterwards.
        run(status, launch: status.running, done: done)
    }

    private func run(_ status: CatalogAppStatus, launch: Bool, done: @escaping Reply) {
        installer.install(status.entry, download: catalog.resolve(status.entry.download), existing: status.installed,
                          launch: launch) { [weak self] result in
            switch result {
            case .failure(let error): done(["ok": false, "id": status.entry.id, "error": error.description])
            case .success(let url):
                done(["ok": true, "id": status.entry.id, "path": url.path, "version": status.entry.version,
                      "app": self?.status(status.entry.id)?.json ?? [:]])
            }
        }
    }

    func uninstall(_ key: String, done: @escaping Reply) {
        guard let status = status(key) else { done(notFound(key)); return }
        installer.uninstall(status.entry, installed: status.installed) { result in
            switch result {
            case .failure(let error): done(["ok": false, "id": status.entry.id, "error": error.description])
            case .success(let url): done(["ok": true, "id": status.entry.id, "trashed": url.path])
            }
        }
    }

    /// Installs every `bundled` app that is not installed yet.
    @discardableResult
    func installBundled(done: Reply? = nil) -> [String] {
        let ids = statuses().filter { $0.entry.isBundled && $0.installed == nil }.map(\.entry.id)
        tab.selected.subtract(ids)
        guard !ids.isEmpty else { done?(["ok": true, "installed": []]); return [] }
        var results: [[String: Any]] = []
        for id in ids {
            install(id, launch: false) { reply in
                results.append(reply)
                if results.count == ids.count {
                    done?(["ok": results.allSatisfy { $0["ok"] as? Bool == true }, "results": results])
                }
            }
        }
        return ids
    }

    func open(_ key: String) {
        if let app = externals.app(matching: key) ?? externals.apps.first(where: { app in catalog.entry(matching: key)?.id == app.id }) {
            _ = externals.launch(app, manual: true)
        } else if let url = status(key)?.installed?.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func notFound(_ key: String) -> [String: Any] {
        ["ok": false, "error": catalog.document == nil ? "no catalog yet; run `catalog refresh`"
            : "\(key) is not in the catalog (\(catalog.installable.map(\.id).joined(separator: ", ")))"]
    }

    // MARK: - Onboarding

    /// Readies the onboarding's Apps step: selects the bundled tools that are not installed
    /// yet, fetching a missing or stale catalog first.
    func preselectBundled() {
        let select = { [weak self] in
            guard let self else { return }
            self.tab.selected = Set(self.statuses().filter { $0.entry.isBundled && $0.installed == nil }.map(\.entry.id))
            self.reloadTab()
        }
        select()
        if catalog.document == nil || catalog.isStale { catalog.refresh { _ in select() } }
    }

    // MARK: - Control

    /// `catalog refresh|list`.
    func registerControl(_ control: HUDSocketServer) {
        control.register("catalog") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            let action = args["action"] ?? ["refresh", "list"].first { args[$0] != nil } ?? "list"
            switch action {
            case "list": done(self.listReply())
            case "refresh":
                self.catalog.refresh { error in
                    var r = self.listReply()
                    if let error { r["ok"] = false; r["error"] = error }
                    done(r)
                }
            default: done(["ok": false, "error": "catalog action must be refresh or list"])
            }
        }
    }

    func listReply() -> [String: Any] {
        var r: [String: Any] = ["ok": true, "catalog": catalog.json, "apps": statuses().map(\.json),
                                "machud": ["version": ownVersion, "available": catalog.umbrella?.version ?? NSNull(),
                                           "updateAvailable": selfUpdate != nil,
                                           "page": catalog.umbrella?.releasePage?.absoluteString ?? NSNull()] as [String: Any]]
        if catalog.document == nil { r["note"] = "no catalog yet; run `catalog refresh`" }
        return r
    }

    /// `apps install|update|uninstall id=<id or name> [launch=1]`. The id may also be a
    /// bare word (`machud apps install sift`). Answers when the work is done.
    func handleApps(_ action: String, _ args: [String: String], done: @escaping Reply) {
        let reserved: Set<String> = ["_", "action", "id", "name", "launch", action]
        guard let key = args["id"] ?? args["name"] ?? args.first(where: { !reserved.contains($0.key) && $0.value == "1" })?.key else {
            done(["ok": false, "error": "apps \(action) needs id=<catalog id or name>"]); return
        }
        switch action {
        case "install":
            install(key, launch: ["1", "true", "yes"].contains((args["launch"] ?? "0").lowercased()), done: done)
        case "update": update(key, done: done)
        default: uninstall(key, done: done)
        }
    }
}
