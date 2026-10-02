import XCTest
import HUDKit
@testable import MacHUDCore

final class WidgetGridTests: XCTestCase {
    // 1440 × 875 visible, 170 cells, 16 gap, 24 margin: 7 columns × 4 rows.
    let grid = WidgetGrid(visible: CGRect(x: 0, y: 0, width: 1440, height: 875), cell: 170, gap: 16, margin: 24)
    typealias Cell = WidgetGrid.Cell

    func testGeometry() {
        XCTAssertEqual(grid.columns, 7)
        XCTAssertEqual(grid.rows, 4)
        XCTAssertEqual(grid.frame(Cell(col: 0, row: 0), .small), CGRect(x: 24, y: 681, width: 170, height: 170), "top-left")
        XCTAssertEqual(grid.frame(Cell(col: 1, row: 1), .large), CGRect(x: 210, y: 309, width: 356, height: 356))
        XCTAssertTrue(grid.fits(Cell(col: 3, row: 2), .extraLarge))
        XCTAssertFalse(grid.fits(Cell(col: 4, row: 2), .extraLarge))
        XCTAssertEqual(grid.cells(Cell(col: 2, row: 1), .medium), [Cell(col: 2, row: 1), Cell(col: 3, row: 1)])
    }

    func testSnapClampsAndRounds() {
        XCTAssertEqual(grid.snap(CGRect(x: 300, y: 600, width: 170, height: 170), .small), Cell(col: 1, row: 0))
        XCTAssertEqual(grid.snap(CGRect(x: 5000, y: -900, width: 170, height: 170), .medium), Cell(col: 5, row: 3), "kept inside")
    }

    func testFreeCells() {
        let taken = grid.cells(Cell(col: 0, row: 0), .large)
        XCTAssertEqual(grid.firstFree(.small, occupied: taken), Cell(col: 0, row: 2), "down the first column first")
        XCTAssertEqual(grid.nearestFree(.small, near: Cell(col: 1, row: 1), occupied: taken), Cell(col: 1, row: 2),
                       "ties go column-major")
        let band = Set((0..<7).flatMap { [Cell(col: $0, row: 1), Cell(col: $0, row: 2)] })
        XCTAssertNil(grid.nearestFree(.extraLarge, near: Cell(col: 0, row: 0), occupied: band))
    }

