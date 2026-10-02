import XCTest
import HUDKit
@testable import MacHUDCore

/// The widget layer against a fake app: sync on connect, the changes it sends, events.
@MainActor
final class WidgetLayerTests: XCTestCase {
    let appID = "xyz.widgets", sock = "/tmp/gs-wl-widgets.sock"
    let otherID = "xyz.other", otherSock = "/tmp/gs-wl-other.sock"
    var workspace: FakeWorkspace!
    var connector: FakeConnector!
    var clock: ManualClock!
    var externals: ExternalPanels!
    var layer: WidgetLayer!
    var stored = WidgetsConfig()
    var saves = 0
    var toasts: [String] = []
    var summoned: [String] = []
    var configured: [String] = []
    let main = WidgetScreen(descriptor: ScreenDescriptor(name: "Main", isMain: true, isBuiltin: true), ref: .builtin,
                            visible: CGRect(x: 0, y: 0, width: 1440, height: 875), frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    let side = WidgetScreen(descriptor: ScreenDescriptor(name: "Side", isMain: false, isBuiltin: false, persistentID: "1-2-3"),
                            ref: .display(id: "1-2-3", name: "Side"),
                            visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055), frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    let schema = HUDSettingsSchema(settings: [
        HUDSettingsSchema.Field(key: "units", type: .enum, default: .string("c"),
                                options: [HUDSettingsSchema.Option(value: "c"), HUDSettingsSchema.Option(value: "f")]),
    ])

    var app: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: appID, name: "Widgets", socket: sock, panels: [
            HUDManifest.Panel(id: "clock", title: "Clock", symbol: "clock", kind: .widget,
                              widget: HUDWidgetSpec(sizes: [.small, .medium])),
            HUDManifest.Panel(id: "weather", title: "Weather", symbol: "cloud.sun", kind: .widget,
                              widget: HUDWidgetSpec(sizes: [.small, .medium, .large], multiple: false, settingsSchema: "w.json")),
            HUDManifest.Panel(id: "pad", title: "Pad", verbs: ["show", "hide"], kind: .hover),
        ]), bundleURL: URL(fileURLWithPath: "/tmp/Widgets.app"))
    }

    var other: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: otherID, name: "Other", socket: otherSock, panels: [
            HUDManifest.Panel(id: "main", title: "Main")]), bundleURL: URL(fileURLWithPath: "/tmp/Other.app"))
    }

    override func setUp() {
        workspace = FakeWorkspace()
        workspace.installed = [appID, otherID]
        connector = FakeConnector()
        connector.reachable = [sock, otherSock]
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned self] in self.clock.now }
        supervisor.windowProbe = { _, _ in .onScreen }
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        layer = WidgetLayer(externals: externals, config: { [unowned self] in self.stored },
                            save: { [unowned self] in self.stored = $0; self.saves += 1 })
        layer.screens = { [unowned self] in [self.main, self.side] }
        var n = 0
        layer.newID = { n += 1; return "W\(n)" }
        layer.notify = { [unowned self] text, _ in self.toasts.append(text) }
        layer.schemaLoader = { [unowned self] _, type in type == "weather" ? self.schema : nil }
        layer.summon = { [unowned self] in self.summoned.append($0) }
        layer.configure = { [unowned self] in self.configured.append($0.instance) }
        externals.keepRunning = { [unowned self] in self.layer.appsWithInstances }
        supervisor.onConnected = { [unowned self] in self.layer.appConnected($0) }
        supervisor.onAppEvent = { [unowned self] id, event in self.layer.handle(event: event, from: id) }
        externals.install([app, other], autoLaunch: [])
    }

    private func startApp(_ id: String? = nil) {
        workspace.start(id ?? appID)
        clock.runQueued()
    }

    private var widgetRequests: [[String: String]] {
        connector.requests.filter { $0.path == sock && $0.command == "widget" }.map(\.args)
    }

    private func call(_ args: [String: String]) -> [String: Any] {
        var reply: [String: Any] = [:]
        layer.handle(args) { reply = $0 }
        return reply
    }

    private func syncedInstances(_ args: [String: String]?) throws -> [[String: Any]] {
        let text = try XCTUnwrap(args?["instances"])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    // MARK: Sync

    func testAnAppServingWidgetsGetsItsWholeStateOnConnect() throws {
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, x: 0, y: 0,
                                         settings: ["zone": .string("UTC")]),
                            WidgetRecord(instance: "B", app: appID, type: "radar", size: .small, x: 0.25, y: 0)]
        startApp()
        let sync = widgetRequests.first
        XCTAssertEqual(sync?["action"], "sync")
        XCTAssertEqual(sync?["editing"], "off")
        XCTAssertEqual(sync?["revealed"], "off")
        let list = try syncedInstances(sync)
        XCTAssertEqual(list.count, 1, "a type the app does not serve is kept but not sent")
        XCTAssertEqual(list.first?["instance"] as? String, "A")
        XCTAssertEqual(list.first?["frame"] as? [Double], [0, 705, 170, 170])
        XCTAssertEqual((list.first?["settings"] as? [String: Any])?["zone"] as? String, "UTC")
        XCTAssertNil(connector.requests.first { $0.path == otherSock && $0.command == "widget" }, "no widgets, no sync")
        startApp(otherID)
        XCTAssertNil(connector.requests.first { $0.path == otherSock && $0.command == "widget" })

        let rows = layer.listJSON()
        XCTAssertEqual(rows.first { $0["instance"] as? String == "B" }?["missingType"] as? Bool, true)
        XCTAssertEqual(rows.first { $0["instance"] as? String == "A" }?["health"] as? String, "running")
    }

    func testRejectedAndDroppedAreMarkedAndToastedOnce() {
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, x: 0, y: 0),
                            WidgetRecord(instance: "B", app: appID, type: "weather", size: .small, x: 0.25, y: 0,
                                         settings: ["units": .string("k")])]
        connector.replies["widget"] = ["ok": true, "rejected": [["instance": "A", "error": "no widget type clock (weather)"]],
                                       "droppedSettings": [["instance": "B", "key": "units", "error": "units must be one of c, f"]]]
        startApp()
        XCTAssertEqual(layer.problems["A"], "no widget type clock (weather)")
        XCTAssertEqual(layer.droppedSettings["B"], ["units": "units must be one of c, f"])
        XCTAssertEqual(toasts, ["Widgets could not restore 1 widget"])
        let a = layer.listJSON().first { $0["instance"] as? String == "A" }
        XCTAssertEqual(a?["problem"] as? String, "no widget type clock (weather)")
        connector.requests = []
        layer.configChanged()
        XCTAssertTrue(widgetRequests.isEmpty, "a refused widget is not offered again until it changes")
        // A reconnect reports nothing new.
        workspace.stop(appID)
        startApp()
        XCTAssertEqual(toasts.count, 1)
    }

    func testAppsWithWidgetsAreKeptRunning() {
        externals.install([app, other], autoLaunch: [])
        XCTAssertEqual(externals.supervisor.record(appID)?.autoLaunch, false)
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, x: 0, y: 0)]
        externals.refreshKeepRunning()
        XCTAssertEqual(externals.supervisor.record(appID)?.autoLaunch, true)
        XCTAssertEqual(workspace.launches, [appID], "and launched now")
        XCTAssertEqual(externals.supervisor.record(otherID)?.autoLaunch, false)

        // Quit by the user: no longer kept, and not launched again when its widgets change.
        workspace.start(appID)
        clock.runQueued()
        externals.supervisor.quit(appID) { _ in }
        workspace.stop(appID)
        clock.runQueued()
        stored.instances = []
        externals.refreshKeepRunning()
        stored.instances = [WidgetRecord(instance: "B", app: appID, type: "clock", size: .small, x: 0, y: 0)]
        externals.refreshKeepRunning()
        XCTAssertEqual(workspace.launches, [appID], "the user quit it")
    }

    // MARK: The verb

    func testAddSendsCreateAtTheFirstFreeCellsAndPersists() throws {
        startApp()
        stored.instances = []
        _ = call(["action": "add", "type": "clock", "size": "medium"])
        connector.requests = []
        let reply = call(["action": "add", "app": "Widgets", "type": "clock", "settings": #"{"zone": "UTC"}"#])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let instance = try XCTUnwrap(reply["instance"] as? [String: Any])
        XCTAssertEqual(instance["instance"] as? String, "W2")
        XCTAssertEqual(instance["frame"] as? [Double], [0, 527, 170, 170], "below the medium one, on the next line")
        let create = try XCTUnwrap(widgetRequests.last)
        XCTAssertEqual(create["action"], "create")
        XCTAssertEqual(create["frame"], "0,527,170,170")
        XCTAssertEqual(create["settings"], #"{"zone":"UTC"}"#)
        XCTAssertEqual(stored.instances.map(\.instance), ["W1", "W2"])
        XCTAssertNil(stored.instances[1].screen, "no screen given: the main display")
    }

    func testAddRefusesWhatTheTypeDoesNotAllowAndRollsBackWhatTheAppRefuses() {
        startApp()
        XCTAssertEqual(call(["action": "add", "type": "clock", "size": "large"])["error"] as? String,
                       "clock size must be one of small, medium")
        XCTAssertEqual(call(["action": "add", "type": "radar"])["error"] as? String, "no widget type radar (clock, weather)")
        XCTAssertEqual(call(["action": "add", "type": "weather"])["ok"] as? Bool, true)
        XCTAssertEqual(call(["action": "add", "type": "weather"])["error"] as? String, "weather allows one instance")
        XCTAssertEqual(call(["action": "add", "type": "weather", "settings": #"{"units": "k"}"#])["error"] as? String,
                       "units must be one of c, f")
        connector.replies["widget"] = ["ok": false, "error": "no widget type clock (weather)"]
        let refused = call(["action": "add", "type": "clock"])
        XCTAssertEqual(refused["error"] as? String, "Widgets refused it: no widget type clock (weather)")
        XCTAssertEqual(stored.instances.map(\.type), ["weather"], "rolled back")
    }

    func testAddWhileTheAppIsDownLaunchesItAndTheSyncCarriesIt() throws {
        let reply = call(["action": "add", "type": "clock", "col": "2", "row": "1"])
        XCTAssertEqual(reply["note"] as? String, "launching Widgets")
        XCTAssertEqual(workspace.launches, [appID])
        XCTAssertTrue(widgetRequests.isEmpty)
        startApp()
        let list = try syncedInstances(widgetRequests.first)
        XCTAssertEqual(list.first?["frame"] as? [Double], [30, 689, 170, 170], "lines 2 and 1")
        XCTAssertEqual(widgetRequests.count, 1, "nothing sent twice")
    }

    func testMoveResizeLayerAndSettingsSendUpdates() throws {
        startApp()
        _ = call(["action": "add", "type": "clock"])                       // W1 at the top-left
        _ = call(["action": "add", "type": "weather", "col": "0", "row": "0"])   // taken: W2 flush under it
        XCTAssertEqual(layer.placements()["W2"]?.frame, CGRect(x: 0, y: 535, width: 170, height: 170))
        connector.requests = []

        var reply = call(["action": "move", "instance": "W2", "col": "24", "row": "0"])
        XCTAssertNil(reply["note"])
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "360,705,170,170"])
        XCTAssertEqual(stored.instances.last?.x, 0.25)
        reply = call(["action": "move", "instance": "W2", "x": "0", "y": "0"])
        XCTAssertEqual(reply["note"] as? String, "0,0 is taken; placed at 0,10.51 on Main")
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "0,535,170,170"])

        reply = call(["action": "move", "instance": "W2", "col": "0", "row": "0", "screen": "Side"])
        XCTAssertEqual(stored.instances.last?.screen, .display(id: "1-2-3", name: "Side"))
        XCTAssertEqual(widgetRequests.last?["frame"], "1440,885,170,170")

        reply = call(["action": "resize", "instance": "W2", "size": "large"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "size": "large", "frame": "1440,699,356,356"])

        reply = call(["_": "layer", "instance": "W2", "float": "1"])
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "layer": "float"])

        reply = call(["_": "settings", "settings": "1", "instance": "W2", "units": "f"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "settings": #"{"units":"f"}"#])
        XCTAssertEqual(call(["action": "settings", "instance": "W2", "units": "k"])["error"] as? String, "units must be one of c, f")

        reply = call(["action": "remove", "instance": "W1"])
        XCTAssertEqual(widgetRequests.last, ["action": "remove", "instance": "W1"])
        XCTAssertEqual(stored.instances.map(\.instance), ["W2"])
    }

    func testEditAndRevealGoToEveryConnectedApp() {
        startApp()
        connector.requests = []
        XCTAssertEqual(call(["_": "edit", "edit": "1", "on": "1"])["editing"] as? Bool, true)
        XCTAssertEqual(widgetRequests.last, ["action": "edit", "state": "on"])
        XCTAssertEqual(call(["action": "reveal"])["revealed"] as? Bool, true, "toggles")
        XCTAssertEqual(widgetRequests.last, ["action": "reveal", "state": "on"])
        XCTAssertEqual(call(["action": "reveal", "state": "off"])["revealed"] as? Bool, false)
        // A reconnect carries the modes in its sync.
        workspace.stop(appID)
        startApp()
        XCTAssertEqual(widgetRequests.last?["editing"], "on")
        XCTAssertEqual(widgetRequests.last?["revealed"], "off")
    }

    func testListGivesPositionsAsFractionsAndGridLines() throws {
        startApp()
        _ = call(["action": "add", "type": "clock", "col": "12", "row": "27"])
        let w = try XCTUnwrap(layer.listJSON().first)
        XCTAssertEqual(w["x"] as? Double, 0.125)
        XCTAssertEqual(w["y"] as? Double, 0.5)
        XCTAssertEqual(w["col"] as? Int, 12)
        XCTAssertEqual(w["row"] as? Int, 27)
        XCTAssertEqual(w["frame"] as? [Double], [180, 268, 170, 170])
        XCTAssertEqual(call(["action": "list"])["grid"] as? [String: Int], ["cols": 96, "rows": 54])
        // Its right edge on a line: fractional line units.
        _ = call(["action": "move", "instance": "W1", "x": "0.99", "y": "0"])
        let moved = try XCTUnwrap(layer.listJSON().first)
        XCTAssertEqual(moved["col"] as? Double, 84.67, "flush with the right edge: 1270 pt is 84.67 lines")
        XCTAssertEqual(moved["frame"] as? [Double], [1270, 705, 170, 170])
    }

    func testPositionArgumentsAreFractionsOrGridLines() {
        startApp()
        XCTAssertEqual(call(["action": "add", "type": "clock", "x": "0.5"])["error"] as? String, "give both x= and y=")
        XCTAssertEqual(call(["action": "add", "type": "clock", "x": "1.5", "y": "0"])["error"] as? String,
                       "x and y must be numbers from 0 to 1")
        XCTAssertEqual(call(["action": "add", "type": "clock", "x": "0", "y": "0", "col": "1", "row": "1"])["error"] as? String,
                       "give x= y= or col= row=, not both")
        XCTAssertEqual(call(["action": "add", "type": "clock", "col": "97", "row": "0"])["error"] as? String,
                       "col must be a grid line from 0 to 96 and row one from 0 to 54")
        XCTAssertEqual(call(["action": "add", "type": "clock", "col": "48", "row": "0"])["ok"] as? Bool, true)
        XCTAssertEqual(layer.placements()["W1"]?.frame.minX, 720)
        XCTAssertEqual(call(["action": "move", "instance": "W1"])["error"] as? String, "widgets move needs x= y= or col= row=")
    }

    func testTypesListsEveryWidgetType() throws {
        let types = layer.typesJSON()
        XCTAssertEqual(types.map { $0["type"] as? String }, ["clock", "weather"])
        XCTAssertEqual(types[1]["multiple"] as? Bool, false)
        XCTAssertEqual(types[1]["sizes"] as? [String], ["small", "medium", "large"])
        XCTAssertNotNil(types[1]["settingsSchema"])
        XCTAssertNil(types[0]["settingsSchema"])
    }

    // MARK: Events

    private func event(_ fields: [String: Any]) {
        var e = fields
        e["event"] = "widget"
        connector.onEvents[sock]?(e)
    }

    func testDraggedWidgetSnapsToTheNearestFreeSpot() {
        startApp()
        _ = call(["action": "add", "type": "clock"])           // W1 top-left
        _ = call(["action": "add", "type": "clock"])           // W2 under it
        connector.requests = []
        event(["instance": "W2", "change": "frame", "frame": [30, 690, 170, 170]])   // dropped onto W1
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "175,689,170,170"],
                       "the nearest free snapped spot: beside W1, right edge on line 23")
        // Its right edge (390) is on line 26; its bottom edge is nearer line 11 than its top to line 0.
        event(["instance": "W2", "change": "frame", "frame": [220, 700, 170, 170]])
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "220,697,170,170"])
        XCTAssertEqual(stored.instances[1].x, 220.0 / 1440, accuracy: 1e-6)
        event(["instance": "W2", "change": "frame", "frame": [1500, 800, 170, 170]])   // onto the side display
        XCTAssertEqual(stored.instances[1].screen, .display(id: "1-2-3", name: "Side"))
        XCTAssertEqual(widgetRequests.last?["frame"], "1500,801,170,170", "the side display's own grid (20 × 19.5 pt)")
    }

    func testSizeRemoveSettingsConfigureAndOpenEvents() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        connector.requests = []
        event(["instance": "W1", "change": "size", "size": "medium"])
        XCTAssertEqual(stored.instances[0].size, .medium)
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W1", "size": "medium", "frame": "0,705,356,170"])
        event(["instance": "W1", "change": "settings", "settings": ["zone": "Asia/Tokyo"]])
        XCTAssertEqual(stored.instances[0].settings, ["zone": .string("Asia/Tokyo")])
        XCTAssertEqual(widgetRequests.count, 1, "already applied by the app: nothing sent")
        event(["instance": "W1", "change": "configure"])
        XCTAssertEqual(configured, ["W1"])
        event(["instance": "W1", "change": "open"])
        XCTAssertEqual(summoned, ["\(appID)/pad"])
        event(["instance": "W1", "change": "remove"])
        XCTAssertTrue(stored.instances.isEmpty)
        XCTAssertEqual(widgetRequests.last, ["action": "remove", "instance": "W1"])
    }

    func testAnEventFromAnotherAppIsIgnored() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        layer.handle(event: ["event": "widget", "instance": "W1", "change": "remove"], from: otherID)
        XCTAssertEqual(stored.instances.count, 1)
    }

    // MARK: Outside changes

    func testAHandEditOrDisplayChangeIsReconciled() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        connector.requests = []
        stored.instances[0].x = 0.25
        stored.instances.append(WidgetRecord(instance: "X", app: appID, type: "weather", size: .small, x: 0, y: 0))
        layer.configChanged()
        let actions = widgetRequests.map { "\($0["action"]!) \($0["instance"]!)" }
        XCTAssertEqual(actions, ["update W1", "create X"])
        XCTAssertEqual(widgetRequests.first?["frame"], "360,705,170,170")
        connector.requests = []
        layer.configChanged()
        XCTAssertTrue(widgetRequests.isEmpty, "nothing changed: nothing sent")
    }

    func testFramesForShowVerification() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        XCTAssertEqual(layer.frames(app: appID), [CGRect(x: 0, y: 705, width: 170, height: 170)])
        XCTAssertEqual(layer.frames(app: otherID), [])
    }

    func testAnAppThatComesBackIsKeptRunningAtOnce() {
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, x: 0, y: 0)]
        externals.install([other], autoLaunch: [])            // gone for a moment (a rebuild swaps the bundle)
        externals.install([app, other], autoLaunch: [])
        XCTAssertEqual(externals.supervisor.record(appID)?.autoLaunch, true)
    }

    func testAModeChangedDuringTheSyncIsSentAfterIt() {
        connector.deferred = []
        startApp()
        XCTAssertEqual(connector.deferred?.map(\.command).contains("widget"), true)
        layer.setEditing(true)
        XCTAssertTrue(widgetRequests.filter { $0["action"] == "edit" }.isEmpty, "not synced yet")
        let held = connector.deferred ?? []
        connector.deferred = nil
        for item in held { item.reply() }
        XCTAssertEqual(widgetRequests.last, ["action": "edit", "state": "on"])
    }

    func testAWholeNumberSettingReadBackAsAnIntIsNotResent() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        event(["instance": "W1", "change": "settings", "settings": ["scale": 1.0]])
        connector.requests = []
        stored.instances[0].settings = ["scale": .int(1)]      // layouts.json writes 1.0 as 1
        layer.configChanged()
        XCTAssertTrue(widgetRequests.isEmpty)
    }

    func testArgumentsWithoutASubVerbAreAnError() {
        XCTAssertEqual(call([:])["ok"] as? Bool, true, "bare widgets lists")
        XCTAssertEqual(call(["instance": "W1", "size": "small"])["error"] as? String,
                       "widgets action must be one of list, types, add, remove, move, resize, layer, settings, edit, reveal")
    }

    func testWidgetFramesAreRecognisedForDragSnapping() {
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, x: 0, y: 0)]
        XCTAssertTrue(layer.isWidgetFrame(CGRect(x: 0, y: 705, width: 170, height: 170)))
        XCTAssertFalse(layer.isWidgetFrame(CGRect(x: 0, y: 705, width: 400, height: 170)))
    }

    // MARK: Menu

    func testWidgetsMenuOffersRevealEditAddAndEachWidget() throws {
        startApp()
        _ = call(["action": "add", "type": "weather"])
        _ = call(["action": "reveal", "state": "on"])
        typealias I = WidgetMenuModel.Item
        let items = WidgetMenuModel.items(layer, hotkey: Hotkeys.defaultWidgets)
        XCTAssertEqual(items.prefix(2), [.action("Reveal Widgets  ⌃⌥W", .reveal, on: true), .action("Edit Widgets…", .edit, on: false)])
        guard case .submenu("Add Widget", _, let add) = items[2] else { return XCTFail("\(items[2])") }
        XCTAssertEqual(add.map(\.title), ["Widgets", "Clock", "Weather"])
        guard case .submenu(_, _, let weatherSizes) = add[2] else { return XCTFail() }
        XCTAssertEqual(weatherSizes.first, .action("Small", .add(app: appID, type: "weather", size: .small), enabled: false),
                       "weather allows one instance")
        XCTAssertEqual(items[3], .separator)
        guard case .submenu(let title, _, let actions) = items[4] else { return XCTFail() }
        XCTAssertEqual(title, "Weather (Small, Main)")
        XCTAssertEqual(actions, [.action("Settings…", .settings("W1")), .action("Float Above Windows", .layer("W1", .float), on: false),
                                 .action("Remove", .remove("W1"))])
    }

    func testTheWheelHasATwoRingWidgetsWedge() {
        XCTAssertEqual(RadialMenu.ringCount(for: .widgets), 2)
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: .widgets), "Reveal widgets")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: .widgets), "Edit widgets")
        XCTAssertEqual(Hotkeys.defaults.widgetsReveal, HotKey(key: "w", modifiers: ["control", "option"]))
        XCTAssertNil(Hotkeys(loadoutMenu: nil, dock: nil, widgets: HotKey(key: "", modifiers: [])).widgetsReveal)
    }

    // MARK: Loadouts

    func testHUDLoadoutsCaptureAndReplaceTheWidgetSet() throws {
        let hud = HUDLoadoutEngine(externals: externals, dockPosition: { nil }, setDockPosition: { _ in })
        var captured: HUDLoadout?
        hud.capture { captured = $0 }
        XCTAssertNil(captured?.widgets, "no widget layer")
        hud.widgets = layer
        hud.capture { captured = $0 }
        XCTAssertNil(captured?.widgets, "none placed: the loadout leaves the widgets alone")
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, x: 0.25, y: 0)]
        hud.capture { captured = $0 }
        XCTAssertEqual(captured?.widgets, stored.instances)
        let data = try JSONEncoder().encode(try XCTUnwrap(captured))
        XCTAssertEqual(try JSONDecoder().decode(HUDLoadout.self, from: data).widgets, stored.instances)

        var report: HUDLoadoutEngine.Report?
        hud.apply(HUDLoadout(widgets: [])) { report = $0 }
        XCTAssertEqual(report?.widgets, 0)
        XCTAssertTrue(stored.instances.isEmpty)
        stored.instances = [WidgetRecord(instance: "B", app: appID, type: "clock", size: .small, x: 0, y: 0)]
        hud.apply(HUDLoadout(dock: nil, apps: [:])) { report = $0 }
        XCTAssertNil(report?.widgets)
        XCTAssertEqual(stored.instances.map(\.instance), ["B"], "no widgets key: left alone")
    }

    func testReplaceKeepsIdsOfWidgetsThatStayAndSyncsTheDifference() {
        startApp()
        _ = call(["action": "add", "type": "clock"])          // W1 0,0
        _ = call(["action": "add", "type": "weather"])        // W2 0,1
        connector.requests = []
        let set = [WidgetRecord(instance: "L1", app: appID, type: "clock", size: .small, x: 0, y: 0),
                   WidgetRecord(instance: "L2", app: appID, type: "clock", size: .small, x: 0.5, y: 0.5, settings: ["zone": .string("UTC")])]
        layer.replace(with: set)
        XCTAssertEqual(stored.instances.map(\.instance), ["W1", "L2"])
        XCTAssertEqual(widgetRequests.map { "\($0["action"]!) \($0["instance"]!)" }, ["remove W2", "create L2"])
    }
}
