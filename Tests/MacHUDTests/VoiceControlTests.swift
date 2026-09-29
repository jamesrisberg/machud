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
    var brainProblem: String? = "Choose a workspace folder for the agent."
    var mclaudeInstalled = false
    var brainRequests: [[String: String]] = []
    var actions: [[String: String]] = []
    var secrets: [String: String] = [:]
    var settingsSets = 0
    var said: [String] = []
    var modelRequests: [[String: String]] = []
    var kokoro: [String: Any] = ["installed": false, "downloading": false, "progress": 0.0, "bytes": 330_000_000]
    var parakeet: [String: Any] = ["installed": false, "downloading": false, "progress": 0.0, "bytes": 600_000_000,
                                   "id": "parakeet-tdt-0.6b-v2"]
    var wake: [String: Any] = ["id": "hey-jarvis", "phrase": "Hey Jarvis", "manifestId": "openwakeword-hey-jarvis-v0.1",
                               "installed": false, "downloading": false, "progress": 0.0, "bytes": 3_685_906,
                               "note": "Personal, non-commercial use only. Downloaded when you ask, never bundled with MacHUD."]
    var wakeProblem: String?
    var activeRuntime: String?
    var historyRequests: [[String: String]] = []
    /// What `history status` resolves to while no `history` setting is saved.
    var historyDefault: [String: Any] = ["mode": "textAndAudio", "shareWithSpeakFree": true]
    var speakFreeInstalled = true
    var workspace = "/Users/someone"
    var workspaceDefault = true

    init(path: String) {
        server = HUDSocketServer(path: path, label: "machud.test.voice")
        server.register("hello") { _, done in done(["ok": true, "name": "MacHUDVoice", "version": "0.1.0", "pid": 42]) }
        server.register("state") { [unowned self] _, done in done(["ok": true, "state": self.state]) }
        server.register("settings") { [unowned self] args, done in
            switch args["action"] {
            case "get":
                self.settingsGets += 1
                done(["ok": true, "settings": self.settings])
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
            if args["name"] == "say" {
                guard let text = args["text"], !text.isEmpty else { done(["ok": false, "error": "say needs text="]); return }
                self.said.append(text)
            }
            if args["name"] == "mute" { self.muted = true }
            if args["name"] == "unmute" { self.muted = false }
            done(["ok": true])
            self.server.publish("state", payload: ["state": self.state])
        }
        server.register("brain") { [unowned self] args, done in
            self.brainRequests.append(args)
            var reply: [String: Any] = [
                "ok": true, "available": self.brainProblem == nil, "workspace": self.workspace,
                "workspaceDefault": self.workspaceDefault,
                "runtimes": [["id": "codex", "name": "Codex", "installed": true, "path": "/bin/codex"],
                             ["id": "claude", "name": "Claude", "installed": false],
                             ["id": "hermes", "name": "Hermes", "installed": false],
                             ["id": "mclaude", "name": "mclaude", "installed": self.mclaudeInstalled]],
            ]
            if let problem = self.brainProblem { reply["problem"] = problem }
            done(reply)
        }
        server.register("models") { [unowned self] args, done in
            self.modelRequests.append(args)
            if args["action"] == "download" {
                switch args["id"] {
                case "parakeet": self.parakeet["downloading"] = true
                case "hey-jarvis": self.wake["downloading"] = true
                default: self.kokoro["downloading"] = true
                }
            }
            done(["ok": true, "kokoro": self.kokoro, "parakeet": self.parakeet, "wake": [self.wake]])
        }
        server.register("history") { [unowned self] args, done in
            self.historyRequests.append(args)
            let saved = self.settings["history"] as? [String: Any]
            let chosen = saved ?? self.historyDefault
            let share = (chosen["shareWithSpeakFree"] as? Bool ?? false) && self.speakFreeInstalled
            done(["ok": true, "mode": chosen["mode"] ?? "off", "shareWithSpeakFree": share,
                  "speakFreeInstalled": self.speakFreeInstalled, "default": saved == nil,
                  "folder": share ? "/Users/someone/.config/speakfree/recordings"
                      : "/Users/someone/Library/Application Support/MacHUD/Voice/History"])
        }
        server.register("secret") { [unowned self] args, done in
            guard let name = args["name"] else { done(["ok": false, "error": "secret needs name="]); return }
            if args["action"] == "set" { self.secrets[name] = args["value"] } else { self.secrets[name] = nil }
            done(["ok": true])
        }
    }

    var settingsGets = 0
    var state: [String: Any] {
        var state: [String: Any] = ["phase": ["name": "idle"], "muted": muted, "brainAvailable": brainProblem == nil]
        if let brainProblem { state["brainProblem"] = brainProblem }
        if let wakeProblem { state["wakeProblem"] = wakeProblem }
        if let activeRuntime { state["activeRuntime"] = activeRuntime }
        return state
    }
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
                                         socketPath: path, environment: [:], isolated: false, schedule: { _, _ in })
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
        XCTAssertEqual(try parse(["brain"]), .forward("brain", ["action": "status"]))
        XCTAssertEqual(try parse(["brain", "status"]), .forward("brain", ["action": "status"]))
        XCTAssertEqual(try parse(["action", "open-session"]), .forward("action", ["name": "open-session"]))
        XCTAssertEqual(try parse(["action", "name=open-session"]), .forward("action", ["name": "open-session"]))
        XCTAssertEqual(try parse(["action", "say", "text=Hello there"]), .forward("action", ["name": "say", "text": "Hello there"]))
        XCTAssertEqual(try parse(["models"]), .forward("models", ["action": "status"]))
        XCTAssertEqual(try parse(["models", "status"]), .forward("models", ["action": "status"]))
        XCTAssertEqual(try parse(["models", "download", "id=kokoro"]), .forward("models", ["action": "download", "id": "kokoro"]))
        XCTAssertEqual(try parse(["models", "download", "id=parakeet"]), .forward("models", ["action": "download", "id": "parakeet"]))
        XCTAssertEqual(try parse(["history"]), .forward("history", ["action": "status"]))
        XCTAssertEqual(try parse(["history", "status"]), .forward("history", ["action": "status"]))
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
        fails(["brain", "action=restart"], "brain only reports status")
        fails(["action", "say"], "say needs text")
        fails(["models", "download"], "download needs id")
        fails(["models", "action=delete", "id=kokoro"], "models only reports and downloads")
        fails(["history", "action=clear"], "history only reports status")
    }

    func testSeedingHistoryStartsFromTheResolvedDefault() {
        let status: [String: Any] = ["ok": true, "mode": "textAndAudio", "shareWithSpeakFree": true]
        let seeded = VoiceSettingsJSON.seedingHistory(["enabled": true], from: status)
        XCTAssertEqual(seeded["history"] as? [String: AnyHashable], ["mode": "textAndAudio", "shareWithSpeakFree": true])
        let saved: [String: Any] = ["history": ["mode": "off", "shareWithSpeakFree": false]]
        XCTAssertEqual(VoiceSettingsJSON.seedingHistory(saved, from: status)["history"] as? [String: AnyHashable],
                       ["mode": "off", "shareWithSpeakFree": false], "a saved choice is kept")
        XCTAssertNil(VoiceSettingsJSON.seedingHistory(["enabled": true], from: ["ok": false])["history"])
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
        XCTAssertEqual(run(["hello"])["name"] as? String, "MacHUDVoice")
    }

    func testSecretValueCanComeFromStdin() {
        XCTAssertEqual(ControlClient.readingSecret(["voice", "secret", "set", "name=grok"]) { "xai-7\n" },
                       ["voice", "secret", "set", "name=grok", "value=xai-7"])
        XCTAssertEqual(ControlClient.readingSecret(["voice", "secret", "set", "name=grok", "value=v"]) { XCTFail(); return nil },
                       ["voice", "secret", "set", "name=grok", "value=v"], "value= given")
        XCTAssertEqual(ControlClient.readingSecret(["voice", "secret", "clear", "name=grok"]) { XCTFail(); return nil },
                       ["voice", "secret", "clear", "name=grok"])
        XCTAssertEqual(ControlClient.readingSecret(["apply", "loadout=x"]) { XCTFail(); return nil }, ["apply", "loadout=x"])
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

    func testStateEventsDoNotReloadTheSettings() {
        supervisor.start()
        XCTAssertTrue(spin(until: { self.voice.connection.isConnected }))
        XCTAssertTrue(spin(until: { self.voice.settingsModel.status == .ready }))
        let gets = host.settingsGets
        for i in 0..<25 {
            host.muted = i % 2 == 0
            host.server.publish("state", payload: ["state": host.state])
        }
        XCTAssertTrue(spin(until: { self.voice.connection.muted == true }))
        _ = spin(until: { false }, timeout: 0.2)
        XCTAssertEqual(host.settingsGets, gets, "a state event is not a reason to fetch settings")
    }

    func testRepeatedConnectsKeepOneSubscription() {
        for _ in 0..<5 { voice.connection.connect() }
        supervisor.start()
        voice.connection.connect()
        XCTAssertTrue(spin(until: { self.voice.connection.isConnected }))
        _ = spin(until: { false }, timeout: 0.3)
        XCTAssertEqual(host.server.subscriberCount, 1)
        voice.connection.disconnect()
        voice.connection.connect()
        XCTAssertTrue(spin(until: { self.voice.connection.isConnected }))
        _ = spin(until: { false }, timeout: 0.3)
        XCTAssertTrue(spin(until: { self.host.server.subscriberCount == 1 }), "the cancelled stream is gone")
    }

    func testRetryRestartsAFailedOrStoppedHost() {
        supervisor.start()
        supervisor.stop()
        XCTAssertEqual(voice.menuTitles(), ["The voice host is stopped.", "Restart Voice Host", "Voice Settings…"])
        var loaded = false
        voice.settingsModel.retry { loaded = true }
        XCTAssertTrue(spin(until: { loaded }))
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertTrue(supervisor.isRunning)
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

    // MARK: - Brain

    func testBrainStatusIsForwarded() {
        supervisor.start()
        let reply = run(["brain", "status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["problem"] as? String, "Choose a workspace folder for the agent.")
        XCTAssertEqual((reply["runtimes"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(host.brainRequests.last?["action"], "status")
    }

    func testTheBrainTabShowsTheProblemAndFollowsIt() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.status == .ready }))
        XCTAssertTrue(spin(until: { model.brainProblem == "Choose a workspace folder for the agent." }))
        XCTAssertTrue(spin(until: { model.runtimes.count == 4 }))
        host.brainProblem = nil
        host.server.publish("state", payload: ["state": host.state])
        XCTAssertTrue(spin(until: { model.brainProblem == nil }))
        XCTAssertEqual(model.json["brainProblem"] as? String, nil)
    }

    func testMclaudeIsOfferedOnceItIsFound() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.runtimes.count == 4 }))
        XCTAssertEqual(model.runtimeOptions.map(\.value), ["codex", "claude", "hermes"])
        XCTAssertEqual(model.runtimeOptions.map(\.title), ["Codex", "Claude (not installed)", "Hermes (not installed)"])
        host.mclaudeInstalled = true
        var loaded = false
        model.loadBrainStatus { loaded = true }
        XCTAssertTrue(spin(until: { loaded }))
        XCTAssertEqual(model.runtimeOptions.map(\.value), ["codex", "claude", "hermes", "mclaude"])
    }

    func testTheBrainTabSaysWhileTheRunningRuntimeIsNotTheChosenOne() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.status == .ready }))
        host.activeRuntime = "codex"
        host.server.publish("state", payload: ["state": host.state])
        XCTAssertTrue(spin(until: { model.activeRuntime == "codex" }))
        XCTAssertNil(model.runtimeSwitchNote, "codex is the one chosen")
        var saved = false
        model.set("brain.runtime", "claude") { saved = true }
        XCTAssertTrue(spin(until: { saved }))
        XCTAssertEqual(model.runtimeSwitchNote,
                       "The brain is still running Codex; it switches to Claude when it is between turns.")
        host.activeRuntime = "claude"
        host.server.publish("state", payload: ["state": host.state])
        XCTAssertTrue(spin(until: { model.runtimeSwitchNote == nil }))
    }

    func testStatusFollowsTheHostFromStoppedToStartingToReady() {
        host.server.stop()
        supervisor.start()
        supervisor.stop()
        let model = voice.settingsModel
        XCTAssertEqual(model.status, .unavailable("The voice host is stopped."))
        supervisor.start()
        XCTAssertEqual(model.status, .unavailable("The voice host is starting."), "not stuck on stopped")
        host = FakeVoiceHost(path: path)
        XCTAssertTrue(host.server.start())
        XCTAssertTrue(spin(until: { model.status == .ready }, timeout: 10))
    }
    // MARK: - Previews and models

    func testSayAndModelsReachTheHostInTheContractsShape() throws {
        supervisor.start()
        XCTAssertEqual(run(["action", "name=say", "text=Hello there"])["ok"] as? Bool, true)
        XCTAssertEqual(host.actions.last, ["name": "say", "text": "Hello there"])
        XCTAssertEqual(host.said, ["Hello there"])
        let status = run(["models", "status"])
        XCTAssertEqual((status["kokoro"] as? [String: Any])?["installed"] as? Bool, false)
        // The settings tab loads `models status` too, in its own time: look for the request, not the last one.
        XCTAssertTrue(host.modelRequests.contains(["action": "status"]))
        let download = run(["models", "download", "id=kokoro"])
        XCTAssertEqual((download["kokoro"] as? [String: Any])?["downloading"] as? Bool, true)
        XCTAssertTrue(host.modelRequests.contains(["action": "download", "id": "kokoro"]))
    }

    func testTestVoiceSaysASampleWithTheReplyVoice() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.status == .ready }))
        model.testVoice()
        XCTAssertTrue(spin(until: { self.host.said.count == 1 }))
        XCTAssertEqual(host.said, [VoiceSettingsModel.voiceSample])
        XCTAssertNil(model.lastError)
    }

    func testKokoroStatusLoadsDownloadsAndFollowsEvents() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.kokoro != nil }))
        XCTAssertEqual(model.kokoro, VoiceSettingsModel.ModelStatus(installed: false, downloading: false, progress: 0,
                                                                    bytes: 330_000_000, error: nil))
        model.downloadKokoro()
        XCTAssertTrue(spin(until: { model.kokoro?.downloading == true }))
        XCTAssertEqual(host.modelRequests.last, ["action": "download", "id": "kokoro"])
        host.server.publish("models", payload: ["kokoro": ["installed": false, "downloading": true, "progress": 0.5,
                                                           "bytes": 330_000_000]])
        XCTAssertTrue(spin(until: { model.kokoro?.progress == 0.5 }))
        host.server.publish("models", payload: ["kokoro": ["installed": true, "downloading": false, "progress": 1.0,
                                                           "bytes": 330_000_000]])
        XCTAssertTrue(spin(until: { model.kokoro?.installed == true }))
    }

    func testSpeechModelAndHistoryReachTheHostInTheContractsShape() {
        supervisor.start()
        let download = run(["models", "download", "id=parakeet"])
        XCTAssertEqual((download["parakeet"] as? [String: Any])?["downloading"] as? Bool, true)
        XCTAssertTrue(host.modelRequests.contains(["action": "download", "id": "parakeet"]))
        let history = run(["history"])
        XCTAssertEqual(history["mode"] as? String, "textAndAudio")
        XCTAssertTrue(host.historyRequests.contains(["action": "status"]))
        // A dotted set with no history saved starts from what the default resolves to.
        XCTAssertEqual(run(["settings", "set", "history.mode=text"])["ok"] as? Bool, true)
        XCTAssertEqual(host.settings["history"] as? [String: AnyHashable], ["mode": "text", "shareWithSpeakFree": true])
    }

    func testTheVoiceTabShowsTheSpeechModelAndHistory() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.parakeet != nil && model.history != nil }))
        XCTAssertEqual(model.parakeet?.installed, false)
        XCTAssertEqual(model.history, VoiceSettingsModel.HistoryStatus(
            mode: "textAndAudio", shareWithSpeakFree: true, speakFreeInstalled: true,
            folder: "/Users/someone/.config/speakfree/recordings", isDefault: true))
        model.downloadParakeet()
        XCTAssertTrue(spin(until: { model.parakeet?.downloading == true }))
        XCTAssertTrue(host.modelRequests.contains(["action": "download", "id": "parakeet"]))
        host.server.publish("models", payload: ["parakeet": ["installed": true, "downloading": false, "progress": 1.0,
                                                             "bytes": 600_000_000]])
        XCTAssertTrue(spin(until: { model.parakeet?.installed == true }))

        model.setHistory(mode: "text")
        XCTAssertTrue(spin(until: { model.history?.mode == "text" }))
        XCTAssertEqual(host.settings["history"] as? [String: AnyHashable], ["mode": "text", "shareWithSpeakFree": true],
                       "saved whole, sharing as it was in effect")
        model.setHistory(shareWithSpeakFree: false)
        XCTAssertTrue(spin(until: { model.history?.shareWithSpeakFree == false }))
        XCTAssertEqual(host.settings["history"] as? [String: AnyHashable], ["mode": "text", "shareWithSpeakFree": false])
        XCTAssertFalse(model.history?.isDefault ?? true)
    }

    func testTheVoiceTabOffersOnlyWakePhrasesWithAModel() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { !model.wakePhrases.isEmpty }))
        XCTAssertEqual(model.wakePhrases.map(\.phrase), ["Hey Jarvis"])
        XCTAssertEqual(model.string("voice.wakePhrase"), "Hey Computer", "the saved phrase is left alone while off")
        XCTAssertEqual(model.wakePhrase?.id, "hey-jarvis", "a phrase without a model shows the first with one")
        XCTAssertEqual(model.wakePhrase?.note,
                       "Personal, non-commercial use only. Downloaded when you ask, never bundled with MacHUD.")
        XCTAssertEqual(model.wakePhrase?.model.installed, false)

        model.downloadWakeModel("hey-jarvis")
        XCTAssertTrue(spin(until: { model.wakePhrase?.model.downloading == true }))
        XCTAssertTrue(host.modelRequests.contains(["action": "download", "id": "hey-jarvis"]))
        var installed = host.wake
        installed["installed"] = true
        installed["downloading"] = false
        installed["progress"] = 1.0
        host.server.publish("models", payload: ["wake": [installed]])
        XCTAssertTrue(spin(until: { model.wakePhrase?.model.installed == true }))

        host.wakeProblem = "Download the Hey Jarvis model to use the wake word."
        host.server.publish("state", payload: ["state": host.state])
        XCTAssertTrue(spin(until: { model.wakeProblem == "Download the Hey Jarvis model to use the wake word." }))
        XCTAssertEqual(model.json["wakeProblem"] as? String, "Download the Hey Jarvis model to use the wake word.")
    }

    func testTheBrainTabShowsTheResolvedWorkspace() {
        supervisor.start()
        let model = voice.settingsModel
        XCTAssertTrue(spin(until: { model.workspace == "/Users/someone" }))
        XCTAssertTrue(model.workspaceIsDefault)
        XCTAssertEqual(model.string("brain.workspacePath"), "", "the stored choice stays empty")
    }
}
