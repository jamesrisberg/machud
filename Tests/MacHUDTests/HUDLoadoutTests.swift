import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

/// A fake sibling app behind a real `HUDSocketServer`: panels with visibility, mode and a
/// frame it reports in `state`, settings, and an `action` log. Every operation is logged
/// in order.
@MainActor
final class FakeSiblingApp: HUDPanelHost {
    struct PanelModel { var visible = false; var mode = HUDPanelMode.full; var frame = CGRect.zero }

    let manifest: HUDManifest
    let server: HUDSocketServer
    private var router: HUDControlRouter!
    var panels: [String: PanelModel] = [:]
    var settingsValues: [String: String] = [:]
    var log: [String] = []
    var actions: [(name: String, args: [String: String])] = []
    var showOptions: [[String: String]] = []

    init(id: String, name: String, socket: String, panels: [HUDManifest.Panel]) {
        manifest = HUDManifest(id: id, name: name, socket: socket, panels: panels)
        server = HUDSocketServer(path: socket, label: "machud.test.\(name)")
        for p in panels { self.panels[p.id] = PanelModel() }
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
        router.install()
        // `state` with each panel's frame (HUDKit's own `state` carries none).
        server.register("state") { [weak self] _, done in done(["ok": true, "panels": self?.stateJSON ?? []]) }
        _ = server.start()
    }

    var stateJSON: [[String: Any]] {
        panels.keys.sorted().map { id in
            let p = panels[id]!
            return ["id": id, "visible": p.visible, "mode": p.mode.rawValue,
                    "frame": [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height]]
        }
    }

    func push() { server.publish("state", payload: ["panels": stateJSON]) }

    var app: ExternalApp { ExternalApp(manifest: manifest, bundleURL: URL(fileURLWithPath: "/tmp/\(manifest.name).app")) }

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }
    var panelStates: [HUDPanelState] {
        panels.keys.sorted().map { HUDPanelState(id: $0, visible: panels[$0]!.visible, mode: panels[$0]!.mode) }
    }
    func showPanel(_ id: String) throws { log.append("show \(id)"); panels[id]?.visible = true }
    func hidePanel(_ id: String) throws { log.append("hide \(id)"); panels[id]?.visible = false }
    func showPanel(_ id: String, options: [String: String]) throws { showOptions.append(options); try showPanel(id) }
    func setPanelFrame(_ id: String, frame: CGRect) throws { log.append("frame \(id)"); panels[id]?.frame = frame }
    func setPanelMode(_ id: String, mode: HUDPanelMode) throws { log.append("mode \(id)"); panels[id]?.mode = mode }
    var settingsSchema: HUDSettingsSchema? { nil }
    func settings() -> [String: Any] { settingsValues }
    func updateSettings(_ values: [String: String]) throws {
        log.append("settings")
        settingsValues.merge(values) { _, b in b }
    }
    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        actions.append((name, args))
        done(["ok": true])
    }
    func quit() {}
}

