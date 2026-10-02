import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

// MARK: - Cooperative parking requests

final class CooperativeModeRequestTests: XCTestCase {
    func testParkingSendsTheRestFrameThenTheModeWithEdgeAndPeek() {
        let rest = CGRect(x: 10, y: 20, width: 300, height: 200)
        let requests = ParkingController.modeRequests(panelID: "browser", mode: .parked, rest: rest, edge: .right, peek: 14)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], ["id": "browser", "action": "frame", "x": "10.0", "y": "20.0", "w": "300.0", "h": "200.0"])
        XCTAssertEqual(requests[1], ["id": "browser", "action": "mode", "mode": "parked", "edge": "right", "peek": "14.0"])
    }

    func testRevealIsJustTheMode() {
        let requests = ParkingController.modeRequests(panelID: "p", mode: .full, rest: .zero, edge: .left, peek: 3)
        XCTAssertEqual(requests, [["id": "p", "action": "mode", "mode": "full"]])
    }

    @MainActor
    func testRequestsArriveInOrder() throws {
        let path = "/tmp/gs-order-\(getpid()).sock"
        let server = HUDSocketServer(path: path)
        nonisolated(unsafe) var seen: [String] = []
        server.register("panel") { a, done in
            seen.append(a["action"] == "mode" ? a["mode"] ?? "?" : a["action"] ?? "?")
            done(["ok": true])
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let client = HUDSocketClient(path: path)
        ParkingController.requestMode(client: client, panelID: "p", mode: .parked, rest: CGRect(x: 0, y: 0, width: 10, height: 10))
        ParkingController.requestMode(client: client, panelID: "p", mode: .full)
        ParkingController.requestMode(client: client, panelID: "p", mode: .parked)
        XCTAssertTrue(spin { seen.count == 4 })
        XCTAssertEqual(seen, ["frame", "parked", "full", "parked"], "a quick reveal/conceal is not reordered")
    }
}

// MARK: - MacHUD's own panels honour panel mode

@MainActor
private final class WindowPanel: Panel {
    let id = "tool"
    let title = "Tool"
    let symbol = "hammer"
    private var shown = false
    lazy var made: NSWindow = {
        let w = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 320, height: 200), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }()
    var window: NSWindow? { shown ? made : nil }
    func show() { shown = true; made.orderFrontRegardless() }
    func hide() { made.orderOut(nil) }
}

@MainActor
final class OwnPanelModeTests: XCTestCase {
    func testParkedAndFullGoThroughTheParkingController() throws {
        guard NSScreen.main != nil else { throw XCTSkip("no display") }
        let registry = PanelRegistry()
        let panel = WindowPanel()
        registry.register(panel)
        let dir = FakeBundles.tempDir("ownpark")
        defer { try? FileManager.default.removeItem(at: dir) }
        let parking = ParkingController(panels: registry, stateURL: dir.appendingPathComponent("parking.json"))
        let host = MacHUDPanelHost(registry: registry, parking: parking)
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: dir.appendingPathComponent("x.sock").path))

        var reply: [String: Any] = [:]
        router.handle("panel", args: ["id": "tool", "mode": "parked", "edge": "left", "peek": "4"]) { reply = $0 }
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["mode"] as? String, "parked")
        let entry = try XCTUnwrap(parking.parked.first)
        XCTAssertEqual(entry.record.id, "panel:tool")
        XCTAssertEqual(entry.record.kind, .own)
        XCTAssertEqual(entry.record.edge, .left)
        XCTAssertEqual(entry.record.peek, 4)
        XCTAssertEqual(entry.record.rest, CGRect(x: 300, y: 300, width: 320, height: 200))
        XCTAssertEqual(host.panelStates.first?.mode, .parked)

        router.handle("panel", args: ["id": "tool", "mode": "compact"]) { reply = $0 }
        XCTAssertEqual(reply["mode"] as? String, "full", "no compact form: comes back full size")
        XCTAssertTrue(parking.parked.isEmpty)
        panel.made.orderOut(nil)
    }

    func testWithoutParkingOwnPanelsRefuseParking() {
        let registry = PanelRegistry()
        registry.register(WindowPanel())
        let host = MacHUDPanelHost(registry: registry)
        XCTAssertThrowsError(try host.setPanelMode("tool", mode: .parked))
    }
}

