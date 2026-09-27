import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class AppCatalogTests: XCTestCase {
    private var dir: URL!
    private var installDir: URL!
    private var catalogFile: URL!

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("cat")
        installDir = dir.appendingPathComponent("Applications", isDirectory: true)
        catalogFile = dir.appendingPathComponent("catalog.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// A MacHUD-aware bundle with an Info.plist, zipped the way hud-release.sh does.
    private func makeZip(id: String = "dev.test.zeta", name: String = "ZetaTest", version: String) throws -> (zip: URL, sha: String, size: Int) {
        let stage = dir.appendingPathComponent("stage-\(version)", isDirectory: true)
        let app = try FakeBundles.make(in: stage, name: name,
                                       json: FakeBundles.manifest(id: id, name: name, socket: "/tmp/zeta-\(getpid()).sock", panels: ["main"]))
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let zip = dir.appendingPathComponent("\(name)-\(version).zip")
        let (status, out) = AppInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        XCTAssertEqual(status, 0, out)
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        return (zip, try AppInstaller.sha256Hex(zip), size)
    }

    private func writeCatalog(_ entries: [[String: Any]]) throws {
        let doc: [String: Any] = ["schemaVersion": 1, "updatedAt": "2026-09-26T00:00:00Z", "hudkit": ["version": "0.1.0"], "apps": entries]
        try JSONSerialization.data(withJSONObject: doc).write(to: catalogFile)
    }

    private func entry(version: String, zip: (zip: URL, sha: String, size: Int), bundled: Bool = true) -> [String: Any] {
        ["id": "dev.test.zeta", "repo": "someone/zetatest", "name": "ZetaTest", "kind": "windowed", "summary": "A test app",
         "version": version, "minOS": "14.0", "download": zip.zip.absoluteString, "sha256": zip.sha, "size": zip.size,
         "publishedAt": "2026-09-26T00:00:00Z", "icon": "icons/zeta.png", "bundled": bundled]
    }

    private func makeServices(gatekeeper: String? = nil) -> (CatalogServices, ExternalPanels) {
        let supervisor = AppSupervisor(workspace: FakeWorkspace(), connector: FakeConnector(), schedule: ManualClock().schedule)
        let config = CatalogConfig(url: catalogFile.absoluteString, installDir: installDir.path)
        var appsConfig = Config(apps: AppsConfig(standardDirectories: false))
        appsConfig.catalog = config
        let discovery = appsConfig.discoveryApps
        let externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { discovery }
        let catalog = AppCatalog(cacheURL: dir.appendingPathComponent("state/catalog.json")) { config }
        let installer = AppInstaller()
        installer.hooks.gatekeeper = { _ in gatekeeper }
        installer.hooks.isRunning = { _, _ in false }
        installer.hooks.trash = { try FileManager.default.removeItem(at: $0) }
        let services = CatalogServices(externals: externals, catalog: catalog, installer: installer)
        services.ownVersion = "1.0.0"
        services.stateDirectory = dir.appendingPathComponent("state", isDirectory: true)
        return (services, externals)
    }

    private func refresh(_ catalog: AppCatalog) -> String? {
        var error: String?? = .none
        catalog.refresh { error = .some($0) }
        XCTAssertTrue(spin(until: { error != nil }))
        return error ?? "timeout"
    }

    private func call(_ body: (@escaping ([String: Any]) -> Void) -> Void, timeout: TimeInterval = 20) -> [String: Any] {
        var reply: [String: Any]?
        body { reply = $0 }
        XCTAssertTrue(spin(until: { reply != nil }, timeout: timeout))
        return reply ?? [:]
    }

    // MARK: - Tests

    func testVersionComparison() {
        XCTAssertTrue(CatalogVersion.isNewer("1.10.0", than: "1.9"))
        XCTAssertTrue(CatalogVersion.isNewer("v0.2.0", than: "0.1.9"))
        XCTAssertEqual(CatalogVersion.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertTrue(CatalogVersion.isNewer("1.0.0", than: "1.0.0-beta"))
        XCTAssertFalse(CatalogVersion.isNewer("0.1.0", than: "0.1.0"))
    }

    func testRefreshFromFileCachesAndReloads() throws {
        let zip = try makeZip(version: "0.1.0")
        try writeCatalog([entry(version: "0.1.0", zip: zip),
                          ["id": "com.jrisberg.machud", "name": "MacHUD", "kind": "umbrella", "version": "2.0.0",
                           "repo": "jamesrisberg/machud"]])
        let (services, _) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        XCTAssertEqual(services.catalog.installable.map(\.id), ["dev.test.zeta"])
        XCTAssertFalse(services.catalog.isStale)
        XCTAssertEqual(services.catalog.resolve("icons/zeta.png")?.path, dir.appendingPathComponent("icons/zeta.png").path)
        // MacHUD's own newer version is offered as a download, not installed.
        XCTAssertEqual(services.selfUpdate?.available, "2.0.0")
        XCTAssertEqual(services.selfUpdate?.page?.absoluteString, "https://github.com/jamesrisberg/machud/releases/latest")
        // As hud-release.sh writes it: a bare repo name and the GitHub homepage.
        let released = CatalogEntry(id: "x", repo: "sift", name: "Sift", kind: "windowed", version: "1",
                                    homepage: "https://github.com/jamesrisberg/sift")
        XCTAssertEqual(released.releasePage?.absoluteString, "https://github.com/jamesrisberg/sift/releases/latest")
        XCTAssertEqual(CatalogEntry(id: "x", repo: "sift", name: "Sift", kind: "windowed", version: "1").releasePage?.absoluteString,
                       "https://github.com/jamesrisberg/sift/releases/latest")
        let install = call { services.install("MacHUD", launch: false, done: $0) }
        XCTAssertEqual(install["ok"] as? Bool, false)

        // The cache is read at startup, so the catalog is there before any fetch.
        let reloaded = AppCatalog(cacheURL: services.catalog.cacheURL) { CatalogConfig(url: "file:///nonexistent/catalog.json") }
        XCTAssertEqual(reloaded.apps.count, 2)
        XCTAssertNotNil(refresh(reloaded), "a missing catalog is an error")
        XCTAssertEqual(reloaded.apps.count, 2, "a failed refresh keeps the cached catalog")
    }

    func testRejectsUnknownSchema() throws {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "apps": []]).write(to: catalogFile)
        let (services, _) = makeServices()
        XCTAssertTrue(refresh(services.catalog)?.contains("schemaVersion 2") ?? false)
    }

    func testInstallUpdateUninstall() throws {
        let v1 = try makeZip(version: "0.1.0")
        try writeCatalog([entry(version: "0.1.0", zip: v1)])
        let (services, externals) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        XCTAssertEqual(services.statuses().first?.state, .notInstalled)
        XCTAssertEqual(services.tab.bundledToInstall.map(\.id), ["dev.test.zeta"])

        // `machud apps install zetatest`: a bare word names the app.
        let installed = call { services.handleApps("install", ["_": "install", "install": "1", "zetatest": "1"], done: $0) }
        XCTAssertEqual(installed["ok"] as? Bool, true, "\(installed)")
        let bundle = installDir.appendingPathComponent("ZetaTest.app")
        XCTAssertEqual(InstalledCopy.read(bundle)?.version, "0.1.0")
        XCTAssertEqual(externals.apps.map(\.id), ["dev.test.zeta"], "installing rescans")
        XCTAssertEqual(services.statuses().first?.state, .installed)
        XCTAssertEqual(services.installer.phase("dev.test.zeta"), .done("Installed 0.1.0"))
        XCTAssertTrue(services.tab.bundledToInstall.isEmpty)

        // A newer catalog entry is an update that replaces the copy in place.
        let v2 = try makeZip(version: "0.2.0")
        try writeCatalog([entry(version: "0.2.0", zip: v2)])
        XCTAssertNil(refresh(services.catalog))
        XCTAssertEqual(services.statuses().first?.state, .updateAvailable)
        let updated = call { services.update("dev.test.zeta", done: $0) }
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(InstalledCopy.read(bundle)?.version, "0.2.0")
        XCTAssertEqual(services.statuses().first?.state, .installed)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installDir.path)
        XCTAssertEqual(leftovers, ["ZetaTest.app"])

        let removed = call { services.uninstall("ZetaTest", done: $0) }
        XCTAssertEqual(removed["ok"] as? Bool, true, "\(removed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(externals.apps.count, 0)
        XCTAssertEqual(services.statuses().first?.state, .notInstalled)
    }

    func testUpdateQuitsTheRunningCopyFirstAndRelaunchesIt() throws {
        let v1 = try makeZip(version: "0.1.0")
        try writeCatalog([entry(version: "0.1.0", zip: v1)])
        let (services, _) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        XCTAssertEqual(call { services.install("dev.test.zeta", launch: false, done: $0) }["ok"] as? Bool, true)
        let bundle = installDir.appendingPathComponent("ZetaTest.app").standardizedFileURL.path
        var running = true
        var quits: [String] = [], launches: [String] = []
        services.installer.hooks.isRunning = { _, url in running && url.standardizedFileURL.path == bundle }
        services.installer.hooks.quit = { _, url, done in
            quits.append(url.standardizedFileURL.path)
            XCTAssertEqual(InstalledCopy.read(url)?.version, "0.1.0", "quit before the copy is replaced")
            running = false
            done()
        }
        services.installer.hooks.launch = { launches.append($0) }
        let v2 = try makeZip(version: "0.2.0")
        try writeCatalog([entry(version: "0.2.0", zip: v2)])
        XCTAssertNil(refresh(services.catalog))
        XCTAssertEqual(call { services.update("zetatest", done: $0) }["ok"] as? Bool, true)
        XCTAssertEqual(quits, [bundle])
        XCTAssertEqual(launches, ["dev.test.zeta"], "a running app is started again after its update")
    }

    func testChecksumSizeAndGatekeeperFailuresInstallNothing() throws {
        let zip = try makeZip(version: "0.1.0")
        var bad = entry(version: "0.1.0", zip: zip)
        bad["sha256"] = String(repeating: "0", count: 64)
        try writeCatalog([bad])
        var (services, _) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        var reply = call { services.install("dev.test.zeta", launch: false, done: $0) }
        XCTAssertTrue((reply["error"] as? String)?.contains("sha256 mismatch") ?? false, "\(reply)")

        bad = entry(version: "0.1.0", zip: zip)
        bad["size"] = zip.size + 1
        try writeCatalog([bad])
        XCTAssertNil(refresh(services.catalog))
        reply = call { services.install("dev.test.zeta", launch: false, done: $0) }
        XCTAssertTrue((reply["error"] as? String)?.contains("size mismatch") ?? false, "\(reply)")

        try writeCatalog([entry(version: "0.1.0", zip: zip)])
        (services, _) = makeServices(gatekeeper: "rejected\nsource=no usable signature")
        XCTAssertNil(refresh(services.catalog))
        reply = call { services.install("dev.test.zeta", launch: false, done: $0) }
        let error = reply["error"] as? String ?? ""
        XCTAssertTrue(error.contains("Gatekeeper rejected ZetaTest.app"), error)
        XCTAssertEqual(services.installer.phase("dev.test.zeta"), .failed(error))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDir.appendingPathComponent("ZetaTest.app").path))
    }

    func testBundleIDMustMatchCatalog() throws {
        let zip = try makeZip(id: "dev.test.other", version: "0.1.0")
        try writeCatalog([entry(version: "0.1.0", zip: zip)])
        let (services, _) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        let reply = call { services.install("dev.test.zeta", launch: false, done: $0) }
        XCTAssertTrue((reply["error"] as? String)?.contains("is dev.test.other, not dev.test.zeta") ?? false, "\(reply)")
    }

    func testInstalledCopyWinsOverADevBuildWithTheSameID() throws {
        let installed = try FakeBundles.make(in: installDir, name: "ZetaTest", json: "{}")
        let dev = try FakeBundles.make(in: dir.appendingPathComponent("build"), name: "ZetaTest", json: "{}")
        for (bundle, version) in [(installed, "0.1.0"), (dev, "0.3.0-dev")] {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.test.zeta", "CFBundleShortVersionString": version],
                                               format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        let entry = CatalogEntry(id: "dev.test.zeta", name: "ZetaTest", kind: "windowed", version: "0.2.0")
        let manifest = try HUDManifest.decode(Data(FakeBundles.manifest(id: "dev.test.zeta", name: "ZetaTest", socket: "z", panels: ["main"]).utf8))
        let found = CatalogAppStatus.compare([entry], discovered: [ExternalApp(manifest: manifest, bundleURL: dev)],
                                             directories: [installDir], running: { _, _ in false })
        XCTAssertEqual(found.first?.installed?.bundleURL.path, installed.path)
        XCTAssertEqual(found.first?.state, .updateAvailable)
        let devOnly = CatalogAppStatus.compare([entry], discovered: [ExternalApp(manifest: manifest, bundleURL: dev)],
                                               directories: [], running: { _, _ in false })
        XCTAssertEqual(devOnly.first?.state, .newerInstalled)
    }

    func testUninstallLeavesDevBuildsAlone() throws {
        let zip = try makeZip(version: "0.1.0")
        try writeCatalog([entry(version: "0.1.0", zip: zip)])
        let (services, _) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        let dev = InstalledCopy(bundleURL: dir.appendingPathComponent("build/ZetaTest.app"), bundleID: "dev.test.zeta", version: "0.1.0")
        var reply: Result<URL, AppInstaller.InstallError>?
        services.installer.uninstall(services.catalog.installable[0], installed: dev) { reply = $0 }
        XCTAssertTrue(spin(until: { reply != nil }))
        guard case .failure(let error)? = reply else { return XCTFail("uninstalled a dev build") }
        XCTAssertTrue(error.description.contains("not in an Applications folder"))
    }

    func testFirstRunSelectsBundledOnce() throws {
        let zip = try makeZip(version: "0.1.0")
        try writeCatalog([entry(version: "0.1.0", zip: zip, bundled: true)])
        setenv("MACHUD_FIRST_RUN", "1", 1)
        defer { unsetenv("MACHUD_FIRST_RUN") }
        let (services, _) = makeServices()
        XCTAssertNil(refresh(services.catalog))
        var shown = 0
        services.showTab = { shown += 1 }
        XCTAssertTrue(services.firstRunIfNeeded())
        XCTAssertEqual(services.tab.selected, ["dev.test.zeta"])
        XCTAssertFalse(services.firstRunIfNeeded(), "only once")
        XCTAssertEqual(shown, 1)
    }
}
