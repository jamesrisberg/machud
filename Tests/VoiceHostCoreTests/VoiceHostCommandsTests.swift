import VoiceKit
import XCTest
@testable import VoiceHostCore

@MainActor
final class VoiceHostCommandsTests: XCTestCase {
    private var directory: URL!
    private var dictation: FakeDictation!
    private var brain: FakeBrain!
    private var secrets: InMemoryVoiceSecretStore!
    private var controller: VoiceHostController!
    private var commands: VoiceHostCommands!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-cmd-\(UUID().uuidString)")
        dictation = FakeDictation()
        brain = FakeBrain()
        secrets = InMemoryVoiceSecretStore()
        controller = VoiceHostController(
            settings: VoiceHostSettings(), dictation: dictation, keys: nil, brain: brain, speaker: nil,
            wake: nil, brainStateRoot: directory, schedule: { _, _ in })
        controller.start()
        commands = VoiceHostCommands(controller: controller, store: VoiceHostSettingsStore(directory: directory),
                                     secrets: secrets, version: "1.2.3")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testHello() {
        let reply = commands.handle("hello", [:])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["name"] as? String, "MacHUDVoice")
        XCTAssertEqual(reply["version"] as? String, "1.2.3")
        XCTAssertEqual(reply["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
    }

    func testStateIsTheStateJSON() throws {
        let reply = commands.handle("state", [:])
        let object = try XCTUnwrap(reply["state"])
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostState.self, from: data), controller.state)
    }

    func testSettingsSetSavesAppliesAndReturnsTheStoredValue() throws {
        let json = #"{"keyMode":"toggle","brainEnabled":false,"brainPort":1}"#
        let reply = commands.handle("settings", ["_": "set", "settings": json])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let returned = try XCTUnwrap(reply["settings"] as? [String: Any])
        XCTAssertEqual(returned["keyMode"] as? String, "toggle")
        XCTAssertEqual(returned["brainPort"] as? Int, 8791)
        XCTAssertEqual(controller.settings.keyMode, .toggle)
        XCTAssertFalse(controller.settings.brainEnabled)
        XCTAssertEqual(VoiceHostSettingsStore(directory: directory).load(), controller.settings)
        let get = commands.handle("settings", ["action": "get"])
        XCTAssertEqual((get["settings"] as? [String: Any])?["keyMode"] as? String, "toggle")
    }

    func testTurningVoiceOnThroughTheSocketTakesEffect() {
        _ = commands.handle("settings", ["action": "set", "settings": #"{"enabled":false}"#])
        XCTAssertNil(brain.configurations.last ?? nil)
        let reply = commands.handle("settings", ["action": "set", "settings": #"{"enabled":true}"#])
        XCTAssertEqual((reply["settings"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertNotNil(brain.configurations.last ?? nil)
    }

    func testSettingsSetRejectsNonObjects() {
        for bad in ["[]", "nope", "\"x\""] {
            XCTAssertEqual(commands.handle("settings", ["_": "set", "settings": bad])["ok"] as? Bool, false)
        }
        XCTAssertEqual(commands.handle("settings", ["_": "set"])["ok"] as? Bool, false)
    }

    func testActionsMapOntoTheController() {
        XCTAssertEqual(commands.handle("action", ["name": "ask"])["ok"] as? Bool, true)
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        _ = commands.handle("action", ["name": "stop"])
        XCTAssertEqual(dictation.stops, 1)
        dictation.finish("")
        _ = commands.handle("action", ["_": "dictate"])
        XCTAssertEqual(dictation.starts, [.caller, .cursor])
        _ = commands.handle("action", ["name": "cancel"])
        XCTAssertEqual(dictation.cancels, 1)
        _ = commands.handle("action", ["name": "mute"])
        XCTAssertTrue(controller.state.muted)
        _ = commands.handle("action", ["name": "unmute"])
        XCTAssertFalse(controller.state.muted)
        _ = commands.handle("action", ["name": "click"])
        XCTAssertEqual(dictation.starts.last, .caller)
    }

    func testTakesRefusedWhileMutedOrOff() {
        _ = commands.handle("action", ["name": "mute"])
        let muted = commands.handle("action", ["name": "dictate"])
        XCTAssertEqual(muted["ok"] as? Bool, false)
        XCTAssertEqual(muted["error"] as? String, VoiceHostController.voiceMuted)
        _ = commands.handle("action", ["name": "unmute"])
        _ = commands.handle("settings", ["action": "set", "settings": #"{"enabled":false}"#])
        let off = commands.handle("action", ["name": "ask"])
        XCTAssertEqual(off["error"] as? String, VoiceHostController.voiceOff)
        XCTAssertTrue(dictation.starts.isEmpty)
    }

    func testApproveNeedsAnID() async {
        XCTAssertEqual(commands.handle("action", ["name": "approve"])["ok"] as? Bool, false)
        XCTAssertEqual(commands.handle("action", ["name": "deny", "id": "a"])["ok"] as? Bool, true)
        await controller.pendingWork?.value
        XCTAssertEqual(brain.approvals.map(\.id), ["a"])
        XCTAssertEqual(commands.handle("action", ["name": "jump"])["ok"] as? Bool, false)
    }

    func testSecretsAreWrittenNeverReturned() {
        let reply = commands.handle("secret", ["_": "set", "name": "grok", "value": "xai-123"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(secrets.string(forKey: VoiceSecrets.grokAPIKey), "xai-123")
        XCTAssertFalse("\(reply)".contains("xai-123"))
        XCTAssertEqual(commands.handle("secret", ["action": "clear", "name": "grok"])["ok"] as? Bool, true)
        XCTAssertNil(secrets.string(forKey: VoiceSecrets.grokAPIKey))
        XCTAssertEqual(commands.handle("secret", ["_": "set", "name": "openai", "value": "x"])["ok"] as? Bool, false)
        XCTAssertEqual(commands.handle("secret", ["_": "get", "name": "grok"])["ok"] as? Bool, false)
    }
}