// MARK: - Settings schema rendering

final class SettingsFormTests: XCTestCase {
    private var sift: HUDSettingsSchema {
        let json = """
        {"version": 1, "settings": [
          {"key": "defaultFolder", "title": "Default folder", "type": "path", "help": "Empty reopens the last folder."},
          {"key": "collisionPolicy", "title": "When names collide", "type": "enum",
           "options": [{"value": "keepBoth", "title": "Keep both"}, {"value": "skip", "title": "Skip"}], "default": "keepBoth"},
          {"key": "showHidden", "title": "Show hidden files", "type": "bool", "default": false}]}
        """
        return try! HUDSettingsSchema.decode(Data(json.utf8))
    }

    func testSchemaFieldsBecomeControlsWithReportedValues() {
        let form = SettingsForm.build(schema: sift, values: ["showHidden": true, "defaultFolder": "~/Downloads",
                                                             "extraThing": 3])
        XCTAssertEqual(form.sections.map(\.title), [nil, SettingsForm.otherTitle])
        XCTAssertEqual(form.sections[0].rows.map(\.key), ["defaultFolder", "collisionPolicy", "showHidden"])
        XCTAssertEqual(form.row("defaultFolder")?.control, .path)
        XCTAssertEqual(form.row("defaultFolder")?.text, "~/Downloads")
        XCTAssertEqual(form.row("defaultFolder")?.help, "Empty reopens the last folder.")
        XCTAssertEqual(form.row("showHidden")?.control, .toggle)
        XCTAssertEqual(form.row("showHidden")?.isOn, true)
        guard case .choice(let options)? = form.row("collisionPolicy")?.control else { return XCTFail("not a choice") }
        XCTAssertEqual(options.map(\.title), ["Keep both", "Skip"])
        XCTAssertEqual(form.row("collisionPolicy")?.value, .string("keepBoth"), "falls back to the default")
        XCTAssertEqual(form.row("collisionPolicy")?.isDefault, true)
        XCTAssertEqual(form.row("extraThing")?.control, .number(.integer))
    }

    func testGroupsKeepSchemaOrder() {
        let schema = HUDSettingsSchema(settings: [
            .init(key: "a", type: .bool, group: "One"), .init(key: "b", type: .int, group: "Two"),
            .init(key: "c", type: .string, group: "One"),
        ])
        let form = SettingsForm.build(schema: schema, values: [:])
        XCTAssertEqual(form.sections.map(\.title), ["One", "Two"])
        XCTAssertEqual(form.sections[0].rows.map(\.key), ["a", "c"])
    }

    func testAppWithoutSchemaShowsWhatItReports() {
        // Wormhole: no schema; `sets` is a list.
        let form = SettingsForm.build(schema: nil, values: ["activeSet": "Work", "sets": ["Work", "Home"], "on": false])
        XCTAssertEqual(form.sections.count, 1)
        XCTAssertNil(form.sections[0].title)
        XCTAssertEqual(form.rows.map(\.key), ["activeSet", "on", "sets"])
        XCTAssertEqual(form.row("activeSet")?.control, .text)
        XCTAssertEqual(form.row("on")?.control, .toggle)
        XCTAssertEqual(form.row("sets")?.control, .readOnly)
        XCTAssertEqual(form.row("sets")?.text, "Work, Home")
    }

