import XCTest
import HUDKit
@testable import MacHUDCore

/// A stand-in voice host: a real `HUDSocketServer` speaking the `machud-voice` contract, with
/// the settings kept as the JSON object the host would store.
@MainActor
final class FakeVoiceHost {
    let server: HUDSocketServer
    var settings: [String: Any] = [
        "enabled": true, "keyMode": "hold", "agentGesture": true, "brainEnabled": true, "brainPort": 8791,
        "brain": ["runtime": "codex", "workspacePath": "", "assistantName": "", "nodePath": "",
                  "codex": ["executablePath": ""], "claude": ["executablePath": ""], "hermes": ["url": ""]],
        "voice": ["wakeWordEnabled": false, "wakePhrase": "Hey Computer", "wakeThreshold": 0.5,
                  "replyVoice": "kokoro", "speakReplies": false,
                  "kokoro": ["voice": "af_heart", "speed": 1], "system": ["voiceIdentifier": "", "rate": 1],
                  "grok": ["voice": "ara"]],
    ]
    var muted = false
    var actions: [[String: String]] = []
    var secrets: [String: String] = [:]
    var settingsSets = 0

    init(path: String) {
        server = HUDSocketServer(path: path, label: "machud.test.voice")
        server.register("hello") { _, done in done(["ok": true, "name": "MacHUDVoice", "version": "0.1.0", "pid": 42]) }
        server.register("state") { [unowned self] _, done in done(["ok": true, "state": self.state]) }
        server.register("settings") { [unowned self] args, done in
            switch args["action"] {
            case "get": done(["ok": true, "settings": self.settings])
            case "set":
                guard let raw = args["settings"], let data = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    done(["ok": false, "error": "settings set needs settings={…}"]); return
                }
                self.settingsSets += 1
                self.settings = object
                done(["ok": true, "settings": self.settings])
            default: done(["ok": false, "error": "settings action must be get or set"])
            }
        }
        server.register("action") { [unowned self] args, done in
            self.actions.append(args)
            if args["name"] == "mute" { self.muted = true }
            if args["name"] == "unmute" { self.muted = false }
            done(["ok": true])
            self.server.publish("state", payload: ["state": self.state])
        }
        server.register("secret") { [unowned self] args, done in
            guard let name = args["name"] else { done(["ok": false, "error": "secret needs name="]); return }
            if args["action"] == "set" { self.secrets[name] = args["value"] } else { self.secrets[name] = nil }
            done(["ok": true])
        }
    }

    var state: [String: Any] { ["phase": ["idle": [:] as [String: Any]], "muted": muted, "brainAvailable": false] }
}

@MainActor
final class VoiceControlTests: XCTestCase {
    private var dir: URL!
    private var path: String!
    private var host: FakeVoiceHost!
    private var launcher: FakeVoiceLauncher!
    private var supervisor: VoiceHostSupervisor!
    private var voice: VoiceServices!
    private var enabled = true

