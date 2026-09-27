import XCTest
import HUDKit
@testable import MacHUDCore

/// `apps announce` / `apps forget`, `apps.known`, duplicate ids and the directory watcher.
@MainActor
final class AppAnnounceTests: XCTestCase {
    private var dir: URL!
    private var config = AppsConfig()
    private var saves = 0
    private var changes = 0
    private var registry: PanelRegistry!
    private var workspace: FakeWorkspace!
    private var externals: ExternalPanels!

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("ann")
        config = AppsConfig(searchPaths: [dir.appendingPathComponent("search").path], standardDirectories: false)
        registry = PanelRegistry()
        workspace = FakeWorkspace()
        let supervisor = AppSupervisor(workspace: workspace, connector: FakeConnector(), schedule: ManualClock().schedule)
        externals = ExternalPanels(registry: registry, supervisor: supervisor) { [unowned self] in self.config }
        externals.runningBundles = { _ in [] }
        externals.saveConfig = { [unowned self] in self.config = $0; self.saves += 1 }
        externals.onAppsChanged = { [unowned self] in self.changes += 1 }
    }

    override func tearDownWithError() throws {
        externals.watcher?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeApp(_ sub: String, id: String = "dev.demo", name: String = "Demo") throws -> URL {
        try FakeBundles.make(in: dir.appendingPathComponent(sub), name: name,
                             json: FakeBundles.manifest(id: id, name: name, socket: "/tmp/\(name).sock", panels: ["main"]))
    }

    private func setModified(_ bundle: URL, _ date: Date) throws {
        for path in [bundle.path, HUDManifest.manifestURL(inBundleAt: bundle).path] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    func testAnnounceRegistersOutsideSearchPathsAndPersists() throws {
        let bundle = try makeApp("elsewhere/build")
        externals.rescan()
        XCTAssertTrue(externals.apps.isEmpty)

        let r = externals.announce(path: bundle.path)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["changed"] as? Bool, true)
        XCTAssertEqual(r["active"] as? Bool, true)
        XCTAssertEqual(externals.apps.map(\.id), ["dev.demo"])
        XCTAssertNotNil(registry.panel(id: "dev.demo/main"), "the dock's button exists at once")
        XCTAssertEqual(config.known, [bundle.path])
        XCTAssertEqual([saves, changes], [1, 1])

        // Again (the app's own launch announcement), also spelled with a trailing slash: a no-op.
        let again = externals.announce(path: bundle.path + "/")
        XCTAssertEqual(again["changed"] as? Bool, false)
        XCTAssertEqual(config.known, [bundle.path], "deduplicated")
        XCTAssertEqual([saves, changes], [1, 1])
    }

    func testAnnounceRejectsBundleWithoutManifest() throws {
        let plain = dir.appendingPathComponent("Plain.app/Contents/Resources")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let r = externals.announce(path: dir.appendingPathComponent("Plain.app").path)
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue((r["error"] as? String ?? "").contains("machud.json"))
        XCTAssertNil(config.known)
        XCTAssertEqual(externals.announce(path: dir.appendingPathComponent("Missing.app").path)["ok"] as? Bool, false)
    }

    func testAnnouncingMacHUDItselfIsIgnored() throws {
        let own = try makeApp("x", id: "com.jrisberg.machud", name: "MacHUD")
        externals.excluding = ["com.jrisberg.machud"]
        let r = externals.announce(path: own.path)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["changed"] as? Bool, false)
        XCTAssertNil(config.known)
    }

    func testForget() throws {
        let bundle = try makeApp("elsewhere")
        _ = externals.announce(path: bundle.path)
        let r = externals.forget(path: bundle.path)
        XCTAssertEqual(r["forgotten"] as? Bool, true)
        XCTAssertNil(config.known)
        XCTAssertTrue(externals.apps.isEmpty)
        XCTAssertNil(registry.panel(id: "dev.demo/main"))
        XCTAssertEqual(externals.forget(path: bundle.path)["forgotten"] as? Bool, false)
    }

    func testVanishedKnownBundleIsDroppedOnRescan() throws {
        let bundle = try makeApp("elsewhere")
        let other = try makeApp("other", id: "dev.other", name: "Other")
        _ = externals.announce(path: bundle.path)
        _ = externals.announce(path: other.path)
        try FileManager.default.removeItem(at: bundle)
        externals.rescan()
        XCTAssertEqual(config.known, [other.path])
        XCTAssertEqual(externals.apps.map(\.id), ["dev.other"])
        XCTAssertTrue(externals.failures.isEmpty, "a vanished bundle is not a failure")
    }

    func testKnownRoundTripsAndIsNotAnAppEntry() throws {
        let json = #"{"known": ["/a/B.app"], "searchPaths": ["~/x"], "dev.b": {"placement": {"edge": "left"}}}"#
        let decoded = try JSONDecoder().decode(AppsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.known, ["/a/B.app"])
        XCTAssertEqual(Set(decoded.perApp.keys), ["dev.b"])
        XCTAssertEqual(try JSONDecoder().decode(AppsConfig.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    // MARK: - Duplicates

    func testDuplicateIDsPreferNewestThenRunning() throws {
        let installed = try makeApp("search")
        let dev = try makeApp("dev/build")
        try setModified(installed, Date(timeIntervalSinceNow: -3600))
        try setModified(dev, Date(timeIntervalSinceNow: -60))
        _ = externals.announce(path: dev.path)
        XCTAssertEqual(externals.apps.map { ExternalAppCatalog.canonicalPath($0.bundleURL) },
                       [ExternalAppCatalog.canonicalPath(dev)], "the most recently modified bundle")
        XCTAssertEqual(externals.duplicates["dev.demo"]?.map(ExternalAppCatalog.canonicalPath),
                       [dev, installed].map(ExternalAppCatalog.canonicalPath))
        let record = try XCTUnwrap(externals.json.first)
        XCTAssertEqual((record["duplicates"] as? [String])?.count, 2)

        // The running instance's bundle beats a newer one.
        externals.runningBundles = { id in id == "dev.demo" ? [installed] : [] }
        externals.rescan()
        XCTAssertEqual(externals.apps.first.map { ExternalAppCatalog.canonicalPath($0.bundleURL) },
                       ExternalAppCatalog.canonicalPath(installed))
        XCTAssertEqual(externals.duplicates["dev.demo"]?.first.map(ExternalAppCatalog.canonicalPath),
                       ExternalAppCatalog.canonicalPath(installed))
    }

    func testEqualDatesKeepSearchOrder() throws {
        let first = try makeApp("search")
        let second = try makeApp("dev")
        let date = Date(timeIntervalSinceNow: -100)
        try setModified(first, date)
        try setModified(second, date)
        XCTAssertEqual(ExternalAppCatalog.preferred([first, second], running: []), 0)
    }

    // MARK: - Watcher

    func testWatchedDirectories() {
        let cfg = AppsConfig(searchPaths: [dir.path + "/*/build", dir.path + "/plain"], standardDirectories: false,
                             known: [dir.path + "/k/build/K.app"])
        let dirs = ExternalAppCatalog.watchedDirectories(cfg).map(\.path)
        XCTAssertEqual(Set(dirs), [dir.path + "/plain", dir.path, dir.path + "/k/build"])
        XCTAssertEqual(dirs.count, 3)
        XCTAssertTrue(ExternalAppCatalog.watchedDirectories(AppsConfig()).map(\.path).contains("/Applications"))
    }

    func testWatcherRescansWhenAnAppAppearsOrGoes() throws {
        let search = dir.appendingPathComponent("search")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        externals.rescan()
        externals.startWatching(debounce: 0.1)
        XCTAssertEqual(externals.watcher?.watched, [search.path])

        let bundle = try makeApp("search")
        XCTAssertTrue(spin(until: { self.externals.apps.count == 1 }), "a new .app triggers a rescan")
        XCTAssertNotNil(registry.panel(id: "dev.demo/main"))
        XCTAssertGreaterThanOrEqual(changes, 1)

        try FileManager.default.removeItem(at: bundle)
        XCTAssertTrue(spin(until: { self.externals.apps.isEmpty }), "a removed .app triggers a rescan")
    }

    func testWatcherSeesARebuiltKnownBundle() throws {
        let bundle = try makeApp("elsewhere/build")
        _ = externals.announce(path: bundle.path)
        externals.startWatching(debounce: 0.1)
        XCTAssertTrue(externals.watcher?.watched.contains(bundle.deletingLastPathComponent().path) == true)
        // A rebuild replaces the bundle with one declaring another panel.
        try FileManager.default.removeItem(at: bundle)
        try FakeBundles.make(in: bundle.deletingLastPathComponent(), name: "Demo",
                             json: FakeBundles.manifest(id: "dev.demo", name: "Demo", socket: "/tmp/Demo.sock", panels: ["main", "more"]))
        XCTAssertTrue(spin(until: { self.registry.panel(id: "dev.demo/more") != nil }))
        XCTAssertEqual(config.known, [bundle.path])
    }
}