    func testWireValuesAreValidatedPerControl() throws {
        let form = SettingsForm.build(schema: sift, values: [:])
        let toggle = try XCTUnwrap(form.row("showHidden"))
        XCTAssertEqual(SettingsForm.wireValue(.bool(true), for: toggle), "true")
        let choice = try XCTUnwrap(form.row("collisionPolicy"))
        XCTAssertEqual(SettingsForm.wireValue(.string("skip"), for: choice), "skip")
        XCTAssertNil(SettingsForm.wireValue(.string("merge"), for: choice))
        let number = SettingsForm.Row(key: "n", title: "n", control: .number(.integer), value: nil, help: nil, isDefault: true)
        XCTAssertEqual(SettingsForm.wireValue(.string(" 12 "), for: number), "12")
        XCTAssertNil(SettingsForm.wireValue(.string("twelve"), for: number))
        let readOnly = SettingsForm.Row(key: "s", title: "s", control: .readOnly, value: nil, help: nil, isDefault: false)
        XCTAssertNil(SettingsForm.wireValue(.string("x"), for: readOnly))
    }

    /// Scratch's autosaveDelay: a decimal with bounds and a step.
    private var decimalSchema: HUDSettingsSchema {
        HUDSettingsSchema(settings: [
            .init(key: "autosaveDelay", title: "Autosave delay", type: .number, default: .double(0.75), min: 0.1, max: 10, step: 0.05),
            .init(key: "ratio", type: .number),
            .init(key: "count", type: .int, default: .int(3), min: 1, max: 5),
        ])
    }

    func testNumberFieldsRenderAsBoundedSteppers() throws {
        let form = SettingsForm.build(schema: decimalSchema, values: [:])
        let delay = try XCTUnwrap(form.row("autosaveDelay"))
        XCTAssertEqual(delay.control, .number(NumberSpec(isInteger: false, min: 0.1, max: 10, step: 0.05)))
        XCTAssertEqual(delay.text, "0.75", "the schema default shows while the app is not running")
        XCTAssertTrue(delay.isDefault)
        XCTAssertEqual(form.row("ratio")?.control, .number(.decimal))
        XCTAssertEqual(form.row("count")?.control, .number(NumberSpec(isInteger: true, min: 1, max: 5, step: 1)))
        let reported = SettingsForm.build(schema: decimalSchema, values: ["autosaveDelay": 10.0, "count": 4])
        XCTAssertEqual(reported.row("autosaveDelay")?.text, "10")
        XCTAssertEqual(reported.row("count")?.text, "4")
        // Wire values: parsed, clamped, cleanly formatted; junk is refused.
        XCTAssertEqual(SettingsForm.wireValue(.string(" 0.5 "), for: delay), "0.5")
        XCTAssertEqual(SettingsForm.wireValue(.string("25"), for: delay), "10")
        XCTAssertEqual(SettingsForm.wireValue(.string("0"), for: delay), "0.1")
        XCTAssertNil(SettingsForm.wireValue(.string("soon"), for: delay))
        let count = try XCTUnwrap(form.row("count"))
        XCTAssertEqual(SettingsForm.wireValue(.string("2"), for: count), "2")
        XCTAssertNil(SettingsForm.wireValue(.string("2.5"), for: count))
        XCTAssertEqual(SettingsForm.wireValue(.string("9"), for: count), "5")
    }

