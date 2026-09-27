import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class ExternalDiscoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("disc")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDiscoversManifestsSkipsOwnAndReportsBroken() throws {
        let apps = dir.appendingPathComponent("Apps")
        try FakeBundles.make(in: apps, name: "Wormhole",
                             json: FakeBundles.manifest(id: "xyz.wormhole", name: "Wormhole", socket: "wormhole", panels: ["portal"]))
        try FakeBundles.make(in: apps.appendingPathComponent("Utilities"), name: "Detox",
                             json: FakeBundles.manifest(id: "dev.detox", name: "Detox", socket: "detox", panels: ["files", "queue"]))
        try FakeBundles.make(in: apps, name: "MacHUD",
                             json: FakeBundles.manifest(id: "com.jrisberg.machud", name: "MacHUD", socket: "machud", panels: ["dock"]))
        try FakeBundles.make(in: apps, name: "Broken", json: "{not json")
        // An app without a manifest is not MacHUD-aware and is ignored silently.
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Plain.app/Contents"), withIntermediateDirectories: true)

        let result = ExternalAppCatalog.discover(AppsConfig(searchPaths: [apps.path], standardDirectories: false))
        XCTAssertEqual(result.apps.map(\.id).sorted(), ["dev.detox", "xyz.wormhole"])
        XCTAssertEqual(result.failures.map { $0.bundleURL.lastPathComponent }, ["Broken.app"])
    }

    func testSearchPathsExpandGlobs() throws {
        for project in ["alpha", "beta"] {
            try FakeBundles.make(in: dir.appendingPathComponent("\(project)/build"), name: project.capitalized,
                                 json: FakeBundles.manifest(id: "dev.\(project)", name: project, socket: project, panels: ["main"]))
        }
        let result = ExternalAppCatalog.discover(AppsConfig(searchPaths: [dir.path + "/*/build", dir.path + "/missing/*"],
                                                            standardDirectories: false))
        XCTAssertEqual(result.apps.map(\.id), ["dev.alpha", "dev.beta"])
        XCTAssertEqual(ExternalAppCatalog.expand(dir.path + "/nothing-*"), [])
    }

    func testInstallRegistersPanelsAndRescanDropsGoneOnes() throws {
        let registry = PanelRegistry()
        let workspace = FakeWorkspace()
        let clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: FakeConnector(), schedule: clock.schedule)
        var config = AppsConfig(searchPaths: [dir.path], standardDirectories: false)
        let externals = ExternalPanels(registry: registry, supervisor: supervisor) { config }
        let bundle = try FakeBundles.make(in: dir, name: "Wormhole",
                                          json: FakeBundles.manifest(id: "xyz.wormhole", name: "Wormhole", socket: "/tmp/x.sock", panels: ["portal", "sets"]))
        workspace.installed = ["xyz.wormhole"]
        externals.rescan()

        XCTAssertEqual(registry.panels.map(\.id), ["xyz.wormhole/portal", "xyz.wormhole/sets"])
        XCTAssertEqual(registry.panel(id: "portal")?.id, "xyz.wormhole/portal", "short id resolves when unique")
        XCTAssertEqual(registry.panel(id: "xyz.wormhole/sets")?.appID, "xyz.wormhole")
        XCTAssertEqual(supervisor.record("xyz.wormhole")?.health, .notRunning)
        XCTAssertEqual(externals.app(matching: "wormhole")?.id, "xyz.wormhole")

        // A second app declaring "portal" makes the short id ambiguous.
        try FakeBundles.make(in: dir, name: "Other",
                             json: FakeBundles.manifest(id: "dev.other", name: "Other", socket: "/tmp/o.sock", panels: ["portal"]))
        externals.rescan()
        XCTAssertNil(registry.panel(id: "portal"))
        XCTAssertNotNil(registry.panel(id: "dev.other/portal"))

        try FileManager.default.removeItem(at: bundle)
        config.searchPaths = [dir.path]
        externals.rescan()
        XCTAssertEqual(registry.panels.map(\.id), ["dev.other/portal"])
        XCTAssertNil(supervisor.record("xyz.wormhole"))
    }

    func testRegistryPublishesVisibilityChangesMadeOutsideTheSocket() {
        final class Fake: Panel {
            let id = "fake", title = "Fake", symbol = "x"
            var window: NSWindow? { nil }
            var shown = false
            var isVisible: Bool { shown }
            func show() { shown = true }
            func hide() { shown = false }
        }
        let registry = PanelRegistry()
        let panel = Fake()
        registry.register(panel)
        var fired = 0
        registry.onStateChange = { fired += 1 }
        registry.refreshState()
        let base = fired
        registry.toggle("fake")          // what the hotkey and menu do now
        XCTAssertTrue(spin { fired == base + 1 })
        panel.hide()                      // a direct change, noticed on the next check
        registry.noteChange()
        XCTAssertTrue(spin { fired == base + 2 })
        registry.noteChange()             // nothing changed: no event
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(fired, base + 2)
    }
}
