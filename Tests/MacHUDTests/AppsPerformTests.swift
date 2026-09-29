import XCTest
import HUDKit
@testable import MacHUDCore

/// `apps` reports each app's manifest (verbs, capabilities) and `apps perform` forwards one of an
/// app's own actions to it, which is how the MCP tool server (`machud-mcp`) reaches app actions.
@MainActor
final class AppsPerformTests: XCTestCase {
    private let padID = "xyz.pad"
    private let padSock = "/tmp/pad-perform-test.sock"
    private var dir: URL!
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var externals: ExternalPanels!
    private var server: HUDSocketServer!
    private var path: String!

    private var pad: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: padID, name: "Pad", socket: padSock, panels: [
            HUDManifest.Panel(id: "pad", title: "Pad", capabilities: ["acceptsFileDrop"],
                              verbs: ["show", "hide", "frame", "append", "clear"], kind: .hover)]),
                    bundleURL: dir.appendingPathComponent("Pad.app"))
    }

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("perform")
        workspace = FakeWorkspace()
        workspace.installed = [padID]
        workspace.running[padID] = [4242]
        connector = FakeConnector()
        connector.reachable.insert(padSock)
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: { _, _ in })
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        externals.install([pad], autoLaunch: [])
        path = dir.appendingPathComponent("c.sock").path
        server = HUDSocketServer(path: path, label: "machud.test.perform")
        externals.registerControl(server)
        XCTAssertTrue(server.start())
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func call(_ args: [String: String]) -> [String: Any] {
        var reply: [String: Any]?
        let path = path!
        DispatchQueue.global().async {
            let r = (try? HUDSocketClient(path: path, timeout: 5).request("apps", args: args)) ?? ["client": "failed"]
            DispatchQueue.main.async { reply = r }
        }
        XCTAssertTrue(spin(until: { reply != nil }))
        return reply ?? [:]
    }

    func testListCarriesEachAppsManifest() throws {
        let apps = try XCTUnwrap(call([:])["apps"] as? [[String: Any]])
        let manifest = try XCTUnwrap(apps.first?["manifest"] as? [String: Any])
        XCTAssertEqual(manifest["id"] as? String, padID)
        let panel = try XCTUnwrap((manifest["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(panel["verbs"] as? [String], ["show", "hide", "frame", "append", "clear"])
        XCTAssertEqual(panel["capabilities"] as? [String], ["acceptsFileDrop"])
        XCTAssertEqual(panel["kind"] as? String, "hover")
        XCTAssertEqual(apps.first?["panels"] as? [String], ["\(padID)/pad"], "panel ids stay as they were")
    }

    func testPerformForwardsTheVerbAndItsArguments() {
        connector.replies["action"] = ["ok": true, "count": 3]
        let reply = call(["action": "perform", "app": "Pad", "verb": "append", "text": "hi", "id": "note-1"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["app"] as? String, padID)
        XCTAssertEqual(reply["count"] as? Int, 3)
        let sent = connector.requests.last { $0.command == "action" }
        XCTAssertEqual(sent?.path, padSock)
        XCTAssertEqual(sent?.args, ["name": "append", "text": "hi", "id": "note-1"])
    }

    func testPerformFromTheCLIForm() {
        _ = call(["_": "perform", "perform": "1", "app": padID, "verb": "clear"])
        XCTAssertEqual(connector.requests.last { $0.command == "action" }?.args, ["name": "clear"])
    }

    func testPerformPassesTheAppsOwnFailureThrough() {
        connector.replies["action"] = ["ok": false, "error": "unknown action zap"]
        let reply = call(["action": "perform", "app": padID, "verb": "zap"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "unknown action zap")
        XCTAssertEqual(reply["app"] as? String, padID)
    }

    func testPerformNeedsAKnownAppAndAVerb() {
        XCTAssertEqual(call(["action": "perform", "app": "Nope", "verb": "x"])["error"] as? String,
                       "app=<bundle id or name> of a discovered app required")
        XCTAssertEqual(call(["action": "perform", "app": padID])["error"] as? String,
                       "apps perform needs verb=<action verb>")
        XCTAssertFalse(connector.requests.contains { $0.command == "action" })
    }
}