    func testNumberSpecStepsParsesAndFormats() {
        let delay = NumberSpec(isInteger: false, min: 0.1, max: 10, step: 0.05)
        XCTAssertEqual(delay.format(0.75), "0.75")
        XCTAssertEqual(delay.format(10), "10")
        XCTAssertEqual(delay.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(delay.stepped(0.75, by: 1), 0.8, accuracy: 1e-9)
        XCTAssertEqual(delay.format(delay.stepped(0.75, by: -1)), "0.7")
        XCTAssertEqual(delay.stepped(10, by: 1), 10, "clamped at max")
        XCTAssertEqual(delay.stepped(0.1, by: -1), 0.1, "clamped at min")
        XCTAssertEqual(delay.stepped(nil, by: 1), 0.15, accuracy: 1e-9, "no value starts at min")
        XCTAssertEqual(delay.parse("abc"), nil)
        XCTAssertEqual(delay.parse("inf"), nil)
        XCTAssertEqual(delay.parse("3"), 3)
        XCTAssertEqual(NumberSpec.decimal.step, 0.1)
        XCTAssertEqual(NumberSpec.decimal.format(NumberSpec.decimal.stepped(0.2, by: 1)), "0.3")
        let count = NumberSpec(isInteger: true, min: 1, max: 5)
        XCTAssertEqual(count.step, 1)
        XCTAssertEqual(count.stepped(5, by: 1), 5)
        XCTAssertEqual(count.stepped(3, by: -1), 2)
        XCTAssertEqual(count.format(4), "4")
        XCTAssertNil(count.parse("1.5"))
        XCTAssertEqual(NumberSpec(isInteger: false, step: -1).step, 0.1, "a bad step falls back")
    }

    func testFormJSONForTheSocket() {
        let json = SettingsForm.build(schema: sift, values: ["showHidden": true]).json
        let rows = json.first?["rows"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["key"] as? String }, ["defaultFolder", "collisionPolicy", "showHidden"])
        XCTAssertEqual(rows.last?["value"] as? Bool, true)
        XCTAssertEqual(rows[1]["control"] as? String, "choice")
    }

    @MainActor
    func testMacHUDOwnSettings() {
        var config = Config.defaults
        config.gap = 6
        config.trigger = .option
        let values = MacHUDSettings.values(config: config, enabled: true, orbsHidden: false)
        XCTAssertEqual(values["gap"] as? Int, 6)
        XCTAssertEqual(values["trigger"] as? String, "option")
        let form = SettingsForm.build(schema: MacHUDSettings.schema, values: values)
        XCTAssertEqual(form.sections.map(\.title), ["Snapping", "Layout", "Parking", "Tool Dock", "Hotkeys", "Menu Bar"])
        XCTAssertTrue(form.rows.allSatisfy { !$0.isDefault }, "MacHUD reports every key in its schema")

        let parsed = try! MacHUDSettings.schema.validate(["gap": "12", "trigger": "command", "browser": " "])
        let updated = MacHUDSettings.applying(parsed, to: config)
        XCTAssertEqual(updated.gap, 12)
        XCTAssertEqual(updated.trigger, .command)
        XCTAssertNil(updated.browser)
        XCTAssertThrowsError(try MacHUDSettings.schema.validate(["trigger": "hyper"]))
    }
}

// MARK: - Placement defaults

final class PlacementConfigTests: XCTestCase {
    func testPerAppPlacementRoundTripsNextToTheKnownKeys() throws {
        let json = """
        {"searchPaths": ["~/dev/*/build"], "standardDirectories": false,
         "xyz.machud.sift": {"placement": {"region": "left"}},
         "JER.wormhole": {"placement": {"mode": "parked", "edge": "right", "peek": 12}}}
        """
        let config = try JSONDecoder().decode(AppsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.searchPaths, ["~/dev/*/build"])
        XCTAssertEqual(config.standardDirectories, false)
        XCTAssertEqual(config.placement(for: "xyz.machud.sift"), AppPlacement(region: "left"))
        XCTAssertEqual(config.placement(for: "JER.wormhole"), AppPlacement(mode: .parked, edge: .right, peek: 12))
        XCTAssertNil(config.placement(for: "other"))
        let again = try JSONDecoder().decode(AppsConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again, config)
        // A whole config file keeps it through a save.
        let file = #"{"layouts": [], "apps": \#(json)}"#
        let decoded = try JSONDecoder().decode(Config.self, from: Data(file.utf8))
        XCTAssertEqual(decoded.apps, config)
    }

    func testModeDefaultsFollowTheRegion() {
        XCTAssertTrue(AppPlacement(edge: .right).isParked, "no region: parked")
        XCTAssertFalse(AppPlacement(region: "left").isParked, "a region: placed there")
        XCTAssertTrue(AppPlacement(mode: .parked, region: "left").isParked)
    }

