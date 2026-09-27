import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

/// The sibling side: a real HUDSocketServer + HUDControlRouter over a fake host.
@MainActor
final class SiblingHost: HUDPanelHost {
    var visible = false
    var frames: [CGRect] = []
    var modes: [HUDPanelMode] = []
    var modeOptions: [HUDPanelModeOptions] = []
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "portal", visible: visible)] }
    var panelDescriptors: [HUDManifest.Panel] { [HUDManifest.Panel(id: "portal", title: "Portal")] }
    func showPanel(_ id: String) throws { visible = true }
    func hidePanel(_ id: String) throws { visible = false }
    func setPanelFrame(_ id: String, frame: CGRect) throws { frames.append(frame) }
    func setPanelMode(_ id: String, mode: HUDPanelMode) throws { modes.append(mode) }
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        modeOptions.append(options)
        try setPanelMode(id, mode: mode)
    }
    var settingsSchema: HUDSettingsSchema? { nil }
    func quit() {}
}

@MainActor
final class ExternalPanelSocketTests: XCTestCase {
    private var dir: URL!
    private var server: HUDSocketServer!
    private var router: HUDControlRouter!
    private var host: SiblingHost!
    private var workspace: FakeWorkspace!
    private var supervisor: AppSupervisor!
    private var registry: PanelRegistry!
    private let appID = "dev.test.sibling"

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("ext")
        let path = dir.appendingPathComponent("s.sock").path
        host = SiblingHost()
        server = HUDSocketServer(path: path, label: "machud.test.sibling")
        let manifest = HUDManifest(id: appID, name: "Sibling", socket: path,
                                   panels: [HUDManifest.Panel(id: "portal", title: "Portal", verbs: ["show", "hide", "toggle", "frame"])])
        router = HUDControlRouter(host: host, server: server, manifest: manifest)
        router.install()
        XCTAssertTrue(server.start())

        workspace = FakeWorkspace()
        workspace.installed = [appID]
        workspace.running[appID] = [getpid()]
        supervisor = AppSupervisor(workspace: workspace)       // real socket connector
        registry = PanelRegistry()
        let externals = ExternalPanels(registry: registry, supervisor: supervisor) { AppsConfig() }
        externals.install([ExternalApp(manifest: manifest, bundleURL: dir)], autoLaunch: [])
        XCTAssertTrue(spin { self.supervisor.record(self.appID)?.health == .running }, "subscribes to the sibling")
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private var panel: ExternalPanel { registry.panel(id: "portal") as! ExternalPanel }

    func testShowHideReachSiblingAndPushedStateComesBack() {
        var published = 0
        registry.onStateChange = { published += 1 }
        panel.show()
        XCTAssertTrue(spin { self.host.visible })
        XCTAssertTrue(panel.isVisible)

        // The sibling changes on its own (its hotkey) and pushes state.
        host.visible = false
        router.publishState()
        XCTAssertTrue(spin { !self.panel.isVisible })
        XCTAssertGreaterThan(published, 0, "MacHUD republishes sibling changes")

        registry.toggle("\(appID)/portal")
        XCTAssertTrue(spin { self.host.visible })
    }

    func testCooperativePlacementSendsFrame() {
        XCTAssertTrue(panel.isCooperative)
        XCTAssertTrue(panel.place(in: CGRect(x: 10, y: 20, width: 300, height: 200)))
        XCTAssertTrue(spin { !self.host.frames.isEmpty })
        XCTAssertEqual(host.frames.first, CGRect(x: 10, y: 20, width: 300, height: 200))
        panel.setMode(.compact)
        XCTAssertTrue(spin { self.host.modes == [.compact] })
    }

    func testUmbrellaHostForwardsContractVerbs() throws {
        let umbrella = MacHUDPanelHost(registry: registry)
        XCTAssertEqual(umbrella.panelDescriptors.map(\.id), ["\(appID)/portal"])
        try umbrella.setPanelFrame("\(appID)/portal", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertTrue(spin { self.host.frames.contains(CGRect(x: 1, y: 2, width: 3, height: 4)) })
        XCTAssertTrue(spin { self.host.visible }, "frame shows the panel too")
        XCTAssertEqual(umbrella.panelStates.first?.id, "\(appID)/portal")
    }

    func testLoadoutPanelOccupantIsPlacedOverTheSocket() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no display") }
        let json = """
        {"gap": 0, "layouts": [{"name": "One", "regions": [{"id": "left", "x": 0, "y": 0, "w": 0.5, "h": 1}]}],
         "loadouts": [{"name": "Sib", "layout": "One", "slots": [{"regionID": "left", "occupant": {"kind": "panel", "id": "portal"}}]}]}
        """
        guard try TestConfig.write(json) else {
            throw XCTSkip("LayoutStore.configURL was already fixed to \(LayoutStore.configURL.path)")
        }
        let store = LayoutStore()
        let engine = LoadoutEngine(store: store, panels: registry)
        let loadout = try XCTUnwrap(store.loadout(named: "Sib"))
        var report: LoadoutEngine.ApplyReport?
        engine.apply(loadout, clear: false, screen: screen) { report = $0 }
        XCTAssertTrue(spin { report != nil }, "apply finishes")
        XCTAssertEqual(report?.placed, ["left"], "failed: \(report?.failed ?? [:])")
        let expected = engine.regionRect(store.layout(named: "One")!.regions[0], on: screen)
        XCTAssertTrue(spin { self.host.frames.contains(expected) })
        XCTAssertTrue(host.visible)
    }

    func testParkedPanelParksOverTheSocketAndTheOrbRevealsIt() throws {
        let parking = ParkingController(panels: registry, stateURL: dir.appendingPathComponent("parking.json"))
        XCTAssertNil(parking.cooperativeTarget("portal"), "no resolver yet")
        LoadoutEngine.wireCooperativeParking(parking, panels: registry)
        XCTAssertNil(parking.cooperativeTarget("dock"), "not an external panel")
        let target = try XCTUnwrap(parking.cooperativeTarget("portal"))
        guard case .cooperative(let client, let panelID) = target else { return XCTFail("not cooperative") }
        XCTAssertEqual(client.path, dir.appendingPathComponent("s.sock").path)
        XCTAssertEqual(panelID, "portal")

        let rest = CGRect(x: 100, y: 100, width: 300, height: 200)
        parking.park(target, id: "left", label: "Portal", rest: rest, edge: .right, peek: 6, screen: NSScreen.main)
        XCTAssertTrue(spin { self.host.modes == [.parked] })
        XCTAssertEqual(host.frames.last, rest, "the app learns its rest frame before parking")
        XCTAssertEqual(host.modeOptions.last, HUDPanelModeOptions(edge: .right, peek: 6))
        XCTAssertEqual(parking.parked.first?.record.kind, .cooperative)

        // Hovering the orb (as `park reveal` does) asks for full; leaving parks again.
        XCTAssertEqual(parking.reveal(edge: .right, pin: true), 1)
        XCTAssertTrue(spin { self.host.modes == [.parked, .full] })
        XCTAssertEqual(parking.conceal(edge: .right), 1)
        XCTAssertTrue(spin { self.host.modes == [.parked, .full, .parked] })
        XCTAssertEqual(parking.unpark(id: "left"), 1)
        XCTAssertTrue(spin { self.host.modes.last == .full })
        XCTAssertTrue(parking.parked.isEmpty)
    }

    func testStoppedAppIsNotACooperativeParkingTarget() {
        workspace.running[appID] = nil
        supervisor.refresh(appID)
        XCTAssertNil(registry.cooperativeParkingTarget("portal"), "placed (and launched) first, parked after")
    }
}