    func testPlacementFallsBackAndResolvesOverlaps() {
        let main = WidgetScreen(descriptor: ScreenDescriptor(name: "Main", isMain: true, isBuiltin: true), ref: .builtin,
                                visible: CGRect(x: 0, y: 0, width: 1440, height: 875), frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let records = [
            WidgetRecord(instance: "A", app: "x", type: "clock", size: .medium, col: 0, row: 0),
            WidgetRecord(instance: "B", app: "x", type: "clock", size: .small, col: 1, row: 0),
            WidgetRecord(instance: "C", app: "x", type: "clock", size: .small, screen: .name("Gone"), col: 30, row: 9),
        ]
        let placed = WidgetPlacement.resolve(records, screens: [main], config: WidgetsConfig())
        XCTAssertEqual(placed["A"]?.cell, Cell(col: 0, row: 0))
        XCTAssertEqual(placed["B"]?.cell, Cell(col: 1, row: 1), "moved off A to the nearest free cell")
        XCTAssertEqual(placed["B"]?.moved, true)
        XCTAssertEqual(placed["C"]?.screenMissing, true)
        XCTAssertEqual(placed["C"]?.cell, Cell(col: 6, row: 3), "pulled inside the main display's grid")
    }

    func testConfigRoundTripsAndReadsLeniently() throws {
        let json = #"{"widgets": {"cell": 150, "instances": [{"instance": "A", "app": "x", "type": "clock", "size": "huge", "#
            + #""col": 2, "row": -1, "layer": "float", "screen": {"builtin": true}, "settings": {"zone": "UTC", "seconds": true}}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let w = try XCTUnwrap(config.widgets)
        XCTAssertEqual(w.cellSize, 150)
        XCTAssertEqual(w.gapSize, 16)
        XCTAssertEqual(w.instances.first?.size, .small, "an unknown size reads as small")
        XCTAssertEqual(w.instances.first?.row, 0)
        XCTAssertEqual(w.instances.first?.layer, .float)
        XCTAssertEqual(w.instances.first?.screen, .builtin)
        XCTAssertEqual(w.instances.first?.settings, ["zone": .string("UTC"), "seconds": .bool(true)])
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.widgets, w)
    }
}

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
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, col: 0, row: 0,
                                         settings: ["zone": .string("UTC")]),
                            WidgetRecord(instance: "B", app: appID, type: "radar", size: .small, col: 1, row: 0)]
        startApp()
        let sync = widgetRequests.first
        XCTAssertEqual(sync?["action"], "sync")
        XCTAssertEqual(sync?["editing"], "off")
        XCTAssertEqual(sync?["revealed"], "off")
        let list = try syncedInstances(sync)
        XCTAssertEqual(list.count, 1, "a type the app does not serve is kept but not sent")
        XCTAssertEqual(list.first?["instance"] as? String, "A")
        XCTAssertEqual(list.first?["frame"] as? [Double], [24, 681, 170, 170])
        XCTAssertEqual((list.first?["settings"] as? [String: Any])?["zone"] as? String, "UTC")
        XCTAssertNil(connector.requests.first { $0.path == otherSock && $0.command == "widget" }, "no widgets, no sync")
        startApp(otherID)
        XCTAssertNil(connector.requests.first { $0.path == otherSock && $0.command == "widget" })

        let rows = layer.listJSON()
        XCTAssertEqual(rows.first { $0["instance"] as? String == "B" }?["missingType"] as? Bool, true)
        XCTAssertEqual(rows.first { $0["instance"] as? String == "A" }?["health"] as? String, "running")
    }

    func testRejectedAndDroppedAreMarkedAndToastedOnce() {
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, col: 0, row: 0),
                            WidgetRecord(instance: "B", app: appID, type: "weather", size: .small, col: 1, row: 0,
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
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, col: 0, row: 0)]
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
        stored.instances = [WidgetRecord(instance: "B", app: appID, type: "clock", size: .small, col: 0, row: 0)]
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
        XCTAssertEqual(instance["frame"] as? [Double], [24, 495, 170, 170], "below the medium one")
        let create = try XCTUnwrap(widgetRequests.last)
        XCTAssertEqual(create["action"], "create")
        XCTAssertEqual(create["frame"], "24,495,170,170")
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
        XCTAssertEqual(list.first?["frame"] as? [Double], [396, 495, 170, 170])
        XCTAssertEqual(widgetRequests.count, 1, "nothing sent twice")
    }

    func testMoveResizeLayerAndSettingsSendUpdates() throws {
        startApp()
        _ = call(["action": "add", "type": "clock"])                       // W1 at 0,0
        _ = call(["action": "add", "type": "weather", "col": "0", "row": "0"])   // taken: W2 at 0,1
        XCTAssertEqual(stored.instances.last?.cell, WidgetGrid.Cell(col: 0, row: 1))
        connector.requests = []

        var reply = call(["action": "move", "instance": "W2", "col": "2", "row": "0"])
        XCTAssertNil(reply["note"])
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "396,681,170,170"])
        reply = call(["action": "move", "instance": "W2", "col": "0", "row": "0"])
        XCTAssertEqual(reply["note"] as? String, "0,0 is taken; placed at 0,1 on Main")
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "24,495,170,170"])

        reply = call(["action": "move", "instance": "W2", "col": "0", "row": "0", "screen": "Side"])
        XCTAssertEqual(stored.instances.last?.screen, .display(id: "1-2-3", name: "Side"))
        XCTAssertEqual(widgetRequests.last?["frame"], "1464,861,170,170")

        reply = call(["action": "resize", "instance": "W2", "size": "large"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "size": "large", "frame": "1464,675,356,356"])

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

    func testDraggedWidgetSnapsToTheNearestFreeCells() {
        startApp()
        _ = call(["action": "add", "type": "clock"])           // W1 0,0
        _ = call(["action": "add", "type": "clock"])           // W2 0,1
        connector.requests = []
        event(["instance": "W2", "change": "frame", "frame": [30, 690, 170, 170]])   // dropped onto W1
        XCTAssertEqual(stored.instances[1].cell, WidgetGrid.Cell(col: 0, row: 1), "the nearest free cells: back where it was")
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "24,495,170,170"])
        event(["instance": "W2", "change": "frame", "frame": [220, 700, 170, 170]])
        XCTAssertEqual(stored.instances[1].cell, WidgetGrid.Cell(col: 1, row: 0))
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W2", "frame": "210,681,170,170"])
        event(["instance": "W2", "change": "frame", "frame": [1500, 800, 170, 170]])   // onto the side display
        XCTAssertEqual(stored.instances[1].screen, .display(id: "1-2-3", name: "Side"))
        XCTAssertEqual(widgetRequests.last?["frame"], "1464,861,170,170")
    }

    func testSizeRemoveSettingsConfigureAndOpenEvents() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        connector.requests = []
        event(["instance": "W1", "change": "size", "size": "medium"])
        XCTAssertEqual(stored.instances[0].size, .medium)
        XCTAssertEqual(widgetRequests.last, ["action": "update", "instance": "W1", "size": "medium", "frame": "24,681,356,170"])
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
        stored.instances[0].col = 3
        stored.instances.append(WidgetRecord(instance: "X", app: appID, type: "weather", size: .small, col: 0, row: 0))
        layer.configChanged()
        let actions = widgetRequests.map { "\($0["action"]!) \($0["instance"]!)" }
        XCTAssertEqual(actions, ["update W1", "create X"])
        XCTAssertEqual(widgetRequests.first?["frame"], "582,681,170,170")
        connector.requests = []
        layer.configChanged()
        XCTAssertTrue(widgetRequests.isEmpty, "nothing changed: nothing sent")
    }

    func testFramesForShowVerification() {
        startApp()
        _ = call(["action": "add", "type": "clock"])
        XCTAssertEqual(layer.frames(app: appID), [CGRect(x: 24, y: 681, width: 170, height: 170)])
        XCTAssertEqual(layer.frames(app: otherID), [])
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
        XCTAssertNil(captured?.widgets, "no widgets placed: the loadout leaves them alone")
        stored.instances = [WidgetRecord(instance: "A", app: appID, type: "clock", size: .small, col: 2, row: 0)]
        hud.widgets = layer
        hud.capture { captured = $0 }
        XCTAssertEqual(captured?.widgets, stored.instances)
        let data = try JSONEncoder().encode(try XCTUnwrap(captured))
        XCTAssertEqual(try JSONDecoder().decode(HUDLoadout.self, from: data).widgets, stored.instances)

        var report: HUDLoadoutEngine.Report?
        hud.apply(HUDLoadout(widgets: [])) { report = $0 }
        XCTAssertEqual(report?.widgets, 0)
        XCTAssertTrue(stored.instances.isEmpty)
        stored.instances = [WidgetRecord(instance: "B", app: appID, type: "clock", size: .small, col: 0, row: 0)]
        hud.apply(HUDLoadout(dock: nil, apps: [:])) { report = $0 }
        XCTAssertNil(report?.widgets)
        XCTAssertEqual(stored.instances.map(\.instance), ["B"], "no widgets key: left alone")
    }

    func testReplaceKeepsIdsOfWidgetsThatStayAndSyncsTheDifference() {
        startApp()
        _ = call(["action": "add", "type": "clock"])          // W1 0,0
        _ = call(["action": "add", "type": "weather"])        // W2 0,1
        connector.requests = []
        let set = [WidgetRecord(instance: "L1", app: appID, type: "clock", size: .small, col: 0, row: 0),
                   WidgetRecord(instance: "L2", app: appID, type: "clock", size: .small, col: 4, row: 2, settings: ["zone": .string("UTC")])]
        layer.replace(with: set)
        XCTAssertEqual(stored.instances.map(\.instance), ["W1", "L2"])
        XCTAssertEqual(widgetRequests.map { "\($0["action"]!) \($0["instance"]!)" }, ["remove W2", "create L2"])
    }
}