    func testRestFrameSitsOnTheEdgeAtDefaultSize() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let size = CGSize(width: 900, height: 560)
        XCTAssertEqual(AppPlacement.restFrame(size: size, edge: .right, visible: visible),
                       CGRect(x: 540, y: 183, width: 900, height: 560))
        XCTAssertEqual(AppPlacement.restFrame(size: size, edge: .left, visible: visible).minX, 0)
        XCTAssertEqual(AppPlacement.restFrame(size: size, edge: .top, visible: visible).maxY, 900)
        XCTAssertEqual(AppPlacement.restFrame(size: CGSize(width: 3000, height: 100), edge: .bottom, visible: visible),
                       CGRect(x: 0, y: 25, width: 1440, height: 100), "shrunk to fit")
    }

    func testRegionLookupByIdThenName() {
        let layout = Layout(name: "Halves", regions: [
            Region(id: "r1", name: "Left", x: 0, y: 0, w: 0.5, h: 1),
            Region(id: "r2", name: "Right", x: 0.5, y: 0, w: 0.5, h: 1),
        ])
        XCTAssertEqual(AppPlacement.region("r2", in: layout)?.id, "r2")
        XCTAssertEqual(AppPlacement.region("left", in: layout)?.id, "r1")
        XCTAssertNil(AppPlacement.region("middle", in: layout))
    }
}

@MainActor
final class PlacementOnLaunchTests: XCTestCase {
    private let id = "dev.test.placed"
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var externals: ExternalPanels!
    private var config = AppsConfig()
    private var placed: [AppPlacement] = []
    private var app: ExternalApp!

