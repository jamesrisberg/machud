import BrainKit
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// What onboarding and the settings tabs preview through the socket: `action say`, `models`,
/// and the brain workspace that defaults to the home folder.
@MainActor
final class VoiceHostPreviewTests: XCTestCase {
    private var directory: URL!
    private var dictation: FakeDictation!
    private var brain: FakeBrain!
    private var speaker: FakeSpeaker!
    private var models: FakeModels!
    private var parakeet: FakeModels!
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-preview-\(UUID().uuidString)")
        dictation = FakeDictation()
        brain = FakeBrain()
        speaker = FakeSpeaker()
        models = FakeModels()
        parakeet = FakeModels()
        parakeet.status = VoiceModelStatus(installed: false, downloading: false, progress: 0, bytes: 600_000_000,
                                           id: "parakeet-tdt-0.6b-v2")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(_ settings: VoiceHostSettings = VoiceHostSettings(), speaker: ReplySpeaking?? = nil)
        -> (VoiceHostController, VoiceHostCommands) {
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: nil, brain: brain,
            speaker: speaker ?? self.speaker, wake: nil, brainStateRoot: directory,
            detectRuntimes: FakeRuntimes.detect(), homeDirectory: home, schedule: { _, _ in })
        controller.start()
        let commands = VoiceHostCommands(controller: controller, store: VoiceHostSettingsStore(directory: directory),
                                         secrets: InMemoryVoiceSecretStore(), version: "dev",
                                         models: ["kokoro": models, "parakeet": parakeet])
        return (controller, commands)
    }

    // MARK: say

    func testSaySpeaksWithTheReplyVoiceEvenWhenRepliesAreNotSpoken() {
        var settings = VoiceHostSettings()
        settings.voice.speakReplies = false
        settings.voice.replyVoice = .system
        let (controller, commands) = make(settings)
        let reply = commands.handle("action", ["name": "say", "text": "Hello there."])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(speaker.spoken, "Hello there.")
        XCTAssertEqual(speaker.finishes, 1)
        XCTAssertEqual(speaker.voices.last?.replyVoice, .system)
        XCTAssertEqual(controller.state.phase, .speaking)
        speaker.complete()
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testSayReplacesWhatIsBeingSaid() {
        let (_, commands) = make()
        _ = commands.handle("action", ["name": "say", "text": "One."])
        _ = commands.handle("action", ["name": "say", "text": "Two."])
        XCTAssertEqual(speaker.stops, 1)
        XCTAssertEqual(speaker.spoken, "One.Two.")
    }

    func testSayNeedsText() {
        let (_, commands) = make()
        let reply = commands.handle("action", ["name": "say", "text": "  "])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "say needs text=")
        XCTAssertEqual(commands.handle("action", ["name": "say"])["ok"] as? Bool, false)
        XCTAssertEqual(speaker.spoken, "")
    }

    func testSayWaitsForATakeToEnd() {
        let (controller, commands) = make()
        controller.perform(.start(.dictation))
        let reply = commands.handle("action", ["name": "say", "text": "Hi"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, VoiceHostController.takeRecording)
        XCTAssertEqual(speaker.spoken, "")
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
    }

    func testSayWithoutAVoice() {
        let (_, commands) = make(speaker: .some(nil))
        let reply = commands.handle("action", ["name": "say", "text": "Hi"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, VoiceHostController.noSpeech)
    }

    func testSilentSpeakerFinishesWithoutSound() async {
        let silent = SilentSpeaker()
        let (controller, commands) = make(speaker: .some(silent))
        XCTAssertEqual(commands.handle("action", ["name": "say", "text": "Hi"])["ok"] as? Bool, true)
        XCTAssertEqual(silent.said, ["Hi"])
        XCTAssertEqual(controller.state.phase, .speaking)
        let idle = expectation(description: "idle")
        controller.onStateChange = { if $0.phase == .idle { idle.fulfill() } }
        await fulfillment(of: [idle], timeout: 2)
    }

    // MARK: models

    func testModelsStatus() throws {
        let (_, commands) = make()
        let reply = commands.handle("models", [:])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let kokoro = try XCTUnwrap(reply["kokoro"] as? [String: Any])
        XCTAssertEqual(kokoro["installed"] as? Bool, false)
        XCTAssertEqual(kokoro["downloading"] as? Bool, false)
        XCTAssertEqual(kokoro["progress"] as? Double, 0)
        XCTAssertEqual(kokoro["bytes"] as? Int64, 325_000_000)
        XCTAssertNil(kokoro["error"])
        XCTAssertNil(kokoro["id"])
        let parakeet = try XCTUnwrap(reply["parakeet"] as? [String: Any])
        XCTAssertEqual(parakeet["installed"] as? Bool, false)
        XCTAssertEqual(parakeet["id"] as? String, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(parakeet["bytes"] as? Int64, 600_000_000)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        XCTAssertEqual(commands.handle("models", ["action": "status"])["ok"] as? Bool, true)
    }

    func testModelsDownloadParakeetStartsOnlyIt() throws {
        let (_, commands) = make()
        let reply = commands.handle("models", ["action": "download", "id": "parakeet"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(parakeet.downloads, 1)
        XCTAssertEqual(models.downloads, 0)
        XCTAssertEqual((reply["parakeet"] as? [String: Any])?["downloading"] as? Bool, true)
        parakeet.update { $0.installed = true; $0.downloading = false }
        _ = commands.handle("models", ["action": "download", "id": "parakeet"])
        XCTAssertEqual(parakeet.downloads, 1, "installed: nothing new starts")
    }

    func testModelsDownloadStartsIt() throws {
        let (_, commands) = make()
        let reply = commands.handle("models", ["action": "download", "id": "kokoro"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(models.downloads, 1)
        XCTAssertEqual((reply["kokoro"] as? [String: Any])?["downloading"] as? Bool, true)
        // Already under way, or installed: nothing new starts.
        _ = commands.handle("models", ["_": "download", "id": "kokoro"])
        models.update { $0 = VoiceModelStatus(installed: true, downloading: false, progress: 1, bytes: 1) }
        _ = commands.handle("models", ["_": "download", "id": "kokoro"])
        XCTAssertEqual(models.downloads, 1)
    }

    func testModelsRefusesOtherModelsAndVerbs() {
        let (_, commands) = make()
        XCTAssertEqual(commands.handle("models", ["action": "download", "id": "whisper"])["ok"] as? Bool, false)
        XCTAssertEqual(commands.handle("models", ["action": "download"])["ok"] as? Bool, false)
        XCTAssertEqual(commands.handle("models", ["action": "delete", "id": "kokoro"])["ok"] as? Bool, false)
        XCTAssertEqual(models.downloads, 0)
    }

    func testModelsWithoutAStore() {
        let controller = VoiceHostController(
            settings: VoiceHostSettings(), dictation: dictation, keys: nil, brain: nil, speaker: nil, wake: nil,
            brainStateRoot: directory, detectRuntimes: FakeRuntimes.detect(), schedule: { _, _ in })
        let commands = VoiceHostCommands(controller: controller, store: VoiceHostSettingsStore(directory: directory),
                                         secrets: InMemoryVoiceSecretStore(), version: "dev")
        XCTAssertEqual(commands.handle("models", [:])["ok"] as? Bool, false)
    }

    func testModelsEventPayload() throws {
        let payload = VoiceHostCommands.modelsPayload(["kokoro": models.status, "parakeet": parakeet.status])
        let kokoro = try XCTUnwrap(payload["kokoro"] as? [String: Any])
        XCTAssertEqual(kokoro["installed"] as? Bool, false)
        XCTAssertEqual((payload["parakeet"] as? [String: Any])?["id"] as? String, "parakeet-tdt-0.6b-v2")
    }

    // MARK: workspace

    func testAnEmptyWorkspaceIsTheHomeFolder() throws {
        let (controller, commands) = make()
        let configuration = try XCTUnwrap(brain.configurations.last ?? nil)
        XCTAssertEqual(configuration.workingDirectory, home.path)
        let reply = commands.handle("brain", ["_": "status"])
        XCTAssertEqual(reply["workspace"] as? String, home.path)
        XCTAssertEqual(reply["workspaceDefault"] as? Bool, true)
        // The stored setting stays empty: the user has not chosen.
        XCTAssertEqual(controller.settings.brain.workspacePath, "")
        let stored = try XCTUnwrap(commands.handle("settings", [:])["settings"] as? [String: Any])
        XCTAssertEqual((stored["brain"] as? [String: Any])?["workspacePath"] as? String, "")
    }

    func testAChosenWorkspaceIsKept() throws {
        var settings = VoiceHostSettings()
        settings.brain.workspacePath = "/Users/someone/Projects"
        let (_, commands) = make(settings)
        XCTAssertEqual((brain.configurations.last ?? nil)?.workingDirectory, "/Users/someone/Projects")
        let reply = commands.handle("brain", ["_": "status"])
        XCTAssertEqual(reply["workspace"] as? String, "/Users/someone/Projects")
        XCTAssertEqual(reply["workspaceDefault"] as? Bool, false)
    }
}