    override func setUpWithError() throws {
        // Short: socket paths are limited to 103 bytes.
        dir = URL(fileURLWithPath: "/tmp/mhv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("v.sock").path
        host = FakeVoiceHost(path: path)
        XCTAssertTrue(host.server.start())
        launcher = FakeVoiceLauncher()
        enabled = true
        supervisor = VoiceHostSupervisor(launcher: launcher, helper: { URL(fileURLWithPath: "/x/MacHUDVoice") },
                                         isEnabled: { [unowned self] in self.enabled },
                                         socketPath: path, environment: [:], schedule: { _, _ in })
        voice = VoiceServices(supervisor: supervisor, socketPath: path)
    }

    override func tearDownWithError() throws {
        voice.stop()
        host.server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Runs `voice` with CLI-style arguments, as `machud voice …` sends them.
    private func run(_ words: [String]) -> [String: Any] {
        var reply: [String: Any]?
        voice.handle(HUDSocketClient.parseArguments(words)) { reply = $0 }
        XCTAssertTrue(spin(until: { reply != nil }), "no reply to \(words)")
        return reply ?? [:]
    }

    // MARK: - Parsing

    func testParsesTheSubVerbs() throws {
        func parse(_ words: [String]) throws -> VoiceCommand { try VoiceCommand.parse(HUDSocketClient.parseArguments(words)) }
        XCTAssertEqual(try parse([]), .forward("state", [:]))
        XCTAssertEqual(try parse(["state"]), .forward("state", [:]))
        XCTAssertEqual(try parse(["status"]), .status)
        XCTAssertEqual(try parse(["action", "name=mute"]), .forward("action", ["name": "mute"]))
        XCTAssertEqual(try parse(["action", "mute"]), .forward("action", ["name": "mute"]))
        XCTAssertEqual(try parse(["action=dictate"]), .forward("action", ["name": "dictate"]))
        XCTAssertEqual(try parse(["action", "name=approve", "id=a1"]), .forward("action", ["name": "approve", "id": "a1"]))
        XCTAssertEqual(try parse(["settings"]), .forward("settings", ["action": "get"]))
        XCTAssertEqual(try parse(["settings", "get"]), .forward("settings", ["action": "get"]))
        XCTAssertEqual(try parse(["settings", "set", #"settings={"enabled":false}"#]),
                       .forward("settings", ["action": "set", "settings": #"{"enabled":false}"#]))
        XCTAssertEqual(try parse(["settings", "set", "voice.speakReplies=true"]), .mergeSettings(["voice.speakReplies": "true"]))
        XCTAssertEqual(try parse(["secret", "set", "name=grok", "value=k"]),
                       .forward("secret", ["action": "set", "name": "grok", "value": "k"]))
        XCTAssertEqual(try parse(["secret", "clear", "name=grok"]), .forward("secret", ["action": "clear", "name": "grok"]))
    }

    func testRejectsBadRequests() {
        func fails(_ words: [String], _ message: String) {
            XCTAssertThrowsError(try VoiceCommand.parse(HUDSocketClient.parseArguments(words)), message)
        }
        fails(["bogus"], "unknown sub-verb")
        fails(["action"], "no action name")
        fails(["action", "name=explode"], "not a contract action")
        fails(["action", "name=approve"], "approve needs id")
        fails(["settings", "set"], "nothing to set")
        fails(["settings", "set", "settings=[1]"], "not an object")
        fails(["secret", "set", "name=grok"], "no value")
        fails(["secret", "set", "value=k"], "no name")
    }

    func testMergeFollowsTheStoredTypes() throws {
        let base: [String: Any] = ["enabled": true, "brainPort": 8791, "voice": ["wakeThreshold": 0.5, "wakePhrase": "Hey"],
                                   "brain": ["assistantName": ""]]
        let merged = try VoiceSettingsJSON.merging(base, ["enabled": "false", "brainPort": "9000", "voice.wakeThreshold": "0.7",
                                                          "brain.assistantName": "42"])
        XCTAssertEqual(merged["enabled"] as? Bool, false)
        XCTAssertEqual(merged["brainPort"] as? Int, 9000)
        XCTAssertEqual((merged["voice"] as? [String: Any])?["wakeThreshold"] as? Double, 0.7)
        XCTAssertEqual((merged["voice"] as? [String: Any])?["wakePhrase"] as? String, "Hey", "siblings kept")
        XCTAssertEqual((merged["brain"] as? [String: Any])?["assistantName"] as? String, "42", "a string stays a string")
        XCTAssertThrowsError(try VoiceSettingsJSON.merging(base, ["enabeld": "false"]), "unknown key")
        XCTAssertThrowsError(try VoiceSettingsJSON.merging(base, ["enabled": "maybe"]), "not a bool")
        XCTAssertThrowsError(try VoiceSettingsJSON.merging(base, ["brainPort": "x"]), "not a number")
        XCTAssertThrowsError(try VoiceSettingsJSON.merging(base, ["voice": "x"]), "an object is not a value")
    }

    // MARK: - Forwarding to the host

    func testStateAndActionsReachTheHost() {
        let state = run(["state"])
        XCTAssertEqual(state["ok"] as? Bool, true)
        XCTAssertEqual((state["state"] as? [String: Any])?["muted"] as? Bool, false)

        XCTAssertEqual(run(["action", "mute"])["ok"] as? Bool, true)
        XCTAssertEqual(host.actions.last?["name"], "mute")
        XCTAssertTrue(host.muted)

        XCTAssertEqual(run(["action", "name=deny", "id=t7"])["ok"] as? Bool, true)
        XCTAssertEqual(host.actions.last, ["name": "deny", "id": "t7"])
    }

    func testSettingsRoundTripKeepsEveryOtherValue() {
        let reply = run(["settings", "set", "voice.speakReplies=true", "brain.runtime=claude"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let voiceSettings = host.settings["voice"] as? [String: Any]
        XCTAssertEqual(voiceSettings?["speakReplies"] as? Bool, true)
        XCTAssertEqual(voiceSettings?["wakePhrase"] as? String, "Hey Computer", "a full object went back")
        XCTAssertEqual((host.settings["brain"] as? [String: Any])?["runtime"] as? String, "claude")
        XCTAssertEqual(host.settings["brainPort"] as? Int, 8791)

        let got = run(["settings", "get"])
        XCTAssertEqual(((got["settings"] as? [String: Any])?["voice"] as? [String: Any])?["speakReplies"] as? Bool, true)
    }

    func testTurningVoiceOffStopsTheHelper() {
        supervisor.start()
        XCTAssertEqual(launcher.launches.count, 1)
        enabled = false
        XCTAssertEqual(run(["settings", "set", "enabled=false"])["ok"] as? Bool, true)
        XCTAssertTrue(spin(until: { self.supervisor.status == .disabled }))
        XCTAssertTrue(launcher.children[0].terminated)
    }

    func testSecretIsForwardedAndNeverEchoed() {
        let reply = run(["secret", "set", "name=grok", "value=xai-123"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(host.secrets["grok"], "xai-123")
        XCTAssertFalse("\(reply)".contains("xai-123"))
        XCTAssertEqual(run(["secret", "clear", "name=grok"])["ok"] as? Bool, true)
        XCTAssertNil(host.secrets["grok"])
    }

    func testHostDownIsAClearError() {
        host.server.stop()
        let reply = run(["state"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue((reply["error"] as? String ?? "").contains("voice host is not reachable"), "\(reply)")
    }

    func testStatusDescribesTheSupervisor() {
        supervisor.start()
        let reply = run(["status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["status"] as? String, "running")
        XCTAssertEqual(reply["pid"] as? Int, 1000)
        XCTAssertEqual(reply["socket"] as? String, path)
    }

    // MARK: - Subscription, menu and the settings tabs

    func testSubscriptionTracksMuted() {
        supervisor.start()
        XCTAssertTrue(spin(until: { self.voice.connection.isConnected }))
        XCTAssertEqual(voice.connection.muted, false)
        XCTAssertEqual(voice.menuTitles(), ["Mute Voice", "Voice Settings…"])
        _ = run(["action", "mute"])
        XCTAssertTrue(spin(until: { self.voice.connection.muted == true }))
        XCTAssertEqual(voice.menuTitles(), ["Unmute Voice", "Voice Settings…"])
    }

    func testMenuWhileDisabledOffersToTurnOn() {
        enabled = false
        supervisor.start()
        XCTAssertEqual(voice.menuTitles(), ["Voice is off", "Turn On Voice", "Voice Settings…"])
    }

    func testSettingsModelLoadsAndWritesFullObjects() {
        supervisor.start()
        let model = voice.settingsModel
        var loaded = false
        model.load { loaded = true }
        XCTAssertTrue(spin(until: { loaded }))
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.string("keyMode"), "hold")
        XCTAssertEqual(model.double("voice.wakeThreshold"), 0.5)

        model.set("voice.wakeWordEnabled", true)
        XCTAssertTrue(spin(until: { (self.host.settings["voice"] as? [String: Any])?["wakeWordEnabled"] as? Bool == true }))
        XCTAssertEqual((host.settings["voice"] as? [String: Any])?["wakePhrase"] as? String, "Hey Computer")
        XCTAssertTrue(spin(until: { model.bool("voice.wakeWordEnabled") }))
        XCTAssertEqual(host.settingsSets, 1)

        model.saveSecret("grok", value: "  xai-9  ")
        XCTAssertTrue(spin(until: { self.host.secrets["grok"] == "xai-9" }))
    }

    func testSettingsModelWhileTheHostIsDown() {
        host.server.stop()
        supervisor.start()
        let model = voice.settingsModel
        var loaded = false
        model.load { loaded = true }
        XCTAssertTrue(spin(until: { loaded }))
        guard case .unavailable(let message) = model.status else { return XCTFail("\(model.status)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(model.canEdit)
    }
}
