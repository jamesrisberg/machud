import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class SessionsBrokerTests: XCTestCase {
    private let plainID = "xyz.plain"
    private let plainSock = "/tmp/plain-test.sock"
    private let dashID = "xyz.mechahud"
    private let dashSock = "/tmp/mechahud-test.sock"
    private var dir: URL!
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var externals: ExternalPanels!
    private var broker: SessionsBroker!

    private var plain: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: plainID, name: "Plain", socket: plainSock,
                                          panels: [HUDManifest.Panel(id: "main", title: "Plain")]),
                    bundleURL: dir.appendingPathComponent("Plain.app"))
    }
    private var dashboard: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: dashID, name: "MechaHUD", socket: dashSock, panels: [
            HUDManifest.Panel(id: "dashboard", title: "Dashboard", capabilities: [SessionsBroker.capability],
                              verbs: ["show", "hide", "frame"])]),
                    bundleURL: dir.appendingPathComponent("MechaHUD.app"))
    }

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("sessions")
        workspace = FakeWorkspace()
        workspace.installed = [plainID, dashID]
        connector = FakeConnector()
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned clock] in clock!.now }
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        broker = SessionsBroker(externals: externals)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testOnlyPanelsDeclaringTheCapabilityAreProviders() {
        externals.install([plain, dashboard], autoLaunch: [])
        XCTAssertEqual(broker.providers.map(\.id), [dashID])
    }

    func testProvidersJSONReportsSocketAndRunning() {
        workspace.running[dashID] = [4242]
        connector.reachable.insert(dashSock)
        externals.install([plain, dashboard], autoLaunch: [])
        let providers = broker.providersJSON
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0]["app"] as? String, dashID)
        XCTAssertEqual(providers[0]["socket"] as? String, dashSock)
        XCTAssertEqual(providers[0]["running"] as? Bool, true)
    }

    func testProvidersJSONNotRunningWhenNoProcessIsUp() {
        externals.install([plain, dashboard], autoLaunch: [])
        XCTAssertEqual(broker.providersJSON[0]["running"] as? Bool, false)
    }

    func testOpenFailsCleanlyWhenNoAppDeclaresTheCapability() {
        externals.install([plain], autoLaunch: [])
        var reply: [String: Any]?
        broker.open(id: "claude:1") { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, "No app shows agent sessions")
        XCTAssertTrue(connector.requests.isEmpty, "never touches the socket when there is no provider")
    }

    func testOpenForwardsToARunningProvider() {
        workspace.running[dashID] = [4242]
        connector.reachable.insert(dashSock)
        connector.replies["action"] = ["ok": true]
        externals.install([plain, dashboard], autoLaunch: [])
        var reply: [String: Any]?
        broker.open(id: "claude:abc") { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["app"] as? String, dashID)
        let sent = connector.requests.last { $0.command == "action" }
        XCTAssertEqual(sent?.args, ["name": "open-session", "id": "claude:abc"])
    }

    func testOpenLaunchesTheOnlyProviderWhenNoneRuns() {
        connector.reachable.insert(dashSock)
        connector.replies["action"] = ["ok": true]
        externals.install([dashboard], autoLaunch: [])
        var reply: [String: Any]?
        broker.open(id: "claude:xyz") { reply = $0 }
        XCTAssertEqual(workspace.launches, [dashID], "launched the discovered provider on demand")
        XCTAssertNil(reply, "queued until the app comes up")
        workspace.start(dashID)
        clock.runQueued()                                    // the post-launch connect
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["app"] as? String, dashID)
    }

    func testOpenPassesThroughTheProvidersOwnFailure() {
        workspace.running[dashID] = [4242]
        connector.reachable.insert(dashSock)
        connector.replies["action"] = ["ok": false, "error": "no such session"]
        externals.install([dashboard], autoLaunch: [])
        var reply: [String: Any]?
        broker.open(id: "claude:missing") { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, "no such session")
    }

    func testOpenReportsATransportFailure() {
        workspace.installed = []
        externals.install([dashboard], autoLaunch: [])
        var reply: [String: Any]?
        broker.open(id: "claude:1") { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, "\(dashID) is not installed")
    }

    func testControlVerbOverARealSocket() throws {
        connector.replies["action"] = ["ok": true]
        externals.install([dashboard], autoLaunch: [])
        let path = dir.appendingPathComponent("c.sock").path
        let server = HUDSocketServer(path: path, label: "machud.test.sessions")
        broker.registerControl(server)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        func call(_ args: [String: String]) -> [String: Any] {
            var reply: [String: Any]?
            DispatchQueue.global().async {
                let r = (try? HUDSocketClient(path: path, timeout: 5).request("sessions", args: args)) ?? ["client": "failed"]
                DispatchQueue.main.async { reply = r }
            }
            XCTAssertTrue(spin(until: { reply != nil }))
            return reply ?? [:]
        }
        let providers = call(["_": "providers", "providers": "1"])
        XCTAssertEqual(providers["ok"] as? Bool, true)
        XCTAssertEqual((providers["providers"] as? [[String: Any]])?.first?["app"] as? String, dashID)

        workspace.running[dashID] = [4242]
        connector.reachable.insert(dashSock)
        let opened = call(["_": "open", "open": "1", "id": "claude:1"])
        XCTAssertEqual(opened["ok"] as? Bool, true)
        XCTAssertEqual(opened["app"] as? String, dashID)

        XCTAssertEqual(call(["_": "open", "open": "1"])["error"] as? String, "sessions open needs id=<session key>")
    }
}
