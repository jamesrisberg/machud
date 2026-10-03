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
    private var sessions: FakeSessions!
    private var journal: FakeTakeJournal!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-cmd-\(UUID().uuidString)")
        dictation = FakeDictation()
        brain = FakeBrain()
        secrets = InMemoryVoiceSecretStore()
        sessions = FakeSessions()
        journal = FakeTakeJournal()
        let fakeBrain = brain!
        controller = VoiceHostController(
            settings: VoiceHostSettings(), dictation: dictation, keys: nil, brain: brain, speaker: nil,
            wake: nil, brainStateRoot: directory, sessions: sessions,
            sessionKeyOf: { _ in fakeBrain.sessionKey }, schedule: { _, _ in }, takeJournal: journal)
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
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        let object = try XCTUnwrap(reply["state"])
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostState.self, from: data), controller.state)
        // No presenter draws an orb here: only what the host intends for it.
        XCTAssertEqual(reply["orb"] as? [String: String], ["intended": "shown"])
    }

    func testStateSaysWhichWindowHidTheOrb() throws {
        let safari = VoiceFullScreenEvidence(id: 4321, pid: 567, app: "Safari",
                                             frame: VoiceRect(CGRect(x: 0, y: 0, width: 2560, height: 1440)), layer: 0)
        controller.setHiddenForFullScreen(true, evidence: safari)
        let reply = commands.handle("state", [:])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        let orb = try XCTUnwrap(reply["orb"] as? [String: Any])
        XCTAssertEqual(orb["intended"] as? String, "hiddenForFullScreen")
        let hiddenBy = try XCTUnwrap(orb["hiddenBy"] as? [String: Any])
        XCTAssertEqual(hiddenBy["id"] as? Int, 4321)
        XCTAssertEqual(hiddenBy["pid"] as? Int, 567)
        XCTAssertEqual(hiddenBy["app"] as? String, "Safari")
        XCTAssertEqual(hiddenBy["layer"] as? Int, 0)
        XCTAssertEqual(hiddenBy["frame"] as? [String: Double], ["x": 0, "y": 0, "w": 2560, "h": 1440])
        XCTAssertNil(orb["window"], "no orb is drawn here")
        XCTAssertNil((reply["state"] as? [String: Any])?["orb"], "not part of the published state")

        controller.setHiddenForFullScreen(false)
        XCTAssertEqual(commands.handle("state", [:])["orb"] as? [String: String], ["intended": "shown"],
                       "the evidence goes once the orb shows again")
    }

    func testStateReportsTheOrbsWindow() throws {
        let presenter = RecordingPresenter()
        presenter.orbWindow = VoiceOrbWindowReport(
            number: 812, isVisible: true, isOnActiveSpace: false, alpha: 0.5,
            frame: VoiceRect(CGRect(x: 1265, y: 1384, width: 29, height: 31)), level: 25,
            screen: VoiceOrbWindowReport.Screen(id: 1, frame: VoiceRect(CGRect(x: 0, y: 0, width: 2560, height: 1440)),
                                                hasNotch: false))
        controller.presenter = presenter
        let reply = commands.handle("state", [:])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        let window = try XCTUnwrap((reply["orb"] as? [String: Any])?["window"] as? [String: Any])
        XCTAssertEqual(window["number"] as? Int, 812)
        XCTAssertEqual(window["isVisible"] as? Bool, true)
        XCTAssertEqual(window["isOnActiveSpace"] as? Bool, false)
        XCTAssertEqual(window["alpha"] as? Double, 0.5)
        XCTAssertEqual(window["level"] as? Int, 25)
        XCTAssertEqual(window["frame"] as? [String: Double], ["x": 1265, "y": 1384, "w": 29, "h": 31])
        let screen = try XCTUnwrap(window["screen"] as? [String: Any])
        XCTAssertEqual(screen["id"] as? Int, 1)
        XCTAssertEqual(screen["frame"] as? [String: Double], ["x": 0, "y": 0, "w": 2560, "h": 1440])
        XCTAssertEqual(screen["hasNotch"] as? Bool, false)
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

    func testHandsFreeSettingsGoThroughTheSocket() throws {
        let json = #"{"handsFree":{"endOfTurn":"manual","pause":3,"sensitivity":"high"}}"#
        let reply = commands.handle("settings", ["action": "set", "settings": json])
        let handsFree = try XCTUnwrap((reply["settings"] as? [String: Any])?["handsFree"] as? [String: Any])
        XCTAssertEqual(handsFree["endOfTurn"] as? String, "manual")
        XCTAssertEqual(handsFree["pause"] as? Double, 3)
        XCTAssertEqual(handsFree["sensitivity"] as? String, "high")
        XCTAssertEqual(controller.settings.handsFree, HandsFreeSettings(endOfTurn: .manual, pause: 3, sensitivity: .high))
        let get = try XCTUnwrap(commands.handle("settings", ["action": "get"])["settings"] as? [String: Any])
        XCTAssertEqual((get["handsFree"] as? [String: Any])?["endOfTurn"] as? String, "manual")
    }

    func testAChoiceSettingOutsideItsChoicesIsRefused() {
        for json in [#"{"handsFree":{"endOfTurn":"never"}}"#, #"{"handsFree":{"sensitivity":3}}"#,
                     #"{"keyMode":"edit"}"#, #"{"brain":{"runtime":"gpt"}}"#, #"{"voice":{"replyVoice":"x"}}"#,
                     #"{"history":{"mode":"all"}}"#] {
            let reply = commands.handle("settings", ["action": "set", "settings": json])
            XCTAssertEqual(reply["ok"] as? Bool, false, json)
            XCTAssertTrue((reply["error"] as? String ?? "").contains("must be one of"), "\(reply)")
        }
        XCTAssertEqual(controller.settings, VoiceHostSettings(), "nothing was saved")
        let error = commands.handle("settings", ["action": "set", "settings": #"{"handsFree":{"endOfTurn":"never"}}"#])["error"]
        XCTAssertEqual(error as? String, "handsFree.endOfTurn must be one of auto, manual, not never")
    }

    func testStateReportsHowTheLastTakeEnded() throws {
        _ = commands.handle("action", ["name": "ask"])
        _ = commands.handle("action", ["name": "stop"])
        let state = try XCTUnwrap(commands.handle("state", [:])["state"] as? [String: Any])
        let end = try XCTUnwrap(state["lastTakeEnd"] as? [String: Any])
        XCTAssertEqual(end["reason"] as? String, "stop")
        XCTAssertNotNil(end["seconds"])
        XCTAssertEqual(end["trigger"] as? [String: String], ["source": "socket", "action": "ask"])
    }

    func testTheSocketsClickIsNotTheOrbs() {
        _ = commands.handle("action", ["name": "click"])
        _ = commands.handle("action", ["name": "click"])
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .socket(action: "click"))
    }

    // MARK: takes

    func testTakesListsTheNewestTakesOldestFirst() async throws {
        XCTAssertTrue(VoiceHostCommands.verbs.contains("takes"))
        _ = commands.handle("action", ["name": "ask"])
        _ = commands.handle("action", ["name": "stop"])
        dictation.finish("hello agent")
        await controller.pendingWork?.value
        brain.push(status: "idle", output: "Hi")
        _ = commands.handle("action", ["name": "dictate"])
        _ = commands.handle("action", ["name": "stop"])
        dictation.finish("a note")

        let reply = commands.handle("takes", [:])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        let takes = try XCTUnwrap(reply["takes"] as? [[String: Any]])
        XCTAssertEqual(takes.map { $0["outcome"] as? String }, ["sent", "typed"])
        XCTAssertEqual(takes.map { ($0["trigger"] as? [String: String])?["action"] }, ["ask", "dictate"])
        XCTAssertEqual(takes.map { $0["mode"] as? String }, ["agent", "dictation"])
        XCTAssertEqual(takes.map { $0["characters"] as? Int }, [11, 6])
        XCTAssertEqual(takes.map { $0["end"] as? String }, ["stop", "stop"])
        XCTAssertNotNil(takes.first?["date"] as? String)
        XCTAssertFalse("\(reply)".contains("hello agent"), "never the words")

        let newest = try XCTUnwrap(commands.handle("takes", ["limit": "1"])["takes"] as? [[String: Any]])
        XCTAssertEqual(newest.map { $0["outcome"] as? String }, ["typed"])
    }

    func testTakesDefaultsToTwentyAndChecksTheLimit() throws {
        for _ in 0..<25 {
            _ = commands.handle("action", ["name": "dictate"])
            _ = commands.handle("action", ["name": "cancel"])
        }
        XCTAssertEqual(journal.records.count, 25)
        XCTAssertEqual((commands.handle("takes", [:])["takes"] as? [Any])?.count, 20)
        XCTAssertEqual((commands.handle("takes", ["limit": "100"])["takes"] as? [Any])?.count, 25)
        for bad in ["0", "-1", "many", "2.5"] {
            let reply = commands.handle("takes", ["limit": bad])
            XCTAssertEqual(reply["ok"] as? Bool, false, bad)
            XCTAssertEqual(reply["error"] as? String, "takes limit= must be a whole number of at least 1")
        }
    }

    func testTakesWithoutAJournalSaysSo() {
        let bare = VoiceHostController(settings: VoiceHostSettings(), dictation: FakeDictation(), keys: nil, brain: nil,
                                       speaker: nil, wake: nil, brainStateRoot: directory, schedule: { _, _ in })
        let reply = VoiceHostCommands(controller: bare, store: VoiceHostSettingsStore(directory: directory),
                                      secrets: secrets, version: "1").handle("takes", [:])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "takes are not kept in this voice host")
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
        XCTAssertEqual(journal.records.map(\.outcome), [.refused, .refused], "each refusal is journaled")
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.voiceMuted, VoiceHostController.voiceOff])
        XCTAssertEqual(journal.records.map(\.trigger), [.socket(action: "dictate"), .socket(action: "ask")])
        XCTAssertEqual(journal.records.map(\.mode), [.dictation, .agent])
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

    // MARK: brain status

    func testBrainStatusReportsTheProblemAndTheRuntimes() throws {
        brain.onHealthChanged?(.unavailable("Choose a workspace folder for the agent."))
        let reply = commands.handle("brain", ["_": "status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["available"] as? Bool, false)
        XCTAssertEqual(reply["problem"] as? String, "Choose a workspace folder for the agent.")
        XCTAssertEqual(reply["workspace"] as? String, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(reply["runtime"] as? String, "codex")
        let runtimes = try XCTUnwrap(reply["runtimes"] as? [[String: Any]])
        XCTAssertEqual(runtimes[0]["installed"] as? Bool, true)
        XCTAssertEqual(runtimes[0]["path"] as? String, "/fake/bin/codex")
        XCTAssertEqual(runtimes[3]["installed"] as? Bool, false)
        XCTAssertNil(runtimes[3]["path"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
    }

    func testBrainStatusWhenReady() {
        brain.onHealthChanged?(.ready)
        let reply = commands.handle("brain", [:])
        XCTAssertEqual(reply["available"] as? Bool, true)
        XCTAssertNil(reply["problem"])
        XCTAssertEqual(commands.handle("brain", ["_": "restart"])["ok"] as? Bool, false)
    }

    func testStateCarriesTheProblem() throws {
        brain.onHealthChanged?(.unavailable("Choose a workspace folder for the agent."))
        let state = try XCTUnwrap(commands.handle("state", [:])["state"] as? [String: Any])
        XCTAssertEqual(state["brainProblem"] as? String, "Choose a workspace folder for the agent.")
        XCTAssertEqual(state["brainAvailable"] as? Bool, false)
    }

    // MARK: open-session

    func testOpenSessionAnswersWithTheApp() async {
        brain.sessionKey = "claude:abc"
        _ = commands.handle("action", ["name": "ask"])
        _ = commands.handle("action", ["name": "stop"])
        dictation.finish("hi")
        await controller.pendingWork?.value
        brain.push(status: "idle", output: "Hello")
        let reply = await commands.openSession()
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["app"] as? String, "SessionsApp")
        XCTAssertEqual(sessions.opened, ["claude:abc"])
    }

    func testOpenSessionWithoutASessionFails() async {
        let reply = await commands.openSession()
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, VoiceHostController.noSession)
        XCTAssertEqual(VoiceHostCommands.actionName(["name": "open-session"]), "open-session")
    }

    // MARK: Conversation

    func testSendIsATypedTurn() async {
        let reply = commands.handle("send", ["text": "list my files"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        await controller.pendingWork?.value
        XCTAssertEqual(brain.submitted.map(\.text), ["list my files"])
        XCTAssertEqual(commands.handle("send", [:])["ok"] as? Bool, false)
        brain.push(status: "running", output: "Working")
        let busy = commands.handle("send", ["text": "again"])
        XCTAssertEqual(busy["ok"] as? Bool, false)
        XCTAssertEqual(busy["error"] as? String, VoiceHostController.agentBusy)
    }

    func testConversationListsTheRows() async throws {
        _ = commands.handle("send", ["text": "hello"])
        await controller.pendingWork?.value
        brain.push(status: "idle", output: "Hi")
        let reply = commands.handle("conversation", [:])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["threadId"] as? String, "thread")
        let rows = try XCTUnwrap(reply["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["user", "reply"])
        XCTAssertEqual(rows.map { $0["text"] as? String }, ["hello", "Hi"])
        XCTAssertEqual(rows.first?["source"] as? String, "typed")
    }

    func testCardSetsTheCardState() throws {
        for (verb, mode) in [("pin", "pinned"), ("expand", "expanded"), ("peek", "peek")] {
            let reply = commands.handle("card", ["action": verb])
            XCTAssertEqual(reply["ok"] as? Bool, true, verb)
            let state = try XCTUnwrap(reply["state"] as? [String: Any])
            XCTAssertEqual(state["cardMode"] as? String, mode)
        }
        _ = commands.handle("card", ["_": "expand"])
        XCTAssertEqual(controller.state.cardMode, .expanded)
        _ = commands.handle("card", ["action": "close"])
        XCTAssertEqual(controller.state.cardMode, .peek)
        XCTAssertNil(controller.state.card)
        XCTAssertEqual(commands.handle("card", ["action": "fold"])["ok"] as? Bool, false)
    }
}
