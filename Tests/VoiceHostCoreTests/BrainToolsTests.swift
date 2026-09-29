import BrainKit
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// MacHUD's tool server and host context going to the brain, and the runtime it reports.
@MainActor
final class BrainToolsTests: XCTestCase {
    private var brain: FakeBrain!
    private var status: FakeMacHUDStatus!
    private let server = MacHUDToolServer(command: "/Apps/MacHUD.app/Contents/Helpers/machud-mcp",
                                          machudSocket: "/tmp/machud-test.sock")
    private let installed = MacHUDSnapshot(
        apps: [.init(id: "com.example.scratch", name: "Scratch", panels: ["com.example.scratch/notes"])],
        loadouts: ["Coding", "Writing"], startupLoadout: "Coding")

    override func setUp() async throws {
        brain = FakeBrain()
        status = FakeMacHUDStatus(installed)
    }

    private func makeController(_ settings: VoiceHostSettings = VoiceHostSettings(),
                                tools: MacHUDToolServer?? = nil) -> VoiceHostController {
        let controller = VoiceHostController(
            settings: settings, dictation: FakeDictation(), keys: nil, brain: brain, speaker: nil, wake: nil,
            brainStateRoot: URL(fileURLWithPath: "/tmp/voice-tests/Brain"),
            machudTools: tools ?? server, machudStatus: status,
            detectRuntimes: FakeRuntimes.detect(), schedule: { _, _ in })
        controller.hostContextSettle = .init(interval: 0.001, reads: 8)
        controller.start()
        return controller
    }

    private func settled(_ controller: VoiceHostController) async {
        await controller.hostContextLoad?.value
    }

    func testTheBrainStartsWithMacHUDsToolServerAndAHostContext() async throws {
        let controller = makeController()
        // The first start waits for MacHUD's description rather than starting twice.
        XCTAssertTrue(brain.configurations.isEmpty)
        await settled(controller)
        XCTAssertEqual(brain.configurations.count, 1)
        let launch = try XCTUnwrap(brain.configurations.last ?? nil)
        XCTAssertEqual(launch.toolServers, [BrainToolServer(
            name: "machud", command: "/Apps/MacHUD.app/Contents/Helpers/machud-mcp",
            environment: ["MACHUD_SOCKET": "/tmp/machud-test.sock"], requireApproval: false)])
        XCTAssertTrue(launch.hostContext.contains("You are the brain of MacHUD"))
        XCTAssertTrue(launch.hostContext.contains("- Scratch (`com.example.scratch`): panels notes"))
        XCTAssertTrue(launch.hostContext.contains("- Coding (applied at launch)"))
        XCTAssertTrue(launch.hostContext.contains("- Writing"))
    }

    func testRequireApprovalGoesToTheToolServer() async throws {
        var settings = VoiceHostSettings()
        settings.machudToolsRequireApproval = true
        let controller = makeController(settings)
        await settled(controller)
        XCTAssertEqual((brain.configurations.last ?? nil)?.toolServers.first?.requireApproval, true)
    }

    func testToolsOffStartsWithoutThemAtOnce() throws {
        var settings = VoiceHostSettings()
        settings.machudTools = false
        _ = makeController(settings)
        let launch = try XCTUnwrap(brain.configurations.last ?? nil)
        XCTAssertEqual(launch.toolServers, [])
        XCTAssertEqual(launch.hostContext, "")
        XCTAssertEqual(status.reads, 0)
    }

    func testNoToolServerBesideTheHostStartsWithoutTools() throws {
        _ = makeController(tools: .some(nil))
        let launch = try XCTUnwrap(brain.configurations.last ?? nil)
        XCTAssertEqual(launch.toolServers, [])
        XCTAssertEqual(launch.hostContext, "")
    }

    func testTurningToolsOnLaterAddsThem() async throws {
        var settings = VoiceHostSettings()
        settings.machudTools = false
        let controller = makeController(settings)
        settings.machudTools = true
        controller.apply(settings)
        await settled(controller)
        XCTAssertEqual((brain.configurations.last ?? nil)?.toolServers.map(\.name), ["machud"])
    }

    func testMacHUDNotAnsweringStillDescribesTheTools() async throws {
        status.current = nil
        let controller = makeController()
        await settled(controller)
        let context = try XCTUnwrap(brain.configurations.last ?? nil).hostContext
        XCTAssertTrue(context.contains("machud_status"))
        XCTAssertTrue(context.contains("MacHUD did not report its apps and loadouts"))
    }

    func testARestartRereadsMacHUDAndFollowsAChange() async throws {
        let controller = makeController()
        await settled(controller)
        XCTAssertEqual(brain.configurations.count, 1)
        // A restart with nothing changed keeps the launch.
        brain.onStopped?()
        await settled(controller)
        XCTAssertEqual(brain.configurations.count, 1)
        // A loadout was saved meanwhile: the brain is told.
        status.current = MacHUDSnapshot(apps: installed.apps, loadouts: ["Coding", "Writing", "Review"],
                                        startupLoadout: "Coding")
        brain.onStopped?()
        await settled(controller)
        XCTAssertEqual(brain.configurations.count, 2)
        XCTAssertTrue((brain.configurations.last ?? nil)?.hostContext.contains("- Review") == true)
    }