    override func setUp() {
        workspace = FakeWorkspace()
        workspace.installed = [id]
        connector = FakeConnector()
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned self] in self.clock.now }
        app = ExternalApp(manifest: HUDManifest(id: id, name: "Placed", socket: "/tmp/gs-placed.sock",
                                                panels: [HUDManifest.Panel(id: "main", title: "Main", verbs: ["frame"])]),
                          bundleURL: URL(fileURLWithPath: "/tmp/Placed.app"))
        connector.reachable = [app.socketPath]
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { [unowned self] in self.config }
        externals.placer = { [unowned self] _, placement in self.placed.append(placement); return nil }
    }

    func testLaunchAppliesThePlacementOnceTheAppListens() throws {
        config = AppsConfig(perApp: [id: AppEntryConfig(placement: AppPlacement(mode: .parked, edge: .right))])
        externals.install([app], autoLaunch: [])
        XCTAssertEqual(try externals.launch(app, manual: true).get(), "pending")
        XCTAssertEqual(workspace.launches, [id])
        XCTAssertTrue(placed.isEmpty, "not before it is up")
        workspace.start(id)
        clock.runQueued()                     // connect → running → placement scheduled
        XCTAssertEqual(externals.supervisor.record(id)?.health, .running)
        XCTAssertTrue(placed.isEmpty, "waits a moment for the window")
        clock.runQueued()
        XCTAssertEqual(placed, [AppPlacement(mode: .parked, edge: .right)])
        XCTAssertEqual(externals.placementResults[id], "applied")
        clock.runQueued()
        XCTAssertEqual(placed.count, 1, "once")
    }

    func testAlreadyRunningOrUnconfiguredAppsAreLeftAlone() throws {
        externals.install([app], autoLaunch: [])
        XCTAssertEqual(try externals.launch(app, manual: true).get(), "none")
        config = AppsConfig(perApp: [id: AppEntryConfig(placement: AppPlacement(region: "left"))])
        workspace.start(id)
        clock.runQueued()
        XCTAssertEqual(try externals.launch(app, manual: true).get(), "running")
        clock.runQueued()
        XCTAssertTrue(placed.isEmpty)
        // `apps place` applies it on request.
        XCTAssertNil(externals.place(app))
        XCTAssertEqual(placed, [AppPlacement(region: "left")])
    }

    func testAutoLaunchedAppsGetTheirPlacementToo() {
        config = AppsConfig(perApp: [id: AppEntryConfig(placement: AppPlacement(edge: .left))])
        externals.install([app], autoLaunch: [id])
        XCTAssertEqual(workspace.launches, [id])
        workspace.start(id)
        clock.runQueued()
        clock.runQueued()
        XCTAssertEqual(placed, [AppPlacement(edge: .left)])
    }

    func testAutoLaunchOffLaunchesAndPlacesNothing() {
        // An isolated instance (`Env.autoApply` false) never starts the user's apps.
        config = AppsConfig(perApp: [id: AppEntryConfig(placement: AppPlacement(edge: .left))])
        externals.autoLaunches = false
        externals.install([app], autoLaunch: [id])
        XCTAssertEqual(workspace.launches, [])
        XCTAssertEqual(externals.supervisor.record(id)?.autoLaunch, false)
        workspace.start(id)
        clock.runQueued()
        clock.runQueued()
        XCTAssertTrue(placed.isEmpty)
    }

    func testPlacementIsDroppedIfTheAppNeverListens() throws {
        config = AppsConfig(perApp: [id: AppEntryConfig(placement: AppPlacement(edge: .left))])
        connector.reachable = []
        externals.install([app], autoLaunch: [])
        _ = try externals.launch(app, manual: true).get()
        clock.now += ExternalPanels.placementTimeout + 1
        workspace.start(id)
        clock.runQueued()
        connector.reachable = [app.socketPath]
        externals.supervisor.connect(id)
        clock.runQueued()
        XCTAssertTrue(placed.isEmpty)
        XCTAssertEqual(externals.placementResults[id], "timed out waiting for the app to listen")
    }

    func testStoppedAppIsReportedSoItsParkingsGo() throws {
        var stopped: [String] = []
        externals.onAppStopped = { stopped.append($0.id) }
        externals.install([app], autoLaunch: [])
        workspace.start(id)
        clock.runQueued()
        XCTAssertTrue(stopped.isEmpty)
        workspace.stop(id)
        XCTAssertEqual(stopped, [id])

        let dir = FakeBundles.tempDir("forget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let parking = ParkingController(panels: externals.registry, stateURL: dir.appendingPathComponent("p.json"))
        let rest = CGRect(x: 0, y: 0, width: 200, height: 100)
        parking.park(.cooperative(HUDSocketClient(path: app.socketPath), panelID: "main"), id: "a", label: "A",
                     rest: rest, edge: .left, peek: 0, screen: NSScreen.main)
        parking.park(.cooperative(HUDSocketClient(path: "/tmp/other.sock"), panelID: "main"), id: "b", label: "B",
                     rest: rest, edge: .right, peek: 0, screen: NSScreen.main)
        parking.forgetCooperative(socketPath: app.socketPath)
        XCTAssertEqual(parking.parked.map(\.record.id), ["b"])
        XCTAssertEqual(parking.orbJSON().map { $0["edge"] as? String }, ["right"], "the left orb went with it")
        parking.forgetCooperative(socketPath: "/tmp/other.sock")
    }

    // MARK: Picker and menu

    func testPickerListsOwnThenSiblingPanels() {
        let registry = externals.registry
        registry.register(WebPanelStub(id: "servers", title: "Dev Servers"))
        registry.register(WebPanelStub(id: "web:https://x", title: "x"))
        externals.install([app], autoLaunch: [])
        let choices = PanelChoice.all(in: registry)
        XCTAssertEqual(choices.map(\.id), ["servers", "\(id)/main"])
        XCTAssertFalse(choices[0].isExternal)
        XCTAssertEqual(choices[1].label, "Placed · Main (not running)")
        workspace.start(id)
        clock.runQueued()
        XCTAssertEqual(PanelChoice.all(in: registry)[1].label, "Placed · Main")
    }

    func testMenuOffersLaunchThenParkAndQuitOnceRunning() {
        externals.install([app], autoLaunch: [])
        var entry = MacHUDMenuModel.entries(externals: externals) { _ in .full }.first
        XCTAssertEqual(entry?.actions.map(\.kind), [.summon, .separator, .dockToggle, .settings, .separator, .launch])
        XCTAssertEqual(entry?.actions.first?.title, "Show Placed")
        XCTAssertEqual(entry?.title, "○ Placed")
        workspace.start(id)
        clock.runQueued()
        entry = MacHUDMenuModel.entries(externals: externals) { _ in .full }.first
        XCTAssertEqual(entry?.actions.map(\.kind), [.summon, .separator, .appMenu, .separator, .park, .dockToggle, .settings, .separator, .relaunch, .quit])
        XCTAssertEqual(entry?.actions.last { $0.kind == .relaunch }?.title, "Relaunch Placed")
        entry = MacHUDMenuModel.entries(externals: externals, liveMenus: false) { _ in .full }.first
        XCTAssertEqual(entry?.actions.map(\.kind), [.summon, .separator, .park, .dockToggle, .settings, .separator, .relaunch, .quit],
                       "no app menu with menuBar.consumeSiblings off")
        entry = MacHUDMenuModel.entries(externals: externals) { _ in .parked }.first
        XCTAssertEqual(entry?.actions.map(\.kind), [.summon, .separator, .appMenu, .separator, .reveal, .dockToggle, .settings, .separator, .relaunch, .quit])
        XCTAssertEqual(entry?.actions[4].panelID, "\(id)/main")
    }

    func testLaunchAllStartsWhatIsDownAndQuitAllStopsWhatIsUp() throws {
        let other = ExternalApp(manifest: HUDManifest(id: "dev.test.other", name: "Other", socket: "/tmp/gs-other.sock",
                                                      panels: [HUDManifest.Panel(id: "main", title: "Main")]),
                                bundleURL: URL(fileURLWithPath: "/tmp/Other.app"))
        let missing = ExternalApp(manifest: HUDManifest(id: "dev.test.missing", name: "Missing", socket: "/tmp/gs-missing.sock",
                                                        panels: [HUDManifest.Panel(id: "main", title: "Main")]),
                                  bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"))
        workspace.installed.insert(other.id)
        connector.reachable.insert(other.socketPath)
        externals.install([app, other, missing], autoLaunch: [])
        workspace.start(id)
        clock.runQueued()
        XCTAssertTrue(MacHUDMenuModel.bulk(externals: externals) == (true, true))

        let launched = externals.launchAll()
        XCTAssertEqual(Set(launched.keys), [other.id, missing.id], "the running app is left alone")
        XCTAssertEqual(try launched[other.id]?.get(), "none")
        guard case .failure(.notInstalled) = launched[missing.id] else { return XCTFail("\(String(describing: launched[missing.id]))") }
        XCTAssertEqual(workspace.launches, [other.id])
        workspace.start(other.id, pid: 4343)
        clock.runQueued()

        var quit: [String: String]?
        externals.quitAll { quit = $0 }
        XCTAssertEqual(quit, [id: "quit", other.id: "quit"], "the uninstalled app is not up")
        XCTAssertEqual(connector.requests.filter { $0.command == "quit" }.map(\.path).sorted(),
                       [app.socketPath, other.socketPath].sorted())
        workspace.stop(id)
        workspace.stop(other.id)
        XCTAssertTrue(MacHUDMenuModel.bulk(externals: externals) == (true, false))

        quit = nil
        externals.quitAll { quit = $0 }
        XCTAssertEqual(quit, [:], "nothing up answers at once")
    }
}

@MainActor
private final class WebPanelStub: Panel {
    let id: String
    let title: String
    let symbol = "globe"
    var window: NSWindow? { nil }
    init(id: String, title: String) { self.id = id; self.title = title }
    func show() {}
    func hide() {}
}
