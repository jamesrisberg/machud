import BrainKit
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// The wake word: phrases come from the models there are, it listens only once its model is
/// installed, says why when it cannot, and a detection starts an agent take. Nothing opens the
/// microphone or downloads anything: the models, the audio and the scoring are fakes.
@MainActor
final class WakeWordTests: XCTestCase {
    private var directory: URL!
    private var dictation: FakeDictation!
    private var brain: FakeBrain!
    private var wake: FakeWake!
    private var jarvis: FakeModels!
    private var clock: ManualClock!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-wake-\(UUID().uuidString)")
        dictation = FakeDictation()
        brain = FakeBrain()
        wake = FakeWake()
        jarvis = FakeModels.wake(installed: false)
        clock = ManualClock()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var wakeModels: [WakePhraseModel] { [WakePhraseModel(model: WakeModels.heyJarvis, store: jarvis)] }

    private func makeController(_ settings: VoiceHostSettings = VoiceHostSettings(),
                                wake: WakeDriving?? = nil) -> VoiceHostController {
        let clock = self.clock!
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: nil, brain: brain, speaker: nil,
            wake: wake ?? self.wake, wakeModels: wakeModels, brainStateRoot: directory,
            detectRuntimes: FakeRuntimes.detect(), now: { clock.now }, schedule: { clock.schedule($0, $1) })
        controller.start()
        return controller
    }

    private func wakeOn(_ phrase: String = VoiceSettings.defaultWakePhrase) -> VoiceHostSettings {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        settings.voice.wakePhrase = phrase
        return settings
    }

    // MARK: Phrases

    func testTheDefaultPhraseHasNoModel() {
        XCTAssertEqual(VoiceSettings().wakePhrase, "Hey Computer")
        XCTAssertNil(WakeModels.model(forPhrase: "Hey Computer"))
        XCTAssertEqual(WakePhraseModel(model: WakeModels.heyJarvis, store: jarvis).id, "hey-jarvis")
    }

    func testAPhraseWithoutAModelResolvesOnlyWhileTheWakeWordIsOn() {
        let off = VoiceHostSettings()
        XCTAssertEqual(off.resolvingWakePhrase(available: ["Hey Jarvis"]).voice.wakePhrase, "Hey Computer",
                       "not before the wake word is turned on")
        XCTAssertEqual(wakeOn().resolvingWakePhrase(available: ["Hey Jarvis"]).voice.wakePhrase, "Hey Jarvis")
        XCTAssertEqual(wakeOn("hey, jarvis").resolvingWakePhrase(available: ["Hey Jarvis"]).voice.wakePhrase,
                       "hey, jarvis", "a phrase with a model is kept as written")
        XCTAssertEqual(wakeOn().resolvingWakePhrase(available: []).voice.wakePhrase, "Hey Computer")
    }

    // MARK: Problems

    func testWakeOnWithoutItsModelSaysSoAndDoesNotListen() {
        let controller = makeController(wakeOn())
        XCTAssertEqual(controller.settings.voice.wakePhrase, "Hey Jarvis")
        XCTAssertTrue(wake.starts.isEmpty)
        XCTAssertFalse(controller.state.wakeListening)
        XCTAssertEqual(controller.state.wakeProblem, "Download the Hey Jarvis model to use the wake word.")
        XCTAssertEqual(controller.state.phase, .idle, "already on at launch: no notice on the orb")
    }

    func testTurningTheWakeWordOnShowsTheProblemOnTheOrb() {
        let controller = makeController()
        XCTAssertNil(controller.state.wakeProblem, "off is not a problem")
        XCTAssertEqual(controller.settings.voice.wakePhrase, "Hey Computer", "unchanged while off")
        controller.apply(wakeOn())
        XCTAssertEqual(controller.settings.voice.wakePhrase, "Hey Jarvis")
        let problem = "Download the Hey Jarvis model to use the wake word."
        XCTAssertEqual(controller.state.wakeProblem, problem)
        XCTAssertEqual(controller.state.phase, .failed(problem))
        clock.advance(to: VoiceHostController.failureDisplay)
        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertEqual(controller.state.wakeProblem, problem, "the problem stays until the model is installed")
    }

    func testDownloadingAndFailedDownloadsAreTheProblem() {
        let controller = makeController(wakeOn())
        jarvis.update { $0.downloading = true }
        controller.wakeModelsChanged()
        XCTAssertEqual(controller.state.wakeProblem, "The Hey Jarvis model is downloading.")
        jarvis.update { $0.downloading = false; $0.error = "The network is offline." }
        controller.wakeModelsChanged()
        XCTAssertEqual(controller.state.wakeProblem, "The Hey Jarvis model did not download: The network is offline.")
    }

    func testInstallingTheModelArmsTheWakeWordWithoutARestart() {
        let controller = makeController(wakeOn())
        jarvis.update { $0 = VoiceModelStatus(installed: true, downloading: false, progress: 1, bytes: 3_685_906) }
        controller.wakeModelsChanged()
        XCTAssertEqual(wake.starts.map(\.wakePhrase), ["Hey Jarvis"])
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertNil(controller.state.wakeProblem)
    }

    func testAListenerThatStopsSaysWhyUntilItStartsAgain() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        XCTAssertTrue(controller.state.wakeListening)
        wake.fail("MacHUD cannot use the microphone.")
        XCTAssertFalse(controller.state.wakeListening)
        XCTAssertEqual(controller.state.wakeProblem, "MacHUD cannot use the microphone.")
        controller.perform(.setMuted(true))
        XCTAssertNil(controller.state.wakeProblem, "muted is not a problem")
        controller.perform(.setMuted(false))
        XCTAssertNil(controller.state.wakeProblem)
        XCTAssertTrue(controller.state.wakeListening)
    }

    func testAHostWithoutAMicrophoneSaysSo() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn(), wake: .some(nil))
        XCTAssertFalse(controller.state.wakeListening)
        XCTAssertEqual(controller.state.wakeProblem, VoiceHostController.wakeUnavailable)
    }

    // MARK: Socket

    private func commands(for controller: VoiceHostController) -> VoiceHostCommands {
        VoiceHostCommands(controller: controller, store: VoiceHostSettingsStore(directory: directory),
                          secrets: InMemoryVoiceSecretStore(), version: "dev", models: ["kokoro": FakeModels()])
    }

    func testModelsStatusListsTheWakePhrases() throws {
        let commands = commands(for: makeController())
        let reply = commands.handle("models", ["_": "status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let wake = try XCTUnwrap(reply["wake"] as? [[String: Any]])
        XCTAssertEqual(wake.count, 1)
        let jarvis = try XCTUnwrap(wake.first)
        XCTAssertEqual(jarvis["id"] as? String, "hey-jarvis")
        XCTAssertEqual(jarvis["phrase"] as? String, "Hey Jarvis")
        XCTAssertEqual(jarvis["manifestId"] as? String, WakeModels.heyJarvis.manifest.id)
        XCTAssertEqual(jarvis["installed"] as? Bool, false)
        XCTAssertEqual(jarvis["downloading"] as? Bool, false)
        XCTAssertEqual(jarvis["redistributable"] as? Bool, false)
        XCTAssertEqual(jarvis["note"] as? String,
                       "Personal, non-commercial use only. Downloaded when you ask, never bundled with MacHUD.")
        XCTAssertTrue((jarvis["licence"] as? String)?.contains("CC BY-NC-SA 4.0") == true)
        XCTAssertFalse(wake.contains { $0["phrase"] as? String == "Hey Computer" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
    }

    func testModelsDownloadTakesTheWakeIdOrTheManifestId() {
        let commands = commands(for: makeController())
        let reply = commands.handle("models", ["_": "download", "id": "hey-jarvis"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(jarvis.downloads, 1)
        XCTAssertEqual((reply["wake"] as? [[String: Any]])?.first?["downloading"] as? Bool, true)
        jarvis.update { $0.downloading = false }
        _ = commands.handle("models", ["_": "download", "id": WakeModels.heyJarvis.manifest.id])
        XCTAssertEqual(jarvis.downloads, 2)
        let refused = commands.handle("models", ["_": "download", "id": "hey-computer"])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "models download needs id=, one of kokoro, hey-jarvis")
    }

    func testSettingsSetResolvesThePhraseWhenTheWakeWordTurnsOn() throws {
        let controller = makeController()
        let commands = commands(for: controller)
        let off = commands.handle("settings", ["_": "set", "settings": #"{"voice":{"wakeWordEnabled":false,"wakePhrase":"Hey Computer"}}"#])
        XCTAssertEqual((off["settings"] as? [String: Any]).flatMap { ($0["voice"] as? [String: Any])?["wakePhrase"] as? String },
                       "Hey Computer")
        let on = commands.handle("settings", ["_": "set", "settings": #"{"voice":{"wakeWordEnabled":true,"wakePhrase":"Hey Computer"}}"#])
        XCTAssertEqual(on["ok"] as? Bool, true, "\(on)")
        XCTAssertEqual((on["settings"] as? [String: Any]).flatMap { ($0["voice"] as? [String: Any])?["wakePhrase"] as? String },
                       "Hey Jarvis")
        XCTAssertEqual(VoiceHostSettingsStore(directory: directory).load().voice.wakePhrase, "Hey Jarvis", "saved")
        XCTAssertEqual(controller.state.wakeProblem, "Download the Hey Jarvis model to use the wake word.")
    }

    func testStateCarriesTheWakeProblem() throws {
        let controller = makeController(wakeOn())
        let data = try JSONEncoder().encode(controller.state)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["wakeProblem"] as? String, "Download the Hey Jarvis model to use the wake word.")
        XCTAssertEqual(json["wakeListening"] as? Bool, false)
        // A state from before the field decodes.
        var older = json
        older["wakeProblem"] = nil
        let decoded = try JSONDecoder().decode(VoiceHostState.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(decoded.wakeProblem)
    }

    // MARK: End to end

    /// The live listener on VoiceKit's `WakeListener` and `InProcessWakeDetector`, with a fake
    /// microphone and a fake scoring engine: installed model → the listener starts the source →
    /// a detection → an agent take, with the source stopped during the take and started again after.
    func testADetectionStartsAnAgentTakeAndTheWakeWordReArmsAfter() async throws {
        jarvis = FakeModels.wake(installed: true)
        let engine = FakeWakeEngine()
        var sources: [FakeWakeSource] = []
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { model, _ in InProcessWakeDetector(engine: engine, phrase: model.phrase, model: model.id) },
            makeSource: { let source = FakeWakeSource(); sources.append(source); return source },
            isInstalled: { _, _ in true })
        let controller = makeController(wakeOn(), wake: listener)
        await waitUntil { controller.state.wakeListening }
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(sources[0].running)
        XCTAssertNil(controller.state.wakeProblem)

        sources[0].send(Array(repeating: 0.01, count: 1600))
        await settle()
        XCTAssertTrue(dictation.starts.isEmpty, "quiet audio does not wake")
        sources[0].send(Array(repeating: 0.9, count: 1600))
        await waitUntil { !self.dictation.starts.isEmpty }
        XCTAssertEqual(dictation.starts, [.caller], "an agent take")
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        await waitUntil { !sources[0].running }
        XCTAssertFalse(controller.state.wakeListening, "paused while the take records")

        controller.perform(.stop)
        dictation.finish("what time is it")
        await controller.pendingWork?.value
        await waitUntil { controller.state.wakeListening }
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources[1].running, "listening again after the take")
        XCTAssertEqual(brain.submitted.map(\.text), ["what time is it"])
    }

    func testTheLiveListenerReportsASourceThatCannotStart() async {
        jarvis = FakeModels.wake(installed: true)
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { model, _ in InProcessWakeDetector(engine: FakeWakeEngine(), phrase: model.phrase, model: model.id) },
            makeSource: { let source = FakeWakeSource(); source.startError = MicrophoneWakeSource.MicrophoneDenied(); return source },
            isInstalled: { _, _ in true })
        let controller = makeController(wakeOn(), wake: listener)
        await waitUntil { controller.state.wakeProblem != nil }
        XCTAssertEqual(controller.state.wakeProblem, MicrophoneWakeSource.MicrophoneDenied().errorDescription)
        XCTAssertFalse(controller.state.wakeListening)
    }

    func testTheLiveListenerChecksTheModelFolder() {
        var problems: [String?] = []
        let listener = WakeWordListener(modelsRoot: directory, makeSource: { FakeWakeSource() })
        listener.onProblem = { problems.append($0) }
        var settings = VoiceSettings()
        settings.wakePhrase = "Hey Jarvis"
        listener.start(settings)
        XCTAssertEqual(problems, ["Download the Hey Jarvis model to use the wake word."])
        settings.wakePhrase = "Hey Computer"
        listener.start(settings)
        XCTAssertEqual(problems.last, "There is no wake model for “Hey Computer” yet.")
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Scores a frame loud when its mean level is high: a stand-in for openWakeWord.
private final class FakeWakeEngine: WakeScoringEngine, @unchecked Sendable {
    func reset() async throws {}
    func score(_ frame: [Float]) async throws -> Float {
        frame.reduce(0) { $0 + abs($1) } / Float(frame.count) > 0.5 ? 0.95 : 0.02
    }
}

/// The microphone, as the wake listener sees it.
@MainActor
private final class FakeWakeSource: WakeAudioSource {
    var onSamples: (([Float]) -> Void)?
    var running = false
    var startError: Error?

    func start() async throws {
        if let startError { throw startError }
        running = true
    }

    func stop() { running = false }

    func send(_ samples: [Float]) { onSamples?(samples) }
}