    func testARuntimeChangeReconfiguresTheBrainWithIt() async throws {
        let controller = makeController()
        await settled(controller)
        var settings = controller.settings
        settings.brain.runtime = .mclaude
        controller.apply(settings)
        XCTAssertEqual((brain.configurations.last ?? nil)?.runtime, .mclaude)
        XCTAssertEqual((brain.configurations.last ?? nil)?.toolServers.count, 1)
    }

    func testBrainStatusReportsTheRuntimeTheCompanionRuns() async throws {
        var settings = VoiceHostSettings()
        settings.brain.runtime = .mclaude
        let controller = makeController(settings)
        await settled(controller)
        let commands = VoiceHostCommands(controller: controller,
                                         store: VoiceHostSettingsStore(directory: URL(fileURLWithPath: "/tmp/unused")),
                                         secrets: InMemoryVoiceSecretStore(), version: "1")
        var reply = commands.handle("brain", ["_": "status"])
        XCTAssertEqual(reply["runtime"] as? String, "mclaude")
        XCTAssertNil(reply["activeRuntime"], "nothing is connected yet")
        brain.onSnapshot?(FakeBrain.snapshot(status: "idle", output: "", progress: "", approvals: [], error: nil,
                                             requestId: nil, turnId: nil, runtime: "codex"))
        reply = commands.handle("brain", ["_": "status"])
        XCTAssertEqual(reply["activeRuntime"] as? String, "codex")
        let tools = try XCTUnwrap(reply["machudTools"] as? [String: Any])
        XCTAssertEqual(tools["enabled"] as? Bool, true)
        XCTAssertEqual(tools["requireApproval"] as? Bool, false)
        XCTAssertEqual(tools["available"] as? Bool, true)
        XCTAssertEqual(tools["path"] as? String, "/Apps/MacHUD.app/Contents/Helpers/machud-mcp")
        XCTAssertNil(tools["active"], "no tool server status in that snapshot")
        // Hermes reports the tool servers it cannot give the agent.
        brain.onSnapshot?(FakeBrain.snapshot(
            status: "idle", output: "", progress: "", approvals: [], error: nil, requestId: nil, turnId: nil,
            runtime: "hermes", toolServers: AgentToolServerStatus(names: ["machud"], active: false,
                                                                  note: "Hermes cannot use tool servers.")))
        let hermes = try XCTUnwrap(commands.handle("brain", ["_": "status"])["machudTools"] as? [String: Any])
        XCTAssertEqual(hermes["active"] as? Bool, false)
        XCTAssertEqual(hermes["note"] as? String, "Hermes cannot use tool servers.")
        // The companion stopping clears it.
        brain.onStopped?()
        XCTAssertNil(commands.handle("brain", ["_": "status"])["activeRuntime"])
    }

    // MARK: Host context

    func testSnapshotReadsMacHUDsReplies() {
        let snapshot = MacHUDSnapshot(
            apps: ["ok": true, "apps": [["id": "a.b", "name": "Stash", "running": true, "panels": ["a.b/history"]],
                                        ["name": "no id"]]],
            loadouts: ["ok": true, "startup": "", "loadouts": [["name": "Focus", "slots": []]]])
        XCTAssertEqual(snapshot, MacHUDSnapshot(apps: [.init(id: "a.b", name: "Stash", panels: ["a.b/history"])],
                                                loadouts: ["Focus"], startupLoadout: nil))
    }

    func testContextListsAreBounded() {
        let apps = (0..<50).map { MacHUDSnapshot.App(id: "app\($0)", name: "App \($0)", panels: []) }
        let context = MacHUDHostContext.build(snapshot: MacHUDSnapshot(apps: apps))
        XCTAssertTrue(context.contains("- App 39 (`app39`)"))
        XCTAssertFalse(context.contains("App 40"))
        XCTAssertTrue(context.contains("- … and 10 more"))
        XCTAssertTrue(context.contains("None saved yet."))
    }

    func testToolServerIsFoundBesideTheExecutable() {
        let executable = URL(fileURLWithPath: "/Apps/MacHUD.app/Contents/Helpers/MacHUDVoice")
        let found = MacHUDToolServer.locate(beside: executable, machudSocket: "/tmp/s.sock",
                                            isExecutable: { $0 == "/Apps/MacHUD.app/Contents/Helpers/machud-mcp" })
        XCTAssertEqual(found, MacHUDToolServer(command: "/Apps/MacHUD.app/Contents/Helpers/machud-mcp",
                                               machudSocket: "/tmp/s.sock"))
        XCTAssertNil(MacHUDToolServer.locate(beside: executable, machudSocket: "/tmp/s.sock", isExecutable: { _ in false }))
    }
}
