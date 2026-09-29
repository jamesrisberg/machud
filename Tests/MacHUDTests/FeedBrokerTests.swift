import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class FeedBrokerTests: XCTestCase {
    private let plainID = "xyz.plain"
    private let plainSock = "/tmp/plain-feed-test.sock"
    private let stashID = "xyz.machud.stash"
    private let stashSock = "/tmp/stash-feed-test.sock"
    private let otherID = "xyz.machud.other"
    private let otherSock = "/tmp/other-feed-test.sock"
    private var dir: URL!
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var externals: ExternalPanels!
    private var broker: FeedBroker!

    private var plain: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: plainID, name: "Plain", socket: plainSock,
                                          panels: [HUDManifest.Panel(id: "main", title: "Plain")]),
                    bundleURL: dir.appendingPathComponent("Plain.app"))
    }
    private var stash: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: stashID, name: "Stash", socket: stashSock, panels: [
            HUDManifest.Panel(id: "history", title: "History", capabilities: [FeedBroker.capability],
                              verbs: ["show", "hide", "frame"])]),
                    bundleURL: dir.appendingPathComponent("Stash.app"))
    }
    private var other: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: otherID, name: "Other", socket: otherSock, panels: [
            HUDManifest.Panel(id: "main", title: "Other", capabilities: [FeedBroker.capability],
                              verbs: ["show", "hide", "frame"])]),
                    bundleURL: dir.appendingPathComponent("Other.app"))
    }

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("feed")
        workspace = FakeWorkspace()
        workspace.installed = [plainID, stashID, otherID]
        connector = FakeConnector()
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned clock] in clock!.now }
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        broker = FeedBroker(externals: externals)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testOnlyPanelsDeclaringTheCapabilityAreProviders() {
        externals.install([plain, stash], autoLaunch: [])
        XCTAssertEqual(broker.providers.map(\.id), [stashID])
    }

    func testAddDeliversNothingAndNeverTouchesTheSocketWhenNoProviderRuns() {
        externals.install([plain, stash], autoLaunch: [])
        var reply: [String: Any]?
        broker.add(text: "hello", source: "Dictation", title: nil, date: nil) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["delivered"] as? [String], [])
        XCTAssertTrue(connector.requests.isEmpty, "never touches the socket when no provider is up")
        XCTAssertTrue(workspace.launches.isEmpty, "never launches a provider to feed it")
    }

    func testAddNeverLaunchesAStoppedProvider() {
        externals.install([stash], autoLaunch: [])
        var reply: [String: Any]?
        broker.add(text: "hello", source: "Dictation", title: nil, date: nil) { reply = $0 }
        XCTAssertEqual(reply?["delivered"] as? [String], [])
        XCTAssertTrue(workspace.launches.isEmpty)
    }

    func testAddForwardsToARunningProviderAndReportsItDelivered() {
        workspace.running[stashID] = [4242]
        connector.reachable.insert(stashSock)
        connector.replies["feed"] = ["ok": true, "id": "abc"]
        externals.install([plain, stash], autoLaunch: [])
        var reply: [String: Any]?
        broker.add(text: "hello", source: "Dictation", title: "Note", date: nil) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["delivered"] as? [String], [stashID])
        let sent = connector.requests.last { $0.command == "feed" }
        XCTAssertEqual(sent?.args, ["action": "add", "text": "hello", "source": "Dictation", "title": "Note"])
    }

    func testAddFansOutToEveryRunningProviderAndSkipsStoppedOnes() {
        workspace.running[stashID] = [4242]
        connector.reachable.insert(stashSock)
        connector.replies["feed"] = ["ok": true, "id": "abc"]
        // `other` is discovered but not running: no socket touch for it.
        externals.install([stash, other], autoLaunch: [])
        var reply: [String: Any]?
        broker.add(text: "hello", source: "Dictation", title: nil, date: nil) { reply = $0 }
        XCTAssertEqual(reply?["delivered"] as? [String], [stashID])
        XCTAssertFalse(connector.requests.contains { $0.path == otherSock })
    }

    func testAddOmitsAProviderThatRefusesTheItem() {
        workspace.running[stashID] = [4242]
        connector.reachable.insert(stashSock)
        connector.replies["feed"] = ["ok": false, "error": "history is full"]
        externals.install([stash], autoLaunch: [])
        var reply: [String: Any]?
        broker.add(text: "hello", source: "Dictation", title: nil, date: nil) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, true, "the broker call itself still succeeds")
        XCTAssertEqual(reply?["delivered"] as? [String], [])
    }

    func testControlVerbOverARealSocket() throws {
        workspace.running[stashID] = [4242]
        connector.reachable.insert(stashSock)
        connector.replies["feed"] = ["ok": true, "id": "abc"]
        externals.install([stash], autoLaunch: [])
        let path = dir.appendingPathComponent("c.sock").path
        let server = HUDSocketServer(path: path, label: "machud.test.feed")
        broker.registerControl(server)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        func call(_ args: [String: String]) -> [String: Any] {
            var reply: [String: Any]?
            DispatchQueue.global().async {
                let r = (try? HUDSocketClient(path: path, timeout: 5).request("feed", args: args)) ?? ["client": "failed"]
                DispatchQueue.main.async { reply = r }
            }
            XCTAssertTrue(spin(until: { reply != nil }))
            return reply ?? [:]
        }
        let added = call(["_": "add", "add": "1", "text": "hi there", "source": "Dictation"])
        XCTAssertEqual(added["ok"] as? Bool, true)
        XCTAssertEqual(added["delivered"] as? [String], [stashID])

        XCTAssertEqual(call(["_": "add", "add": "1", "source": "Dictation"])["error"] as? String, "feed add needs text=")
        XCTAssertEqual(call(["_": "add", "add": "1", "text": "hi"])["error"] as? String, "feed add needs source=")
    }
}
