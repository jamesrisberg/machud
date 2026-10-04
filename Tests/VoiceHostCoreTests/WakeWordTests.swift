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
    private var journal: FakeTakeJournal!
    /// The take and wake-listener lines the controller logged.
    private var logged: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-wake-\(UUID().uuidString)")
        dictation = FakeDictation()
        brain = FakeBrain()
        wake = FakeWake()
        jarvis = FakeModels.wake(installed: false)
        clock = ManualClock()
        journal = FakeTakeJournal()
        logged = []
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
            detectRuntimes: FakeRuntimes.detect(), now: { clock.now }, schedule: { clock.schedule($0, $1) },
            takeJournal: journal)
        controller.log = { [weak self] in self?.logged.append($0) }
        controller.start()
        return controller
    }

    private func lines(_ prefix: String) -> [String] { logged.filter { $0.hasPrefix(prefix) } }

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

    func testAListenerThatStopsRestartsByItselfAndSaysWhyMeanwhile() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertEqual(wake.starts.count, 1)
        wake.fail("The microphone stopped for the wake word after an audio device change.")
        XCTAssertFalse(controller.state.wakeListening)
        XCTAssertEqual(controller.state.wakeProblem, "The microphone stopped for the wake word after an audio device change.")
        clock.advance(to: 1.9)
        XCTAssertEqual(wake.starts.count, 1)
        clock.advance(to: 2)
        XCTAssertEqual(wake.starts.count, 2, "restarted 2 s later")
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertNil(controller.state.wakeProblem, "listening again clears the problem")
        XCTAssertEqual(lines("wake listener failed"),
                       ["wake listener failed: The microphone stopped for the wake word after an audio device change.; restarting in 2 s"])
        XCTAssertEqual(lines("wake listener listening again"), ["wake listener listening again after 1 attempt"])
    }

    func testRestartsBackOffWhileTheListenerKeepsFailingAndARunIsLoggedOnce() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        let denied = "MacHUD cannot use the microphone."
        wake.startFailure = WakeFailure(reason: denied, retryable: true)
        wake.fail(denied)
        // 2 s, then 10 s, then every 60 s.
        for (time, starts) in [(1.9, 1), (2, 2), (11.9, 2), (12, 3), (71.9, 3), (72, 4), (131.9, 4), (132, 5)] {
            clock.advance(to: time)
            XCTAssertEqual(wake.starts.count, starts, "at \(time) s")
            XCTAssertEqual(controller.state.wakeProblem, denied, "the problem stays while it fails, at \(time) s")
            XCTAssertFalse(controller.state.wakeListening)
        }
        XCTAssertEqual(lines("wake listener"), ["wake listener starting: \"Hey Jarvis\", threshold 0.50, 2 frames",
                                                "wake listener listening",
                                                "wake listener failed: \(denied); restarting in 2 s"],
                       "the same failure again and again is logged once")
        // Another reason is a new run.
        wake.startFailure = WakeFailure(reason: "The microphone stopped.", retryable: true)
        clock.advance(to: 192)
        XCTAssertEqual(lines("wake listener failed").last, "wake listener failed: The microphone stopped.; restarting in 60 s")
        wake.startFailure = nil
        clock.advance(to: 252)
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertNil(controller.state.wakeProblem)
        XCTAssertEqual(lines("wake listener listening again"), ["wake listener listening again after 6 attempts"])
    }

    func testABriefRecoveryKeepsTheBackoffStep() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        wake.fail("The microphone stopped.")
        clock.advance(to: 2)
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertNil(controller.state.wakeProblem, "listening clears the problem shown")
        clock.advance(to: 2.5)
        wake.fail("The microphone stopped.")
        clock.advance(to: 12.4)
        XCTAssertEqual(wake.starts.count, 2, "not 2 s again after half a second of listening")
        clock.advance(to: 12.5)
        XCTAssertEqual(wake.starts.count, 3, "10 s later")
        XCTAssertEqual(lines("wake listener failed").last, "wake listener failed: The microphone stopped.; restarting in 10 s")
    }

    func testAFailureAfterAMinuteOfListeningStartsTheBackoffOver() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        wake.fail("The microphone stopped.")
        clock.advance(to: 2)
        wake.fail("The microphone stopped.")
        clock.advance(to: 12)
        XCTAssertTrue(controller.state.wakeListening)
        clock.advance(to: 72)
        wake.fail("The microphone stopped.")
        clock.advance(to: 73.9)
        XCTAssertEqual(wake.starts.count, 3)
        clock.advance(to: 74)
        XCTAssertEqual(wake.starts.count, 4, "2 s again after a minute of listening")
    }

    func testAModelThatWillNotLoadIsNotRetriedUntilTheModelChanges() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        let broken = "The Hey Jarvis model could not load: bad file"
        wake.fail(broken, retryable: false)
        clock.advance(to: 1000)
        XCTAssertEqual(wake.starts.count, 1, "no timer for a model that will not load")
        XCTAssertEqual(controller.state.wakeProblem, broken)
        XCTAssertEqual(lines("wake listener failed"),
                       ["wake listener failed: \(broken); not restarting until its model or the voice settings change"])
        jarvis.update { $0.progress = 1 }
        controller.wakeModelsChanged()
        XCTAssertEqual(wake.starts.count, 2, "a change to its model starts it again")
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertNil(controller.state.wakeProblem)
    }

    func testTheReasonStaysUntilTheListenerListensAgain() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        let stopped = "The microphone stopped."
        wake.listensOnStart = false
        wake.fail(stopped)
        controller.perform(.setMuted(true))
        XCTAssertNil(controller.state.wakeProblem, "muted is not a problem")
        controller.perform(.setMuted(false))
        XCTAssertEqual(wake.starts.count, 2)
        XCTAssertEqual(controller.state.wakeProblem, stopped, "started again by the unmute, not listening yet")
        wake.listen()
        XCTAssertNil(controller.state.wakeProblem)

        wake.fail(stopped)
        controller.perform(.orbClicked)
        XCTAssertEqual(controller.state.wakeProblem, stopped, "while a take records")
        controller.perform(.stop)
        dictation.finish("")
        XCTAssertEqual(wake.starts.count, 3)
        XCTAssertEqual(controller.state.wakeProblem, stopped, "started again by the take's end, not listening yet")
        wake.listen()
        XCTAssertNil(controller.state.wakeProblem)

        wake.fail(stopped)
        var settings = wakeOn()
        settings.voice.wakeThreshold = 0.6
        controller.apply(settings)
        XCTAssertEqual(wake.starts.count, 4)
        XCTAssertNil(controller.state.wakeProblem, "new voice settings start it afresh")

        wake.listen()
        wake.fail(stopped)
        var off = settings
        off.voice.wakeWordEnabled = false
        controller.apply(off)
        controller.apply(settings)
        XCTAssertEqual(wake.starts.count, 5)
        XCTAssertNil(controller.state.wakeProblem, "turned off and on again: the settings changed in between")
    }

    func testNoRestartWhileATakeRecordsOrOnceTheWakeWordIsOff() async {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        wake.fail("The microphone stopped.")
        controller.perform(.orbClicked)
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        clock.advance(to: 5)
        XCTAssertEqual(wake.starts.count, 1, "not while a take records")
        controller.perform(.stop)
        dictation.finish("")
        XCTAssertEqual(wake.starts.count, 2, "the take's end starts it, as after any take")
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertNil(controller.state.wakeProblem)

        wake.fail("The microphone stopped.")
        var settings = wakeOn()
        settings.voice.wakeWordEnabled = false
        controller.apply(settings)
        clock.advance(to: 100)
        XCTAssertEqual(wake.starts.count, 2, "not once the wake word is off")
        XCTAssertNil(controller.state.wakeProblem)
        XCTAssertEqual(lines("wake listener stopped").last, "wake listener stopped: The wake word is off")
    }

    func testTheWakeListenersLifeIsLogged() {
        jarvis = FakeModels.wake(installed: true)
        let controller = makeController(wakeOn())
        controller.perform(.orbClicked)
        controller.perform(.setMuted(true))
        XCTAssertEqual(logged.filter { $0.hasPrefix("wake listener") }, [
            #"wake listener starting: "Hey Jarvis", threshold 0.50, 2 frames"#,
            "wake listener listening",
            "wake listener stopped: A take is recording",
        ])
        controller.perform(.setMuted(false))
        XCTAssertEqual(lines("wake listener").suffix(2), [#"wake listener starting: "Hey Jarvis", threshold 0.50, 2 frames"#,
                                                          "wake listener listening"])
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
    /// a detection → an agent take, with the source stopped during the take and the same listener
    /// started again after.
    func testADetectionStartsAnAgentTakeAndTheWakeWordReArmsAfter() async throws {
        jarvis = FakeModels.wake(installed: true)
        let engine = FakeWakeEngine()
        var sources: [FakeWakeSource] = []
        var detectors = 0
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { model, _ in
                detectors += 1
                return InProcessWakeDetector(engine: engine, phrase: model.phrase, model: model.id)
            },
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
        // One loud frame (the second chunk's first frame) is not a wake under the two-frame rule.
        sources[0].send(Array(repeating: 0.9, count: 1600))
        await settle()
        XCTAssertTrue(dictation.starts.isEmpty, "a single loud frame does not wake")
        sources[0].send(Array(repeating: 0.9, count: 1600))
        await waitUntil { !self.dictation.starts.isEmpty }
        XCTAssertEqual(dictation.starts, [.caller], "an agent take")
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        await waitUntil { !sources[0].running }
        XCTAssertFalse(controller.state.wakeListening, "paused while the take records")

        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.95, phrase: "Hey Jarvis", frames: 2, peak: 0.95),
                       "the detection's score, phrase and run reach the take")
        dictation.finish("what time is it")
        await controller.pendingWork?.value
        await waitUntil { controller.state.wakeListening }
        XCTAssertEqual(sources.count, 1, "the same listener and microphone")
        XCTAssertEqual(detectors, 1, "the model is loaded once")
        XCTAssertTrue(sources[0].running, "listening again after the take")
        XCTAssertEqual(brain.submitted.map(\.text), ["what time is it"])
    }

    /// A wake that starts no take re-arms the listener running now, which drops what it hears for
    /// the quiet period (VoiceKit's), so the rest of the sound that woke it cannot wake it again.
    func testAWakeThatStartsNoTakeReArmsTheSameListenerWithAQuietPeriod() async throws {
        jarvis = FakeModels.wake(installed: true)
        var uptime: TimeInterval = 100
        var sources: [FakeWakeSource] = []
        var detectors = 0
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { model, _ in
                detectors += 1
                return InProcessWakeDetector(engine: FakeWakeEngine(), phrase: model.phrase, model: model.id)
            },
            makeSource: { let source = FakeWakeSource(); sources.append(source); return source },
            isInstalled: { _, _ in true }, now: { uptime })
        var settings = wakeOn()
        settings.brainEnabled = false
        let controller = makeController(settings, wake: listener)
        await waitUntil { controller.state.wakeListening }
        let source = try XCTUnwrap(sources.first)
        source.send(Array(repeating: 0.9, count: 3200))
        await waitUntil { self.journal.records.count == 1 }
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.brainOff)
        await waitUntil { controller.state.wakeListening }

        uptime += 0.9
        source.send(Array(repeating: 0.9, count: 3200))
        await settle()
        XCTAssertEqual(journal.records.count, 1, "within the quiet period nothing is scored")
        uptime += 0.2
        source.send(Array(repeating: 0.9, count: 3200))
        await waitUntil { self.journal.records.count == 2 }
        XCTAssertEqual(detectors, 1)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(source.running, "the microphone stayed open throughout")
        XCTAssertTrue(dictation.starts.isEmpty)
    }

    /// The listener is kept while paused for a take and started again with its model loaded; new
    /// settings replace it and close the old one's microphone.
    func testTheLiveListenerIsReplacedOnlyForNewSettings() async throws {
        jarvis = FakeModels.wake(installed: true)
        var sources: [FakeWakeSource] = []
        var detectors = 0
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { model, _ in
                detectors += 1
                return InProcessWakeDetector(engine: FakeWakeEngine(), phrase: model.phrase, model: model.id)
            },
            makeSource: { let source = FakeWakeSource(); sources.append(source); return source },
            isInstalled: { _, _ in true })
        let controller = makeController(wakeOn(), wake: listener)
        await waitUntil { controller.state.wakeListening }
        controller.perform(.orbClicked)
        await waitUntil { sources.first?.running == false }
        controller.perform(.cancel)
        await waitUntil { controller.state.wakeListening && sources.first?.running == true }
        XCTAssertEqual(detectors, 1)
        XCTAssertEqual(sources.count, 1)

        var settings = wakeOn()
        settings.voice.wakeThreshold = 0.6
        controller.apply(settings)
        await waitUntil { sources.count == 2 && sources[1].running && controller.state.wakeListening }
        XCTAssertEqual(detectors, 2)
        await waitUntil { !sources[0].running }
        XCTAssertFalse(sources[0].running, "the replaced listener's microphone is closed")
    }

    /// A detection on its way from a listener when new settings replace it reaches the host marked
    /// as not from the listener running now.
    func testADetectionInFlightFromAReplacedListenerIsNotCurrent() async throws {
        let first = GatedWakeDetector()
        var detectors: [GatedWakeDetector] = []
        var sources: [FakeWakeSource] = []
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { _, _ in
                let detector = detectors.isEmpty ? first : GatedWakeDetector()
                detectors.append(detector)
                return detector
            },
            makeSource: { let source = FakeWakeSource(); sources.append(source); return source },
            isInstalled: { _, _ in true })
        var wakes: [(score: Double, current: Bool)] = []
        listener.onWake = { wakes.append(($0.score, $1)) }
        var settings = VoiceSettings()
        settings.wakePhrase = "Hey Jarvis"
        listener.start(settings)
        await waitUntil { sources.first?.running == true }
        sources[0].send(Array(repeating: 0.5, count: 1600))
        await waitUntil { first.isWaiting }
        first.fire(WakeDetection(score: 0.9, phrase: "Hey Jarvis", frames: 2))
        settings.wakeThreshold = 0.6
        listener.start(settings)
        await waitUntil { !wakes.isEmpty }
        XCTAssertEqual(wakes.map(\.current), [false])
        XCTAssertEqual(detectors.count, 2)

        // The listener running now is current.
        await waitUntil { sources.count == 2 && sources[1].running }
        sources[1].send(Array(repeating: 0.5, count: 1600))
        await waitUntil { detectors[1].isWaiting }
        detectors[1].fire(WakeDetection(score: 0.8, phrase: "Hey Jarvis", frames: 2))
        await waitUntil { wakes.count == 2 }
        XCTAssertEqual(wakes.last?.current, true)
    }

    func testTheLiveListenerRecoversFromASourceThatFailedToStart() async throws {
        jarvis = FakeModels.wake(installed: true)
        var sources: [FakeWakeSource] = []
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { model, _ in InProcessWakeDetector(engine: FakeWakeEngine(), phrase: model.phrase, model: model.id) },
            makeSource: {
                let source = FakeWakeSource()
                source.startError = MicrophoneWakeSource.StartFailed()
                sources.append(source)
                return source
            },
            isInstalled: { _, _ in true })
        let controller = makeController(wakeOn(), wake: listener)
        await waitUntil { controller.state.wakeProblem != nil }
        XCTAssertEqual(controller.state.wakeProblem, MicrophoneWakeSource.StartFailed().errorDescription)
        let source = try XCTUnwrap(sources.first)
        // The microphone can start by the time the restart comes.
        source.startError = nil
        clock.advance(to: 2)
        await waitUntil { controller.state.wakeListening }
        XCTAssertEqual(sources.count, 1, "the same listener starts again")
        XCTAssertTrue(source.running)
        XCTAssertNil(controller.state.wakeProblem)
    }

    func testTheLiveListenerDoesNotRetryAModelThatWillNotLoad() {
        jarvis = FakeModels.wake(installed: true)
        var loads = 0
        let listener = WakeWordListener(
            modelsRoot: directory,
            makeDetector: { _, _ in
                loads += 1
                throw CocoaError(.fileReadCorruptFile)
            },
            makeSource: { FakeWakeSource() },
            isInstalled: { _, _ in true })
        let controller = makeController(wakeOn(), wake: listener)
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(controller.state.wakeProblem?.hasPrefix("The Hey Jarvis model could not load") == true,
                      "\(String(describing: controller.state.wakeProblem))")
        clock.advance(to: 1000)
        XCTAssertEqual(loads, 1, "a model that will not load is not loaded again on a timer")
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
        var problems: [WakeFailure] = []
        let listener = WakeWordListener(modelsRoot: directory, makeSource: { FakeWakeSource() })
        listener.onProblem = { problems.append($0) }
        var settings = VoiceSettings()
        settings.wakePhrase = "Hey Jarvis"
        listener.start(settings)
        XCTAssertEqual(problems, [WakeFailure(reason: "Download the Hey Jarvis model to use the wake word.", retryable: false)])
        settings.wakePhrase = "Hey Computer"
        listener.start(settings)
        XCTAssertEqual(problems.last,
                       WakeFailure(reason: "There is no wake model for “Hey Computer” yet.", retryable: false),
                       "neither is fixed by trying again")
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

/// A detector that answers each chunk only when told: `fire` hands over a detection.
@MainActor
private final class GatedWakeDetector: WakeDetector {
    private var waiting: CheckedContinuation<WakeDetection?, Never>?
    var isWaiting: Bool { waiting != nil }

    func arm(threshold: Double, frames: Int) async throws -> WakeDetectorInfo {
        WakeDetectorInfo(phrase: "Hey Jarvis", model: "fake")
    }

    func detect(_ samples: [Float]) async throws -> WakeDetection? {
        await withCheckedContinuation { waiting = $0 }
    }

    func disarm() async { answer(nil) }

    func fire(_ detection: WakeDetection) { answer(detection) }

    private func answer(_ detection: WakeDetection?) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: detection)
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