@MainActor
final class HUDLoadoutTests: XCTestCase {
    private var dir: URL!
    private var pad: FakeSiblingApp!
    private var sift: FakeSiblingApp!
    private var workspace: FakeWorkspace!
    private var supervisor: AppSupervisor!
    private var registry: PanelRegistry!
    private var externals: ExternalPanels!
    private var dock: ToolDock!
    private var dockConfig = ToolDockConfig()
    private var hud: HUDLoadoutEngine!

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("hud")
        pad = FakeSiblingApp(id: "dev.test.pad", name: "Pad", socket: dir.appendingPathComponent("p.sock").path, panels: [
            HUDManifest.Panel(id: "pad", title: "Pad", capabilities: [HUDDrop.capability], kind: .hover)])
        sift = FakeSiblingApp(id: "dev.test.sift", name: "Sift", socket: dir.appendingPathComponent("s.sock").path, panels: [
            HUDManifest.Panel(id: "browser", title: "Sift")])
        workspace = FakeWorkspace()
        workspace.installed = [pad.manifest.id, sift.manifest.id]
        workspace.running[pad.manifest.id] = [getpid()]
        workspace.running[sift.manifest.id] = [getpid()]
        supervisor = AppSupervisor(workspace: workspace)       // real sockets
        registry = PanelRegistry()
        externals = ExternalPanels(registry: registry, supervisor: supervisor) { AppsConfig() }
        externals.install([pad.app, sift.app], autoLaunch: [])
        XCTAssertTrue(spin { self.supervisor.record(self.pad.manifest.id)?.health == .running
                          && self.supervisor.record(self.sift.manifest.id)?.health == .running })
        dock = ToolDock(registry: registry, externals: externals, config: { [unowned self] in self.dockConfig },
                        saveConfig: { [unowned self] in self.dockConfig = $0 },
                        stateURL: dir.appendingPathComponent("tooldock.json"), ui: false)
        dock.screens = { [ToolDockScreen(name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                         visible: CGRect(x: 0, y: 80, width: 1920, height: 975))] }
        dock.refresh()
        hud = HUDLoadoutEngine(externals: externals, dockPosition: { [unowned self] in self.dockConfig.dockPosition },
                               setDockPosition: { [unowned self] in self.dock.position($0) })
    }

    override func tearDownWithError() throws {
        pad.server.stop()
        sift.server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func testDropReachesTheFakeAppDecodable() {
        let files = [URL(fileURLWithPath: "/tmp/with space.png"), URL(fileURLWithPath: "/tmp/pipe|and%percent.mov"),
                     URL(fileURLWithPath: "/tmp/ünï.txt")]
        XCTAssertFalse(dock.drop(files, on: sift.manifest.id))
        XCTAssertTrue(dock.drop(files, on: pad.manifest.id))
        XCTAssertTrue(spin { !self.pad.actions.isEmpty })
        XCTAssertEqual(pad.actions.first?.name, "drop")
        XCTAssertEqual(HUDDrop.urls(from: pad.actions.first?.args ?? [:]).map(\.path), files.map(\.path))
        XCTAssertTrue(sift.actions.isEmpty)
    }

    func testCaptureThenApplyPutsEverythingBack() throws {
        dock.position(.bottomLeft)
        sift.panels["browser"] = .init(visible: true, mode: .full, frame: CGRect(x: 100, y: 120, width: 900, height: 600))
        sift.settingsValues = ["dock.edge": "left", "defaultFolder": "~/Downloads"]
        sift.push()
        XCTAssertTrue(spin { self.supervisor.record(self.sift.manifest.id)?.frames["browser"]?.width == 900 })

        var captured: HUDLoadout?
        hud.capture { captured = $0 }
        XCTAssertTrue(spin { captured != nil })
        let saved = try XCTUnwrap(captured)
        XCTAssertEqual(saved.dock?.position, .bottomLeft)
        let browser = try XCTUnwrap(saved.apps?[sift.manifest.id]?.panels["browser"])
        XCTAssertEqual(browser, HUDLoadout.PanelEntry(visible: true, mode: .full,
                                                      frame: HUDLoadout.Frame(CGRect(x: 100, y: 120, width: 900, height: 600)),
                                                      settings: ["dock.edge": "left"]), "only dock settings are kept")
        XCTAssertEqual(saved.apps?[pad.manifest.id]?.panels["pad"]?.visible, false)

        // It survives layouts.json.
        var loadout = Loadout(name: "Mine", layout: "", slots: [], hotkey: nil)
        loadout.hud = saved
        let back = try JSONDecoder().decode(Loadout.self, from: JSONEncoder().encode(loadout))
        XCTAssertEqual(back, loadout)

        // Move everything.
        dock.position(.top)
        sift.panels["browser"] = .init(visible: false, mode: .compact, frame: CGRect(x: 5, y: 5, width: 300, height: 300))
        sift.settingsValues["dock.edge"] = "right"
        sift.log = []

        var report: HUDLoadoutEngine.Report?
        hud.apply(back.hud!) { report = $0 }
        XCTAssertTrue(spin { report != nil })
        XCTAssertEqual(report?.dock, "bottomLeft")
        XCTAssertEqual(report?.apps[sift.manifest.id], "applied")
        XCTAssertEqual(dockConfig.position, .bottomLeft)
        XCTAssertEqual(sift.panels["browser"]?.frame, CGRect(x: 100, y: 120, width: 900, height: 600))
        XCTAssertEqual(sift.panels["browser"]?.visible, true)
        XCTAssertEqual(sift.panels["browser"]?.mode, .full)
        XCTAssertEqual(sift.settingsValues["dock.edge"], "left")
        XCTAssertEqual(sift.log, ["settings", "mode browser", "frame browser", "show browser"],
                       "settings, mode, frame, visibility")
        XCTAssertEqual(sift.showOptions.last?["reason"], "summon")
    }

    func testCommandsSkipTheFrameOfAParkedPanel() {
        let entry = HUDLoadout.App(panels: ["a": .init(visible: true, mode: .parked, frame: .init(CGRect(x: 1, y: 2, width: 3, height: 4))),
                                            "b": .init(visible: false, mode: nil, frame: nil)])
        let commands = HUDLoadoutEngine.commands(for: entry).map { "\($0.0) \($0.1["action"] ?? "") \($0.1["id"] ?? "")" }
        XCTAssertEqual(commands, ["panel mode a", "panel hide b"])
    }

    func testApplyLaunchesAnAppThatIsNotRunning() {
        let connector = FakeConnector()
        let clock = ManualClock()
        let ws = FakeWorkspace()
        ws.installed = ["dev.test.pad"]
        let sup = AppSupervisor(workspace: ws, connector: connector, schedule: clock.schedule)
        let ext = ExternalPanels(registry: PanelRegistry(), supervisor: sup) { AppsConfig() }
        ext.install([pad.app], autoLaunch: [])
        let engine = HUDLoadoutEngine(externals: ext, dockPosition: { nil }, setDockPosition: { _ in })
        engine.apply(HUDLoadout(apps: ["dev.test.pad": .init(panels: ["pad": .init(visible: true)]),
                                       "dev.test.gone": .init(panels: [:])])) { _ in }
        XCTAssertEqual(ws.launches, ["dev.test.pad"])
        XCTAssertTrue(connector.requests.isEmpty, "commands wait for the socket")
    }

    func testEngineAppliesAHUDOnlyLoadoutWithoutTouchingWindows() throws {
        // LayoutStore reads MACHUD_CONFIG once per process: the shared test file.
        guard try TestConfig.write("{}") else {
            throw XCTSkip("LayoutStore.configURL was already fixed to \(LayoutStore.configURL.path)")
        }
        let store = LayoutStore()
        let engine = LoadoutEngine(store: store, panels: registry)
        engine.hudEngine = hud
        sift.panels["browser"] = .init(visible: true, mode: .full, frame: CGRect(x: 10, y: 90, width: 500, height: 400))
        sift.push()
        XCTAssertTrue(spin { self.supervisor.record(self.sift.manifest.id)?.frames["browser"]?.width == 500 })
        var saved: Loadout?
        engine.captureHUD(into: "Desk") { saved = $0 }
        XCTAssertTrue(spin { saved != nil })
        XCTAssertEqual(store.loadout(named: "Desk")?.hud, saved?.hud)
        XCTAssertEqual(store.loadout(named: "Desk")?.slots, [])

        sift.panels["browser"]?.visible = false
        var report: LoadoutEngine.ApplyReport?
        engine.apply(try XCTUnwrap(store.loadout(named: "Desk")), clear: false) { report = $0 }
        XCTAssertTrue(spin { report != nil })
        XCTAssertEqual(report?.json["ok"] as? Bool, true)
        XCTAssertNotNil(report?.json["hud"])
        XCTAssertEqual(sift.panels["browser"]?.visible, true)
    }
}

