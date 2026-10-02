import XCTest
import HUDKit
@testable import MacHUDCore

/// Widget panels (and kinds MacHUD does not know) are never dock panels: an app that only
/// serves widgets is an ordinary app in Apps and the menus, without a dock button.
@MainActor
final class WidgetGateTests: XCTestCase {
    private let widgetsID = "xyz.widgets", widgetsSock = "/tmp/gs-gate-widgets.sock"
    private let mixedID = "xyz.mixed", mixedSock = "/tmp/gs-gate-mixed.sock"
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var externals: ExternalPanels!

    /// Widgets only: a clock and a weather widget.
    private var widgetOnly: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: widgetsID, name: "Widgets", socket: widgetsSock, panels: [
            HUDManifest.Panel(id: "clock", title: "Clock", symbol: "clock", kind: .widget),
            HUDManifest.Panel(id: "weather", title: "Weather", symbol: "cloud.sun", kind: .widget),
        ]), bundleURL: URL(fileURLWithPath: "/tmp/Widgets.app"))
    }

    /// A widget first, an unknown kind, then the one dock panel.
    private var mixed: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: mixedID, name: "Mixed", socket: mixedSock, panels: [
            HUDManifest.Panel(id: "servers", title: "Servers", symbol: "server.rack", kind: .widget),
            HUDManifest.Panel(id: "orb", title: "Orb", kind: .unknown("orb")),
            HUDManifest.Panel(id: "list", title: "List", symbol: "list.bullet", verbs: ["show", "hide", "frame"], kind: .hover),
        ]), bundleURL: URL(fileURLWithPath: "/tmp/Mixed.app"))
    }

    override func setUp() {
        workspace = FakeWorkspace()
        workspace.installed = [widgetsID, mixedID]
        connector = FakeConnector()
        connector.reachable = [widgetsSock, mixedSock]
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned self] in self.clock.now }
        supervisor.windowProbe = { _, _ in .onScreen }
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        externals.install([widgetOnly, mixed], autoLaunch: [])
    }

    func testAWidgetOnlyAppHasNoDockButtonAndDoesNotCrashTheDock() {
        let items = ToolDockModel.items(apps: [widgetOnly, mixed], hasParked: false)
        XCTAssertEqual(items.map(\.id), [mixedID], "the widget-only app has no button")
        XCTAssertEqual(items.first?.panelIDs, ["\(mixedID)/list"], "only the dock panel")
        XCTAssertEqual(items.first?.behaviour, .hover)
        XCTAssertEqual(items.first?.symbol, "list.bullet")
    }

    func testWidgetAndUnknownKindsAreNeverRegisteredAsPanels() {
        let ids = externals.registry.panels.map(\.id)
        XCTAssertEqual(ids, ["\(mixedID)/list"])
        let row = externals.json.first { $0["id"] as? String == mixedID }
        XCTAssertEqual(row?["panels"] as? [String], ["\(mixedID)/list"])
        XCTAssertEqual(row?["widgets"] as? [String], ["servers"])
    }

    func testSummonByAppPicksTheFirstDockPanel() {
        let dock = ToolDock(registry: externals.registry, externals: externals, config: { ToolDockConfig() },
                            saveConfig: { _ in }, stateURL: FakeBundles.tempDir("gate").appendingPathComponent("t.json"), ui: false)
        XCTAssertEqual(dock.panel(matching: mixedID)?.id, "\(mixedID)/list")
        XCTAssertNil(dock.panel(matching: widgetsID))
    }

    func testAWidgetOnlyAppIsAnOrdinaryAppInTheMenu() throws {
        let entries = MacHUDMenuModel.entries(externals: externals) { _ in .full }
        let widgets = try XCTUnwrap(entries.first { $0.appID == widgetsID })
        XCTAssertEqual(widgets.actions.map(\.kind), [.separator, .settings, .separator, .launch],
                       "no Show, no Show on Tool Dock")
        XCTAssertEqual(widgets.symbol, "clock", "the first widget's symbol stands in")
        let mixedEntry = try XCTUnwrap(entries.first { $0.appID == mixedID })
        XCTAssertEqual(mixedEntry.actions.filter { $0.kind == .summon }.map(\.panelID), ["\(mixedID)/list"])
        XCTAssertEqual(mixedEntry.symbol, "list.bullet")
        workspace.start(widgetsID)
        clock.runQueued()
        let running = try XCTUnwrap(MacHUDMenuModel.entries(externals: externals) { _ in .full }.first { $0.appID == widgetsID })
        XCTAssertEqual(running.actions.map(\.kind), [.separator, .appMenu, .separator, .settings, .separator, .relaunch, .quit])
    }

    func testShowVerificationIgnoresWidgetWindows() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        typealias W = WindowPresence.Window
        let widget = W(frame: CGRect(x: 24, y: 700, width: 170, height: 170), onScreen: true)
        let panelAway = W(frame: CGRect(x: 100, y: 100, width: 400, height: 300), onScreen: false, spaces: 1)
        XCTAssertEqual(WindowPresence.classify([widget, panelAway], screens: screens), .onScreen, "without the hint")
        XCTAssertEqual(WindowPresence.classify([widget, panelAway], screens: screens,
                                               ignoring: [CGRect(x: 24.4, y: 700, width: 170, height: 170)]),
                       .anotherDesktop, "a widget MacHUD placed does not count as the panel")
    }

    func testTheSupervisorPassesWidgetFramesToTheProbe() {
        var seen: [CGRect] = []
        externals.supervisor.windowProbe = { _, ignoring in seen = ignoring; return .onScreen }
        externals.supervisor.widgetFrames = { $0 == self.mixedID ? [CGRect(x: 1, y: 2, width: 3, height: 4)] : [] }
        workspace.start(mixedID)
        clock.runQueued()
        let panel = externals.registry.panel(id: "\(mixedID)/list") as! ExternalPanel
        panel.show(HUDPanelTransition(reason: .summon))
        clock.runQueued()
        XCTAssertEqual(seen, [CGRect(x: 1, y: 2, width: 3, height: 4)])
    }
}