@MainActor
final class StartupLoadoutTests: XCTestCase {
    private var reachable: Set<String> = []
    private var running: Set<String> = ["a", "b"]
    private var applied: [String] = []
    private var configured: Loadout? = {
        var l = Loadout(name: "Desk", layout: "", slots: [], hotkey: nil)
        l.hud = HUDLoadout(apps: ["a": .init(panels: [:]), "b": .init(panels: [:]), "c": .init(panels: [:])])
        return l
    }()

    private func make(_ clock: ManualClock) -> StartupLoadout {
        StartupLoadout(schedule: clock.schedule, loadout: { [unowned self] in self.configured },
                       isRunning: { [unowned self] in self.running.contains($0) },
                       isReachable: { [unowned self] in self.reachable.contains($0) },
                       apply: { [unowned self] in self.applied.append($0.name) })
    }

    func testAppliesTwoSecondsInOnceRunningSiblingsListen() {
        let clock = ManualClock()
        let startup = make(clock)
        startup.start()
        XCTAssertEqual(clock.queue.map(\.delay), [2], "nothing before ~2 s")
        XCTAssertTrue(applied.isEmpty)
        clock.runQueued()
        XCTAssertTrue(applied.isEmpty, "a and b are up but not listening yet (c is not running: apply launches it)")
        XCTAssertEqual(clock.queue.map(\.delay), [0.25])
        reachable = ["a"]
        clock.runQueued()
        XCTAssertTrue(applied.isEmpty)
        reachable = ["a", "b"]
        clock.runQueued()
        XCTAssertEqual(applied, ["Desk"])
        XCTAssertTrue(clock.queue.isEmpty, "once only")
    }

    func testGivesUpWaitingAfterItsPatience() {
        let clock = ManualClock()
        let startup = make(clock)
        startup.start()
        var rounds = 0
        while applied.isEmpty && !clock.queue.isEmpty && rounds < 100 { clock.runQueued(); rounds += 1 }
        XCTAssertEqual(applied, ["Desk"])
        XCTAssertEqual(rounds, 1 + Int(StartupLoadout.patience / StartupLoadout.poll), "2 s, then 0.25 s polls for 8 s")
    }

    func testNothingConfiguredDoesNothing() {
        configured = nil
        let clock = ManualClock()
        make(clock).start()
        clock.runQueued()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(clock.queue.isEmpty)
    }

    func testStartupLoadoutIsAConfigKey() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"startupLoadout": "Desk"}"#.utf8))
        XCTAssertEqual(c.startupLoadout, "Desk")
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)).startupLoadout, "Desk")
    }
}
