import BrainKit
import SpeakFreeLib
import VoiceKit
import XCTest
@testable import VoiceHostCore

@MainActor
final class VoiceHostControllerTests: XCTestCase {
    private var dictation: FakeDictation!
    private var keys: FakeKeys!
    private var brain: FakeBrain!
    private var speaker: FakeSpeaker!
    private var wake: FakeWake!
    /// The Hey Jarvis model's files, installed unless a test says otherwise.
    private var wakeStore: FakeModels!
    private var presenter: RecordingPresenter!
    private var clock: ManualClock!
    private var sessions: FakeSessions!
    private var journal: FakeTakeJournal!
    /// Confirms every wake's phrase at once unless a test holds its answer.
    private var confirmer: FakeWakeConfirmer!
    /// The take and wake-listener lines the controller logged.
    private var logged: [String] = []
    private var missingRuntimes: Set<String> = []
    private var pluginRuntimes: [String] = []
    private let brainRoot = URL(fileURLWithPath: "/tmp/voice-tests/Brain")
    /// The wall clock at uptime 0; it moves with `clock`.
    private let launchDate = Date(timeIntervalSince1970: 1_791_000_000)

    override func setUp() async throws {
        dictation = FakeDictation()
        keys = FakeKeys()
        brain = FakeBrain()
        speaker = FakeSpeaker()
        wake = FakeWake()
        wakeStore = FakeModels.wake(installed: true)
        presenter = RecordingPresenter()
        clock = ManualClock()
        sessions = FakeSessions()
        journal = FakeTakeJournal()
        confirmer = FakeWakeConfirmer()
        logged = []
        missingRuntimes = []
        pluginRuntimes = []
    }

    private func makeController(_ settings: VoiceHostSettings = VoiceHostSettings(),
                                brain: BrainDriving?? = nil) -> VoiceHostController {
        let clock = self.clock!
        let fakeBrain = self.brain!
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: keys,
            brain: brain ?? self.brain, speaker: speaker, wake: wake,
            wakeModels: [WakePhraseModel(model: WakeModels.heyJarvis, store: wakeStore)], wakeConfirmer: confirmer,
            brainStateRoot: brainRoot,
            sessions: sessions, detectRuntimes: FakeRuntimes.detect(missing: missingRuntimes, plugins: pluginRuntimes),
            sessionKeyOf: { _ in fakeBrain.sessionKey },
            now: { clock.now }, wallClock: { [launchDate] in launchDate.addingTimeInterval(clock.now) },
            schedule: { clock.schedule($0, $1) }, takeJournal: journal)
        controller.log = { [weak self] in self?.logged.append($0) }
        controller.presenter = presenter
        controller.start()
        return controller
    }

    /// The journal's date for uptime `time`.
    private func date(at time: TimeInterval) -> String {
        VoiceTakeRecord.timestamp(launchDate.addingTimeInterval(time))
    }

    private func lines(_ prefix: String) -> [String] { logged.filter { $0.hasPrefix(prefix) } }

    private func settled(_ controller: VoiceHostController) async {
        await controller.pendingWork?.value
    }

    // MARK: fn gestures

    func testKeysStartWithModeAndAgentGesture() {
        var settings = VoiceHostSettings()
        settings.keyMode = .toggle
        settings.agentGesture = false
        _ = makeController(settings)
        XCTAssertEqual(keys.starts, [FakeKeys.Start(mode: .toggle, alternateEnabled: false)])
    }

    func testSessionActiveComesFromTheDictation() {
        let controller = makeController()
        XCTAssertEqual(keys.isSessionActive?(), false)
        keys.send(.begin(.primary))
        XCTAssertEqual(keys.isSessionActive?(), true)
        withExtendedLifetime(controller) {}
    }

    func testHoldDictatesAtTheCursor() {
        let controller = makeController()
        keys.send(.begin(.primary))
        XCTAssertEqual(dictation.starts, [.cursor])
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
        keys.send(.end)
        XCTAssertEqual(dictation.stops, 1)
        XCTAssertEqual(controller.state.phase, .transcribing(.dictation))
        dictation.finish("hello there")
        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertTrue(brain.submitted.isEmpty)
    }

    func testAlternateGestureSendsTheTakeToTheAgent() async {
        let controller = makeController()
        keys.send(.begin(.primary))
        keys.send(.retarget(.alternate))
        XCTAssertEqual(dictation.retargets, [.caller])
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        keys.send(.end)
        XCTAssertEqual(controller.state.phase, .transcribing(.agent))
        dictation.finish("what time is it")
        await settled(controller)
        XCTAssertEqual(brain.submitted.map(\.text), ["what time is it"])
        XCTAssertEqual(controller.state.card?.prompt, "what time is it")
        XCTAssertEqual(controller.state.phase, .working)
    }

    func testDiscardAbortsQuietly() {
        let controller = makeController()
        keys.send(.begin(.primary))
        keys.send(.discard)
        XCTAssertEqual(dictation.cancels, 1)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testMuteStopsKeysAndWakeAndUnmuteRestartsThem() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        XCTAssertTrue(keys.running)
        XCTAssertTrue(wake.listening)
        controller.perform(.setMuted(true))
        XCTAssertTrue(controller.state.muted)
        XCTAssertFalse(keys.running)
        XCTAssertFalse(wake.listening)
        XCTAssertFalse(controller.state.wakeListening)
        controller.perform(.setMuted(false))
        XCTAssertTrue(keys.running)
        XCTAssertTrue(wake.listening)
    }

    func testDisabledVoiceIdlesUntilTurnedOn() {
        var settings = VoiceHostSettings()
        settings.enabled = false
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        XCTAssertTrue(keys.starts.isEmpty)
        XCTAssertTrue(wake.starts.isEmpty)
        XCTAssertEqual(brain.configurations.count, 1)
        XCTAssertNil(brain.configurations[0])
        XCTAssertEqual(controller.state.phase, .idle)
        settings.enabled = true
        controller.apply(settings)
        XCTAssertTrue(keys.running)
        XCTAssertTrue(wake.listening)
        XCTAssertNotNil(brain.configurations.last ?? nil)
        settings.enabled = false
        controller.apply(settings)
        XCTAssertFalse(keys.running)
        XCTAssertFalse(wake.listening)
        XCTAssertNil(brain.configurations.last ?? nil)
    }

    func testChangingKeyModeRestartsTheKeys() {
        let controller = makeController()
        var settings = controller.settings
        settings.keyMode = .toggle
        controller.apply(settings)
        XCTAssertEqual(keys.starts.last, FakeKeys.Start(mode: .toggle, alternateEnabled: true))
        let count = keys.starts.count
        controller.apply(settings)
        XCTAssertEqual(keys.starts.count, count, "an unchanged key setup is not restarted")
    }

    // MARK: Orb click and endpointing

    /// Levels every 50 ms from `start` up to (not including) `end`, as SpeakFree sends them.
    private func levels(_ value: Double, from start: Double, to end: Double) {
        var time = start
        while time < end - 1e-9, dictation.isCapturing {
            clock.now = time
            dictation.level(value)
            time += 0.05
        }
    }

    /// Words at 0.6, 0.4 s each with a 0.1 s gap at the start of every half second.
    private func speak(from start: Double, to end: Double) {
        var time = start
        while time < end - 1e-9, dictation.isCapturing {
            clock.now = time
            dictation.level((time + 1e-9).truncatingRemainder(dividingBy: 0.5) < 0.1 ? 0.01 : 0.6)
            time += 0.05
        }
    }

    func testOrbClickStartsAnAgentTakeThatEndsOnSilence() {
        let controller = makeController()
        controller.perform(.orbClicked)
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        speak(from: 0, to: 1)
        XCTAssertEqual(controller.state.inputLevel, 0.6)
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        dictation.partial("What is on my calendar today?")
        levels(0.01, from: 1, to: 2.9)
        XCTAssertEqual(dictation.stops, 0, "a pause shorter than 2 s keeps listening")
        levels(0.01, from: 2.9, to: 3.1)
        XCTAssertEqual(dictation.stops, 1)
        XCTAssertEqual(clock.now, 3, accuracy: 0.001)
    }

    func testAnUnfinishedSentenceWaitsLonger() {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        controller.perform(.orbClicked)
        speak(from: 0, to: 1)
        dictation.partial("Open the browser and")
        levels(0.01, from: 1, to: 4.4)
        XCTAssertEqual(dictation.stops, 0)
        levels(0.01, from: 4.4, to: 4.6)
        XCTAssertEqual(dictation.stops, 1)
    }

    func testThePauseSettingAppliesToTheNextTake() {
        var settings = VoiceHostSettings()
        settings.handsFree.pause = 1
        let controller = makeController(settings)
        defer { withExtendedLifetime(controller) {} }
        controller.perform(.orbClicked)
        speak(from: 0, to: 1)
        dictation.partial("Stop.")
        levels(0.01, from: 1, to: 2.1)
        XCTAssertEqual(dictation.stops, 1)
        XCTAssertEqual(clock.now, 2, accuracy: 0.001)
    }

    func testManualEndOfTurnWaitsForTheTap() throws {
        var settings = VoiceHostSettings()
        settings.handsFree.endOfTurn = .manual
        let controller = makeController(settings)
        controller.perform(.orbClicked)
        speak(from: 0, to: 1)
        dictation.partial("Done.")
        levels(0.01, from: 1, to: 60)
        XCTAssertEqual(dictation.stops, 0)
        controller.perform(.orbClicked)
        XCTAssertEqual(dictation.stops, 1)
        XCTAssertEqual(try XCTUnwrap(controller.state.lastTakeEnd).reason, .stop)
    }

    func testAHandsFreeTakeSaysWhyItEndedAndWhatStartedIt() throws {
        let controller = makeController()
        controller.perform(.orbClicked)
        levels(0.01, from: 0, to: 0.5)
        speak(from: 0.5, to: 1.5)
        dictation.partial("Mute the music.")
        levels(0.01, from: 1.5, to: 5)
        let end = try XCTUnwrap(controller.state.lastTakeEnd)
        XCTAssertEqual(end.reason, .pause)
        XCTAssertEqual(end.seconds, 3.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(end.quietMs), 2000)
        XCTAssertEqual(try XCTUnwrap(end.floor), 0.012, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(end.threshold), 0.03, accuracy: 0.001)
        XCTAssertEqual(end.pause, 2)
        XCTAssertEqual(end.grace, false)
        XCTAssertEqual(end.trigger, .orb)
        XCTAssertEqual(lines("take ended").count, 1)
        let ended = try XCTUnwrap(lines("take ended").first)
        XCTAssertTrue(ended.contains("pause"), ended)
        XCTAssertTrue(ended.contains("2000 ms"), ended)
        XCTAssertTrue(ended.hasSuffix("started by orb"), ended)
        dictation.finish("Mute the music.")
        XCTAssertEqual(lines("take ended").count, 1, "one line per take")
    }

    func testTakeEndsAreReportedForEveryWayATakeEnds() throws {
        let controller = makeController()
        controller.perform(.start(.agent))
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.reason, .stop)
        dictation.finish("")

        controller.perform(.start(.agent))
        controller.perform(.cancel)
        XCTAssertEqual(controller.state.lastTakeEnd?.reason, .cancelled)

        clock.now = 200
        controller.perform(.orbClicked)
        speak(from: 200, to: 321)
        XCTAssertEqual(dictation.stops, 2)
        let end = try XCTUnwrap(controller.state.lastTakeEnd)
        XCTAssertEqual(end.reason, .maximum)
        XCTAssertEqual(end.seconds, 120, accuracy: 0.001)
        dictation.finish("")

        controller.perform(.orbClicked)
        dictation.onUpdate?(dictation.takeID, .failed(.tooShort))
        XCTAssertEqual(controller.state.lastTakeEnd?.reason, .failed)
    }

    func testATakeWithNothingHeardIsThrownAway() throws {
        let controller = makeController()
        controller.perform(.orbClicked)
        levels(0.01, from: 0, to: 9.9)
        XCTAssertEqual(dictation.cancels, 0)
        levels(0.01, from: 9.9, to: 10.1)
        XCTAssertEqual(dictation.cancels, 1)
        XCTAssertEqual(dictation.stops, 0, "nothing is transcribed or sent")
        XCTAssertEqual(try XCTUnwrap(controller.state.lastTakeEnd).reason, .nothingHeard)
        XCTAssertEqual(controller.state.phase, .failed("Didn't hear anything"))
        XCTAssertTrue(brain.submitted.isEmpty)
    }

    func testKeyTakesReportNoTakeEnd() {
        let controller = makeController()
        keys.send(.begin(.primary))
        keys.send(.end)
        XCTAssertNil(controller.state.lastTakeEnd)
    }

    func testFnTakesAreNotEndpointed() {
        let controller = makeController()
        defer { withExtendedLifetime(controller) {} }
        keys.send(.begin(.primary))
        keys.send(.retarget(.alternate))
        clock.now = 0.1
        dictation.level(0.6)
        clock.now = 5
        dictation.level(0.01)
        XCTAssertEqual(dictation.stops, 0)
    }

    func testOrbClickWhileListeningStops() {
        let controller = makeController()
        controller.perform(.orbClicked)
        controller.perform(.orbClicked)
        XCTAssertEqual(dictation.stops, 1)
    }

    func testSocketActionsStartAndStopTakes() {
        let controller = makeController()
        controller.perform(.start(.dictation))
        XCTAssertEqual(dictation.starts, [.cursor])
        controller.perform(.stop)
        XCTAssertEqual(dictation.stops, 1)
        dictation.finish("")
        controller.perform(.start(.agent))
        XCTAssertEqual(dictation.starts, [.cursor, .caller])
        controller.perform(.cancel)
        XCTAssertEqual(dictation.cancels, 1)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testMissingModelFailsWithAMessage() {
        dictation.unavailable = .modelMissing(recordingKept: false)
        let controller = makeController()
        keys.send(.begin(.primary))
        XCTAssertEqual(controller.state.phase, .failed("Speech model not installed"))
    }

    func testFailureReturnsToIdleAfterAMoment() {
        dictation.unavailable = .modelMissing(recordingKept: false)
        let controller = makeController()
        controller.perform(.start(.dictation))
        clock.advance(to: 10)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testShortTakeIsQuiet() {
        let controller = makeController()
        keys.send(.begin(.primary))
        dictation.onUpdate?(dictation.takeID, .failed(.tooShort))
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testEmptyAgentTakeSubmitsNothing() async {
        let controller = makeController()
        controller.perform(.start(.agent))
        controller.perform(.stop)
        dictation.finish("  ")
        await settled(controller)
        XCTAssertTrue(brain.submitted.isEmpty)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    // MARK: Brain

    func testBrainConfiguredFromSettings() {
        var settings = VoiceHostSettings()
        settings.brain.workspacePath = "/tmp/ws"
        _ = makeController(settings)
        let configuration = brain.configurations.last ?? nil
        XCTAssertEqual(configuration?.port, 8791)
        XCTAssertEqual(configuration?.workingDirectory, "/tmp/ws")
        XCTAssertTrue(configuration?.stateDirectory.hasPrefix(brainRoot.path) ?? false)
    }

    func testBrainDisabledStopsItAndRefusesAgentTakes() {
        var settings = VoiceHostSettings()
        settings.brainEnabled = false
        let controller = makeController(settings)
        XCTAssertEqual(brain.configurations.count, 1)
        XCTAssertNil(brain.configurations[0])
        controller.perform(.start(.agent))
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(controller.state.phase, .failed("The brain is off"))
    }

    func testNoBrainRefusesAgentTakes() {
        let controller = makeController(brain: .some(nil))
        controller.perform(.orbClicked)
        XCTAssertEqual(controller.state.phase, .failed("The brain is off"))
        XCTAssertFalse(controller.state.brainAvailable)
    }

    func testAvailabilityIsReflected() {
        let controller = makeController()
        brain.onHealthChanged?(.ready)
        XCTAssertTrue(controller.state.brainAvailable)
        XCTAssertNil(controller.state.brainProblem)
        brain.onHealthChanged?(.connecting)
        XCTAssertFalse(controller.state.brainAvailable)
        XCTAssertEqual(controller.state.brainProblem, "Connecting to the brain…")
    }

    // MARK: Brain problem

    private static let noWorkspace = "Choose a workspace folder for the agent."

    func testTheCompanionsReasonIsTheProblem() {
        let controller = makeController()
        brain.onHealthChanged?(.unavailable(Self.noWorkspace))
        XCTAssertFalse(controller.state.brainAvailable)
        XCTAssertEqual(controller.state.brainProblem, Self.noWorkspace)
        brain.onHealthChanged?(.failed("exit 1"))
        XCTAssertEqual(controller.state.brainProblem, "The brain stopped after repeated failures: exit 1")
        brain.onHealthChanged?(.restarting("exit 1"))
        XCTAssertEqual(controller.state.brainProblem, "The brain is restarting: exit 1")
        brain.onHealthChanged?(.ready)
        XCTAssertNil(controller.state.brainProblem)
    }

    func testAnUnavailableBrainRefusesAgentTakesWithItsReason() {
        let controller = makeController()
        brain.onHealthChanged?(.unavailable(Self.noWorkspace))
        controller.perform(.orbClicked)
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(controller.state.phase, .failed(Self.noWorkspace))
        XCTAssertNil(controller.socketRefusal(for: .dictation, action: "dictate"))
    }

    func testAStartingBrainStillTakesTheTake() {
        let controller = makeController()
        brain.onHealthChanged?(.starting)
        XCTAssertEqual(controller.state.brainProblem, "The brain is starting.")
        controller.perform(.orbClicked)
        XCTAssertEqual(dictation.starts, [.caller])
    }

    func testAMissingRuntimeIsTheProblem() {
        missingRuntimes = ["codex"]
        let controller = makeController()
        brain.onHealthChanged?(.ready)
        XCTAssertFalse(controller.state.brainAvailable)
        XCTAssertEqual(controller.state.brainProblem, "Codex is not installed.")
        controller.perform(.start(.agent))
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(controller.state.phase, .failed("Codex is not installed."))
    }

    func testAMissingRuntimeThatIsNotChosenIsNoProblem() {
        missingRuntimes = ["claude", "example-agent"]
        pluginRuntimes = ["example-agent"]
        let controller = makeController()
        brain.onHealthChanged?(.ready)
        XCTAssertNil(controller.state.brainProblem)
    }

    /// A chosen runtime plugin that cannot be used is the problem, in its own words; the
    /// runtime stays chosen.
    func testAChosenPluginThatCannotBeUsedIsTheProblem() {
        missingRuntimes = ["example-agent"]
        pluginRuntimes = ["example-agent"]
        var settings = VoiceHostSettings()
        settings.brain.runtime = AgentRuntime(rawValue: "example-agent")!
        let controller = makeController(settings)
        brain.onHealthChanged?(.ready)
        XCTAssertEqual(controller.state.brainProblem, "Example Agent is not installed.")
        XCTAssertEqual(controller.settings.brain.runtime.rawValue, "example-agent")
    }

    func testSettingsProblems() {
        var settings = VoiceHostSettings()
        settings.brainEnabled = false
        let controller = makeController(settings)
        XCTAssertEqual(controller.state.brainProblem, "The brain is off")
        settings.enabled = false
        controller.apply(settings)
        XCTAssertEqual(controller.state.brainProblem, "Voice is off")
        settings.enabled = true
        settings.brainEnabled = true
        controller.apply(settings)
        XCTAssertEqual(controller.state.brainProblem, "The brain is starting.")
    }

    func testNoBrainIsAProblem() {
        let controller = makeController(brain: .some(nil))
        XCTAssertEqual(controller.state.brainProblem, "The brain is off")
    }

    func testFnAlternateWithAnUnavailableBrainPastesAndSaysWhy() {
        let controller = makeController()
        brain.onHealthChanged?(.unavailable(Self.noWorkspace))
        keys.send(.begin(.primary))
        keys.send(.retarget(.alternate))
        XCTAssertTrue(dictation.retargets.isEmpty)
        keys.send(.end)
        dictation.finish("hello")
        XCTAssertEqual(controller.state.phase, .failed("Choose a workspace folder for the agent — pasted instead"))
    }

    func testSubmitToABrainThatIsNotUpSaysWhy() async {
        brain.submitError = AgentSessionError.server(503, "not ready")
        let controller = makeController()
        brain.onHealthChanged?(.connecting)
        await startTurn(controller)
        XCTAssertEqual(controller.state.phase, .failed("Connecting to the brain…"))
    }

    // MARK: Sessions

    func testSnapshotsCarryTheSessionKeyAndItsProvider() async {
        let controller = makeController()
        await startTurn(controller)
        brain.sessionKey = "claude:abc"
        brain.push(status: "running")
        XCTAssertEqual(controller.state.sessionKey, "claude:abc")
        await controller.providerLookup?.value
        XCTAssertEqual(controller.state.sessionProvider, "SessionsApp")
    }

    func testDefaultSessionKeyOfReadsTheSnapshotDirectly() async {
        let fakeBrain = brain!
        let clock = self.clock!
        let controller = VoiceHostController(
            settings: VoiceHostSettings(), dictation: dictation, keys: keys,
            brain: fakeBrain, speaker: speaker, wake: wake, brainStateRoot: brainRoot,
            sessions: sessions, detectRuntimes: FakeRuntimes.detect(missing: missingRuntimes),
            now: { clock.now }, schedule: { clock.schedule($0, $1) })
        controller.presenter = presenter
        controller.start()
        await startTurn(controller)
        fakeBrain.onSnapshot?(FakeBrain.snapshot(status: "running", output: "", progress: "", approvals: [],
                                                 error: nil, requestId: fakeBrain.submitted.last?.requestId,
                                                 turnId: "turn-1", sessionKey: "claude:xyz"))
        XCTAssertEqual(controller.state.sessionKey, "claude:xyz")
    }

    func testNoSessionKeyWithoutOne() async {
        let controller = makeController()
        await startTurn(controller)
        brain.push(status: "running")
        XCTAssertNil(controller.state.sessionKey)
        XCTAssertNil(controller.providerLookup)
    }

    func testTheSessionKeyGoesWithTheBrain() async {
        let controller = makeController()
        await startTurn(controller)
        brain.sessionKey = "claude:abc"
        brain.push(status: "running")
        brain.onStopped?()
        XCTAssertNil(controller.state.sessionKey)
    }

    func testOpenSessionAsksMacHUD() async {
        let controller = makeController()
        await startTurn(controller)
        brain.sessionKey = "claude:abc"
        brain.push(status: "idle", output: "Done.")
        sessions.result = .success("Sessions")
        controller.perform(.openSession)
        await settled(controller)
        XCTAssertEqual(sessions.opened, ["claude:abc"])
        XCTAssertEqual(controller.state.sessionProvider, "Sessions")
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testOpenSessionFailureShowsBriefly() async {
        let controller = makeController()
        await startTurn(controller)
        brain.sessionKey = "claude:abc"
        brain.push(status: "idle", output: "Done.")
        sessions.result = .failure(SessionOpenError(message: "No app shows agent sessions"))
        controller.perform(.openSession)
        await settled(controller)
        XCTAssertEqual(controller.state.phase, .failed("No app shows agent sessions"))
        clock.advance(to: 3)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testOpenSessionFailureDuringATurnGoesOnTheCard() async {
        let controller = makeController()
        await startTurn(controller)
        brain.sessionKey = "claude:abc"
        brain.push(status: "running", output: "Working")
        sessions.result = .failure(SessionOpenError(message: "No app shows agent sessions"))
        controller.perform(.openSession)
        await settled(controller)
        XCTAssertEqual(controller.state.phase, .working)
        XCTAssertEqual(controller.state.card?.progress.last, "No app shows agent sessions")
    }

    func testOpenSessionWithoutASessionSaysSo() async {
        let controller = makeController()
        controller.perform(.openSession)
        await settled(controller)
        XCTAssertTrue(sessions.opened.isEmpty)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.noSession))
    }

    private func startTurn(_ controller: VoiceHostController, _ text: String = "list my files") async {
        controller.perform(.start(.agent))
        controller.perform(.stop)
        dictation.finish(text)
        await settled(controller)
    }

    func testSnapshotsFillTheCard() async {
        let controller = makeController()
        await startTurn(controller)
        brain.push(status: "running", output: "Looking", progress: "Reading folder")
        XCTAssertEqual(controller.state.card?.reply, "Looking")
        XCTAssertEqual(controller.state.card?.progress, ["Reading folder"])
        XCTAssertEqual(controller.state.phase, .working)
        brain.push(status: "running", output: "Looking now", progress: "Reading folder")
        XCTAssertEqual(controller.state.card?.progress, ["Reading folder"])
        brain.push(status: "idle", output: "Looking now. Done.")
        XCTAssertEqual(controller.state.card?.reply, "Looking now. Done.")
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testApprovalsAreShownAndAnswered() async {
        let controller = makeController()
        await startTurn(controller)
        let approval = AgentApproval(id: "a1", kind: "command", reason: "Run ls", command: "ls -la", cwd: "/tmp")
        brain.push(status: "approval", approvals: [approval])
        XCTAssertEqual(controller.state.phase, .awaitingApproval)
        XCTAssertEqual(controller.state.card?.approval, VoiceApproval(id: "a1", summary: "Run ls", detail: "ls -la"))
        controller.perform(.approve(id: "a1"))
        await settled(controller)
        XCTAssertEqual(brain.approvals.map(\.id), ["a1"])
        XCTAssertEqual(brain.approvals.map(\.allow), [true])
        XCTAssertNil(controller.state.card?.approval)
        XCTAssertEqual(controller.state.phase, .working)
        controller.perform(.deny(id: "a2"))
        await settled(controller)
        XCTAssertEqual(brain.approvals.map(\.allow), [true, false])
    }

    func testOtherRequestsAreIgnored() async {
        let controller = makeController()
        await startTurn(controller)
        brain.push(status: "idle", output: "an old reply", requestId: "someone-else")
        XCTAssertEqual(controller.state.phase, .working)
        XCTAssertEqual(controller.state.card?.reply, "")
    }

    func testBrainFailureIsShown() async {
        let controller = makeController()
        await startTurn(controller)
        brain.push(status: "failed", error: "Codex is not signed in")
        XCTAssertEqual(controller.state.phase, .failed("Codex is not signed in"))
    }

    func testSubmitErrorIsShown() async {
        brain.submitError = AgentSessionError.server(503, "not ready")
        let controller = makeController()
        await startTurn(controller)
        guard case .failed = controller.state.phase else { return XCTFail("\(controller.state.phase)") }
    }

    func testCancelInterruptsTheBrain() async {
        let controller = makeController()
        await startTurn(controller)
        controller.perform(.cancel)
        await settled(controller)
        XCTAssertEqual(brain.cancels, 1)
        brain.push(status: "interrupted", output: "partial")
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testDismissClearsTheCard() async {
        let controller = makeController()
        await startTurn(controller)
        brain.push(status: "idle", output: "Done.")
        controller.perform(.dismissCard)
        XCTAssertNil(controller.state.card)
    }

    // MARK: Review fixes: one turn at a time, brain loss, mute, speech into the mic

    /// A MacHUD tool call the runtime asks about (Codex's `tool` kind, when the tools require
    /// approval) is shown and answered like a command.
    func testToolApprovalsAreShownAndAnswered() async {
        let controller = makeController()
        await startTurn(controller)
        let approval = AgentApproval(id: "t1", kind: "tool", reason: "Use a machud tool", command: "machud: apply_loadout")
        brain.push(status: "approval", approvals: [approval])
        XCTAssertEqual(controller.state.phase, .awaitingApproval)
        XCTAssertEqual(controller.state.card?.approval,
                       VoiceApproval(id: "t1", summary: "Use a machud tool", detail: "machud: apply_loadout"))
        controller.perform(.approve(id: "t1"))
        await settled(controller)
        XCTAssertEqual(brain.approvals.map(\.id), ["t1"])
        XCTAssertEqual(brain.approvals.map(\.allow), [true])
    }

    func testAgentTakeWhileATurnRunsIsRefused() async {
        let controller = makeController()
        await startTurn(controller, "first")
        let approval = AgentApproval(id: "a1", kind: "command", reason: "Run ls")
        brain.push(status: "approval", approvals: [approval])
        let starts = dictation.starts.count
        controller.perform(.start(.agent))
        XCTAssertEqual(dictation.starts.count, starts)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusy))
        XCTAssertEqual(controller.state.card?.prompt, "first")
        XCTAssertEqual(controller.state.card?.approval?.id, "a1")
        XCTAssertEqual(brain.submitted.count, 1)
        // The running turn is still followed.
        brain.push(status: "idle", output: "done")
        XCTAssertEqual(controller.state.card?.reply, "done")
    }

    func testWakeWhileATurnRunsIsRefusedOnceConfirmed() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        await startTurn(controller)
        let starts = dictation.starts.count
        confirmer.immediate = nil
        wake.detect(score: 0.61)
        XCTAssertEqual(controller.state.phase, .working, "nothing shows before it is confirmed")
        confirmer.answer("Hey Jarvis, stop.")
        XCTAssertEqual(dictation.starts.count, starts)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusy))
        let refused = try? XCTUnwrap(journal.records.last)
        XCTAssertEqual(refused?.outcome, .refused)
        XCTAssertEqual(refused?.reason, VoiceHostController.agentBusy)
        XCTAssertEqual(refused?.trigger, .wake(score: 0.61, phrase: "Hey Jarvis", frames: 2, peak: 0.61, confirmed: true,
                                               confirmMs: 0))
        XCTAssertNil(refused?.seconds, "it never recorded")
        XCTAssertEqual(wake.rearms, [VoiceHostController.wakeQuietPeriod])
    }

    func testFnAlternateWhileATurnRunsPastesInstead() async {
        let controller = makeController()
        await startTurn(controller, "first")
        keys.send(.begin(.primary))
        keys.send(.retarget(.alternate))
        XCTAssertTrue(dictation.retargets.isEmpty, "the take stays at the cursor")
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
        keys.send(.end)
        dictation.finish("second")
        await settled(controller)
        XCTAssertEqual(brain.submitted.map(\.text), ["first"])
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusyPasted))
        XCTAssertEqual(controller.state.card?.prompt, "first")
    }

    func testCardAndTurnChangeOnlyAfterTheBrainAccepts() async {
        let controller = makeController()
        await startTurn(controller, "first")
        brain.push(status: "idle", output: "one")
        brain.submitError = AgentSessionError.server(409, "turn already active")
        await startTurn(controller, "second")
        XCTAssertEqual(controller.state.card?.prompt, "first")
        guard case .failed = controller.state.phase else { return XCTFail("\(controller.state.phase)") }
    }

    func testCancelReachesTheBrainWhileItWorksWithoutOurTurn() async {
        let controller = makeController()
        brain.push(status: "running", output: "someone else's", requestId: "other")
        controller.perform(.cancel)
        await settled(controller)
        XCTAssertEqual(brain.cancels, 1)
    }

    func testAgentTakeRefusedWhileTheBrainWorksOnAnotherRequest() {
        let controller = makeController()
        brain.push(status: "running", requestId: "other")
        controller.perform(.start(.agent))
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusy))
        brain.push(status: "idle", requestId: "other")
        controller.perform(.start(.agent))
        XCTAssertEqual(controller.state.phase, .listening(.agent))
    }

    func testBrainTurnedOffMidTurnSettles() async {
        let controller = makeController()
        await startTurn(controller)
        var settings = controller.settings
        settings.brainEnabled = false
        controller.apply(settings)
        XCTAssertEqual(controller.state.phase, .idle)
        brain.push(status: "idle", output: "late")
        XCTAssertEqual(controller.state.card?.reply, "")
    }

    func testBrainStoppingMidTurnSettles() async {
        let controller = makeController()
        await startTurn(controller)
        brain.onStopped?()
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testFailedCancelSettles() async {
        let controller = makeController()
        await startTurn(controller)
        brain.cancelError = AgentSessionError.server(500, "gone")
        controller.perform(.cancel)
        await settled(controller)
        XCTAssertEqual(controller.state.phase, .idle)
        controller.perform(.start(.agent))
        XCTAssertEqual(controller.state.phase, .listening(.agent), "the host is not wedged")
    }

    func testMuteCancelsTheTake() {
        let controller = makeController()
        controller.perform(.start(.agent))
        controller.perform(.setMuted(true))
        XCTAssertEqual(dictation.cancels, 1)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testKeyChangeCancelsAnFnTake() {
        let controller = makeController()
        keys.send(.begin(.primary))
        var settings = controller.settings
        settings.keyMode = .toggle
        controller.apply(settings)
        XCTAssertEqual(dictation.cancels, 1)
    }

    func testKeyChangeLeavesASocketTake() {
        let controller = makeController()
        controller.perform(.start(.dictation))
        var settings = controller.settings
        settings.agentGesture = false
        controller.apply(settings)
        XCTAssertEqual(dictation.cancels, 0)
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
    }

    func testReplyIsNotSpokenIntoANewTake() async {
        var settings = VoiceHostSettings()
        settings.voice.speakReplies = true
        let controller = makeController(settings)
        await startTurn(controller)
        keys.send(.begin(.primary))
        brain.push(status: "running", output: "Streaming while you talk.")
        XCTAssertEqual(speaker.spoken, "")
        keys.send(.end)
        dictation.finish("note")
        brain.push(status: "idle", output: "Streaming while you talk. Done.")
        XCTAssertEqual(speaker.spoken, "")
        XCTAssertEqual(controller.state.card?.reply, "Streaming while you talk. Done.")
    }

    func testAlternateWithTheBrainOffPastesInstead() {
        var settings = VoiceHostSettings()
        settings.brainEnabled = false
        let controller = makeController(settings)
        keys.send(.begin(.primary))
        keys.send(.retarget(.alternate))
        XCTAssertTrue(dictation.retargets.isEmpty)
        keys.send(.end)
        dictation.finish("remember milk")
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.brainOffPasted))
    }

    func testAgentTextPastedWhenTheBrainWentOffDuringTheTake() {
        let controller = makeController()
        controller.perform(.start(.agent))
        controller.perform(.stop)
        var settings = controller.settings
        settings.brainEnabled = false
        controller.apply(settings)
        dictation.finish("remember milk")
        XCTAssertEqual(dictation.inserted, ["remember milk"])
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.brainOffPasted))
    }

    func testFailureShowsForThreeSeconds() {
        dictation.unavailable = .modelMissing(recordingKept: false)
        let controller = makeController()
        controller.perform(.start(.dictation))
        clock.advance(to: 2.9)
        XCTAssertNotEqual(controller.state.phase, .idle)
        clock.advance(to: 3)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testDisabledOrMutedRefusesSocketTakes() {
        var settings = VoiceHostSettings()
        settings.enabled = false
        let controller = makeController(settings)
        XCTAssertEqual(controller.socketRefusal(for: .dictation, action: "dictate"), VoiceHostController.voiceOff)
        settings.enabled = true
        controller.apply(settings)
        XCTAssertNil(controller.socketRefusal(for: .agent, action: "ask"))
        controller.perform(.setMuted(true))
        XCTAssertEqual(controller.socketRefusal(for: .agent, action: "ask"), VoiceHostController.voiceMuted)
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.voiceOff, VoiceHostController.voiceMuted],
                       "each refusal is journaled, with the other refusals")
        XCTAssertEqual(journal.records.map(\.trigger), [.socket(action: "dictate"), .socket(action: "ask")])
    }

    // MARK: Speech

    private func speakingSettings() -> VoiceHostSettings {
        var settings = VoiceHostSettings()
        settings.voice.speakReplies = true
        return settings
    }

    func testRepliesAreSpokenAsTheyStream() async {
        let controller = makeController(speakingSettings())
        await startTurn(controller)
        brain.push(status: "running", output: "Hello. ")
        brain.push(status: "running", output: "Hello. How are")
        XCTAssertEqual(speaker.spoken, "Hello. How are")
        brain.push(status: "idle", output: "Hello. How are you?")
        XCTAssertEqual(speaker.spoken, "Hello. How are you?")
        XCTAssertEqual(speaker.finishes, 1)
        XCTAssertEqual(controller.state.phase, .speaking)
        speaker.complete()
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testSpeechUsesTheVoiceSettings() {
        let settings = speakingSettings()
        _ = makeController(settings)
        XCTAssertEqual(speaker.voices.last, settings.voice)
    }

    func testRepliesAreNotSpokenWhenOff() async {
        let controller = makeController()
        await startTurn(controller)
        brain.push(status: "idle", output: "Quiet.")
        XCTAssertEqual(speaker.spoken, "")
    }

    func testMutedRepliesAreNotSpoken() async {
        let controller = makeController(speakingSettings())
        controller.perform(.setMuted(true))
        await startTurn(controller)
        brain.push(status: "idle", output: "Quiet.")
        XCTAssertEqual(speaker.spoken, "")
    }

    func testFnPressStopsSpeech() async {
        let controller = makeController(speakingSettings())
        await startTurn(controller)
        brain.push(status: "idle", output: "A long answer.")
        let stops = speaker.stops
        keys.send(.begin(.primary))
        XCTAssertEqual(speaker.stops, stops + 1)
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
    }

    func testOrbClickStopsSpeech() async {
        let controller = makeController(speakingSettings())
        await startTurn(controller)
        brain.push(status: "idle", output: "A long answer.")
        let stops = speaker.stops
        let starts = dictation.starts.count
        controller.perform(.orbClicked)
        XCTAssertEqual(speaker.stops, stops + 1)
        XCTAssertEqual(dictation.starts.count, starts, "the click only stops speech")
        XCTAssertEqual(controller.state.phase, .idle)
    }

    // MARK: Wake word

    /// Nothing happens on a detection until the speech model has heard the phrase in what woke the
    /// listener: no take, no orb, the reply still spoken. Then the take starts as a wake's always
    /// did, stopping the reply.
    func testAWakeStartsATakeOnlyOnceItsPhraseIsConfirmed() async {
        var settings = speakingSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        await startTurn(controller)
        brain.push(status: "idle", output: "A long answer.")
        XCTAssertEqual(controller.state.phase, .speaking)
        XCTAssertTrue(controller.state.wakeListening)
        confirmer.immediate = nil
        let before = controller.state
        let stops = speaker.stops
        let starts = dictation.starts.count
        let records = journal.records.count
        let renders = presenter.states.count
        let lineCount = logged.count
        clock.now = 10
        wake.detect(peak: 0.991, audio: [0.1, -0.2, 0.3])
        XCTAssertEqual(confirmer.heard, [[0.1, -0.2, 0.3]], "what woke it goes to the speech model")
        XCTAssertEqual(dictation.starts.count, starts, "no take before the phrase is confirmed")
        XCTAssertEqual(speaker.stops, stops, "the reply goes on")
        XCTAssertEqual(controller.state.phase, before.phase)
        XCTAssertEqual(controller.state.card, before.card)
        XCTAssertTrue(presenter.states.dropFirst(renders).allSatisfy { $0.phase == before.phase && $0.card == before.card })
        XCTAssertEqual(journal.records.count, records)
        XCTAssertEqual(logged.count, lineCount, "nothing logged until it is decided")

        clock.now = 10.14
        confirmer.answer("Hey, Jarvis. What time is it?")
        XCTAssertEqual(dictation.starts.count, starts + 1, "an agent take")
        XCTAssertEqual(dictation.starts.last, .caller)
        XCTAssertEqual(speaker.stops, stops + 1, "a confirmed wake stops the reply")
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        XCTAssertFalse(wake.listening, "paused while the take records")
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger,
                       .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.991, confirmed: true, confirmMs: 140))
        dictation.finish("what time is it")
        await settled(controller)
        XCTAssertTrue(wake.listening)
        XCTAssertEqual(journal.records.last?.trigger,
                       .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.991, confirmed: true, confirmMs: 140))
    }

    /// Speech the detector took for the phrase and the speech model did not: nothing shows,
    /// nothing stops, nothing is said; one journal line and one log line, never the words; the
    /// listener is re-armed with its quiet period.
    func testAWakeWhosePhraseIsNotConfirmedLeavesNoTrace() async {
        var settings = speakingSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        await startTurn(controller)
        brain.push(status: "idle", output: "A long answer.")
        confirmer.immediate = nil
        let before = controller.state
        let stops = speaker.stops
        let spoken = speaker.spoken
        let starts = dictation.starts.count
        let records = journal.records.count
        let renders = presenter.states.count
        let lineCount = logged.count
        clock.now = 20
        wake.detect(score: 0.61, peak: 0.7)
        clock.now = 20.2
        confirmer.answer("Hey Javier, the narrator said, turning the page.")
        XCTAssertEqual(dictation.starts.count, starts)
        XCTAssertEqual(controller.state, before, "the state is as it was")
        XCTAssertTrue(presenter.states.dropFirst(renders).allSatisfy { $0.phase == before.phase && $0.card == before.card },
                      "the orb never showed it")
        XCTAssertEqual(speaker.stops, stops, "the reply was not stopped")
        XCTAssertEqual(speaker.spoken, spoken, "nothing was said")
        XCTAssertEqual(wake.rearms, [VoiceHostController.wakeQuietPeriod])
        XCTAssertEqual(Array(journal.records.dropFirst(records)), [VoiceTakeRecord(
            date: date(at: 20), trigger: .wake(score: 0.61, phrase: "Hey Jarvis", frames: 2, peak: 0.7, confirmed: false,
                                               confirmMs: 200),
            mode: .agent, outcome: .refused, reason: VoiceHostController.wakeNotConfirmed)])
        XCTAssertEqual(VoiceHostController.wakeNotConfirmed, "The wake phrase was not confirmed")
        XCTAssertEqual(Array(logged.dropFirst(lineCount)), [
            #"take refused (The wake phrase was not confirmed): wake word "Hey Jarvis" (score 0.610, 2 frames, "#
                + "peak 0.700, not confirmed in 200 ms), agent",
        ])
        XCTAssertFalse(logged.contains { $0.contains("Javier") || $0.contains("narrator") }, "never the words")
        XCTAssertNil(controller.state.wakeProblem, "the speech model answered: no problem to show")
    }

    /// No speech model, one still loading, a transcription that fails, or no answer in 1.5 s: the
    /// wake counts as not confirmed, and `wakeProblem` says why until a wake's words are heard.
    func testAWakeThatCannotBeConfirmedSaysWhyWhereTheWakeWordsProblemsShow() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        let cases: [(WakeConfirmFailure, String)] = [
            (.noModel, VoiceHostController.wakeConfirmNoModel), (.loading, VoiceHostController.wakeConfirmLoading),
            (.failed, VoiceHostController.wakeConfirmFailed),
        ]
        for (failure, reason) in cases {
            confirmer.immediate = .failure(failure)
            wake.detect()
            XCTAssertEqual(journal.records.last?.reason, reason)
            XCTAssertEqual(journal.records.last?.trigger,
                           .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973, confirmed: false, confirmMs: 0))
            XCTAssertEqual(controller.state.wakeProblem, reason)
            XCTAssertEqual(controller.state.phase, .idle, "not on the orb: it may have been anyone talking")
            XCTAssertTrue(dictation.starts.isEmpty)
        }
        XCTAssertEqual(VoiceHostController.wakeConfirmTimeout, 1.5)
        confirmer.immediate = nil
        clock.now = 30
        wake.detect()
        clock.advance(to: 31.49)
        XCTAssertEqual(journal.records.count, 3)
        clock.advance(to: 31.5)
        XCTAssertEqual(journal.records.count, 4)
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.wakeConfirmSlow)
        XCTAssertEqual(journal.records.last?.trigger,
                       .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973, confirmed: false, confirmMs: 1500))
        XCTAssertEqual(controller.state.wakeProblem, VoiceHostController.wakeConfirmSlow)
        XCTAssertEqual(wake.rearms.count, 4, "re-armed after each")
        confirmer.answer("Hey Jarvis")
        XCTAssertTrue(dictation.starts.isEmpty, "an answer after the time is up changes nothing")
        XCTAssertEqual(journal.records.count, 4)

        confirmer.immediate = .success("hey jarvis")
        wake.detect()
        XCTAssertNil(controller.state.wakeProblem, "a wake whose words were heard clears it")
        XCTAssertEqual(dictation.starts, [.caller])
    }

    func testWithConfirmationOffTheDetectionAloneStartsTheTake() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        settings.wakeConfirm = false
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect(audio: [0.5])
        XCTAssertTrue(confirmer.heard.isEmpty, "nothing is transcribed")
        XCTAssertEqual(dictation.starts, [.caller])
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973),
                       "no confirmation recorded")
    }

    /// After a wake is decided, whatever the outcome, a take records or the listener listens,
    /// unless the wake word is meant to be off (voice off, muted, the wake word off).
    private func assertTheWakeWordIsNotDeaf(_ controller: VoiceHostController, file: StaticString = #filePath,
                                            line: UInt = #line) {
        let off = !controller.settings.enabled || controller.state.muted || !controller.settings.voice.wakeWordEnabled
        XCTAssertTrue(off || dictation.isCapturing || (wake.listening && !wake.woke && controller.state.wakeListening),
                      "neither a take recording nor the listener listening", file: file, line: line)
    }

    /// A take started by the orb while a wake is confirmed stops the listener: the wake is refused
    /// then, without waiting for its answer, which changes nothing when it comes.
    func testAWakeBeingConfirmedWhenATakeStartsIsRefusedThen() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect(score: 0.8)
        controller.perform(.orbClicked)
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.takeRecording)
        XCTAssertEqual(journal.records.last?.trigger, .wake(score: 0.8, phrase: "Hey Jarvis", frames: 2, peak: 0.8),
                       "decided without an answer")
        confirmer.answer("hey jarvis")
        XCTAssertEqual(dictation.starts, [.caller], "only the orb's take")
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        XCTAssertEqual(journal.records.count, 1)
        assertTheWakeWordIsNotDeaf(controller)
        controller.perform(.cancel)
        assertTheWakeWordIsNotDeaf(controller)
    }

    /// A mute and unmute while a wake is confirmed: that wake is refused when the listener stops,
    /// and the next one, from the listener started again, is confirmed and heard.
    func testAWakeAfterAMuteWhileAnotherWasConfirmedIsHeard() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect(score: 0.8)
        controller.perform(.setMuted(true))
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.voiceMuted])
        controller.perform(.setMuted(false))
        assertTheWakeWordIsNotDeaf(controller)
        wake.detect(score: 0.9)
        XCTAssertEqual(confirmer.heard.count, 1, "the first is still being transcribed")
        confirmer.answer("hey jarvis")
        XCTAssertTrue(dictation.starts.isEmpty, "the first answer finds its wake decided")
        XCTAssertEqual(confirmer.heard.count, 2, "then the second wake goes to the speech model")
        confirmer.answer("hey jarvis")
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.voiceMuted])
        assertTheWakeWordIsNotDeaf(controller)
    }

    /// New settings while a wake is confirmed replace the listener: that wake is refused then, and
    /// the next one is heard.
    func testAWakeAfterNewSettingsWhileAnotherWasConfirmedIsHeard() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect(score: 0.8)
        settings.voice.wakeThreshold = 0.6
        controller.apply(settings)
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.staleWake])
        assertTheWakeWordIsNotDeaf(controller)
        wake.detect(score: 0.9)
        confirmer.answer("hey jarvis")
        confirmer.answer("Hey Javier")
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.staleWake, VoiceHostController.wakeNotConfirmed])
        assertTheWakeWordIsNotDeaf(controller)
        wake.detect(score: 0.95)
        confirmer.answer("hey jarvis")
        XCTAssertEqual(dictation.starts, [.caller])
        assertTheWakeWordIsNotDeaf(controller)
    }

    /// Confirmation turned off while a wake is confirmed: that wake is still decided by its answer;
    /// the next one starts its take at once.
    func testTurningConfirmationOffWhileAWakeIsConfirmed() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect(score: 0.8)
        settings.wakeConfirm = false
        controller.apply(settings)
        XCTAssertTrue(journal.records.isEmpty, "the listener did not change")
        confirmer.answer("Hey Javier")
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.wakeNotConfirmed])
        assertTheWakeWordIsNotDeaf(controller)
        wake.detect(score: 0.9)
        XCTAssertEqual(confirmer.heard.count, 1, "not confirmed any more")
        XCTAssertEqual(dictation.starts, [.caller])
        assertTheWakeWordIsNotDeaf(controller)
    }

    /// A timeout or a failure for a wake whose listener was replaced brings back no problem the
    /// new settings cleared.
    func testALateAnswerForAReplacedListenerShowsNoProblem() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect()
        settings.voice.wakeThreshold = 0.6
        controller.apply(settings)
        clock.advance(to: VoiceHostController.wakeConfirmTimeout)
        confirmer.answer(.failure(.failed))
        XCTAssertNil(controller.state.wakeProblem)
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.staleWake])
        assertTheWakeWordIsNotDeaf(controller)
    }

    /// Whatever became of a wake, the wake word listens again (or a take records).
    func testTheWakeWordListensAgainAfterEveryKindOfDecision() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        // Confirmed: a take records; after it, the listener listens.
        wake.detect()
        assertTheWakeWordIsNotDeaf(controller)
        controller.perform(.stop)
        dictation.finish("")
        assertTheWakeWordIsNotDeaf(controller)
        // Not confirmed, and cannot be confirmed.
        for answer: Result<String, WakeConfirmFailure> in [.success("hey javier"), .failure(.noModel), .failure(.loading)] {
            confirmer.immediate = answer
            wake.detect()
            assertTheWakeWordIsNotDeaf(controller)
        }
        // No answer in time (it comes later).
        confirmer.immediate = nil
        clock.now = 100
        wake.detect()
        clock.advance(to: 100 + VoiceHostController.wakeConfirmTimeout)
        assertTheWakeWordIsNotDeaf(controller)
        confirmer.answer("hey jarvis")
        assertTheWakeWordIsNotDeaf(controller)
        // Confirmed and refused: the agent is still working.
        confirmer.immediate = .success("hey jarvis")
        brain.push(status: "running", requestId: "other")
        wake.detect()
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusy))
        assertTheWakeWordIsNotDeaf(controller)
        // Refused as stale, from a listener replaced since.
        wake.detect(current: false)
        assertTheWakeWordIsNotDeaf(controller)
    }

    /// An fn dictation that stopped recording and is being transcribed; the wake word listens again.
    private func transcribeADictation(_ controller: VoiceHostController, file: StaticString = #filePath,
                                      line: UInt = #line) {
        keys.send(.begin(.primary))
        keys.send(.end)
        XCTAssertEqual(controller.state.phase, .transcribing(.dictation), file: file, line: line)
    }

    /// The speech model transcribes one thing at a time, as SpeakFree uses it: a wake that comes
    /// while a take is being transcribed waits for it, then goes to the model.
    func testAWakeWhileATakeIsTranscribedWaitsForItThenIsConfirmed() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        clock.now = 10
        transcribeADictation(controller)
        XCTAssertTrue(wake.listening)
        wake.detect(audio: [0.4])
        XCTAssertTrue(confirmer.heard.isEmpty, "not while the take is transcribed")
        clock.now = 10.5
        dictation.finish("a note")
        XCTAssertEqual(dictation.inserted, [], "typed by the dictation itself")
        XCTAssertEqual(journal.records.map(\.outcome), [.typed])
        XCTAssertEqual(confirmer.heard, [[0.4]], "sent once the transcription is done")
        clock.now = 10.6
        confirmer.answer("Hey Jarvis")
        XCTAssertEqual(dictation.starts, [.cursor, .caller])
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger,
                       .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973, confirmed: true, confirmMs: 600))
        clock.advance(to: 20)
        XCTAssertEqual(journal.records.count, 1, "the time limit passed unused")
    }

    func testAWakeStillWaitingForATakesTranscriptionAtTheLimitCannotBeConfirmed() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        clock.now = 10
        transcribeADictation(controller)
        wake.detect()
        clock.advance(to: 11.5)
        XCTAssertEqual(VoiceHostController.wakeConfirmBusy,
                       "The speech model was still transcribing the last take, so the wake phrase could not be confirmed.")
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.wakeConfirmBusy)
        XCTAssertEqual(journal.records.last?.trigger,
                       .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973, confirmed: false, confirmMs: 1500))
        XCTAssertEqual(controller.state.wakeProblem, VoiceHostController.wakeConfirmBusy)
        XCTAssertEqual(wake.rearms, [VoiceHostController.wakeQuietPeriod])
        assertTheWakeWordIsNotDeaf(controller)
        dictation.finish("a note")
        XCTAssertTrue(confirmer.heard.isEmpty, "never sent")
        XCTAssertTrue(dictation.starts.allSatisfy { $0 == .cursor })
    }

    /// A wake waiting for a take's transcription whose listener stops (a script starts a take) is
    /// refused then, and never sent.
    func testAWakeWaitingForATakesTranscriptionIsRefusedWhenItsListenerStops() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        let first = dictation.takeID
        transcribeADictation(controller)
        let transcribed = dictation.takeID
        XCTAssertNotEqual(first, transcribed)
        wake.detect()
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.takeRecording)
        dictation.finish("a note", take: transcribed, at: .cursor)
        XCTAssertTrue(confirmer.heard.isEmpty)
        XCTAssertEqual(controller.state.phase, .listening(.agent))
    }

    /// A confirmation the time limit gave up on is still running on the speech model: the next wake
    /// waits for it to answer, as for a take's transcription, then is sent.
    func testAWakeWaitsForAnEarlierConfirmationStillRunning() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        clock.now = 10
        wake.detect(score: 0.8)
        clock.advance(to: 11.5)
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.wakeConfirmSlow)
        clock.now = 12.6
        wake.detect(score: 0.9, audio: [0.2])
        XCTAssertEqual(confirmer.heard.count, 1, "not while the first is still being transcribed")
        clock.now = 12.8
        confirmer.answer("too late")
        XCTAssertEqual(confirmer.heard, [[], [0.2]], "sent once the first answered")
        confirmer.answer("hey jarvis")
        XCTAssertEqual(dictation.starts, [.caller])
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger,
                       .wake(score: 0.9, phrase: "Hey Jarvis", frames: 2, peak: 0.9, confirmed: true, confirmMs: 200))
    }

    func testAWakeBeingConfirmedWhenTheHostQuitsIsJournaled() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        confirmer.immediate = nil
        wake.detect()
        controller.prepareToQuit()
        confirmer.answer("hey jarvis")
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.hostQuit])
        XCTAssertEqual(journal.records.last?.trigger, .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973),
                       "never answered")
    }

    func testWakeListensAgainWhenNoTakeStarts() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        settings.brainEnabled = false
        let controller = makeController(settings)
        let starts = wake.starts.count
        let stops = wake.stops
        let listenerLines = lines("wake listener")
        wake.detect()
        XCTAssertEqual(controller.state.phase, .failed("The brain is off"))
        XCTAssertEqual(wake.starts.count, starts, "the listener running now, not a new one")
        XCTAssertEqual(wake.stops, stops)
        XCTAssertEqual(VoiceHostController.wakeQuietPeriod, 1)
        XCTAssertEqual(wake.rearms, [1], "re-armed, dropping the next second of what it hears")
        XCTAssertTrue(wake.listening)
        XCTAssertTrue(controller.state.wakeListening)
        XCTAssertEqual(lines("wake listener"), listenerLines, "re-arming is not a listener stop and start")
        XCTAssertEqual(journal.records.map(\.outcome), [.refused])
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.brainOff)
    }

    func testADetectionFromAListenerStoppedOrReplacedSinceTouchesNothingButTheJournal() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        let before = controller.state
        let starts = wake.starts.count
        wake.detect(score: 0.88, current: false)
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(controller.state, before, "nothing shows")
        XCTAssertEqual(wake.starts.count, starts)
        XCTAssertTrue(wake.rearms.isEmpty, "the listener running now is left alone")
        XCTAssertTrue(wake.listening)
        XCTAssertEqual(journal.records.map(\.outcome), [.refused])
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.staleWake)
        XCTAssertEqual(lines("take refused").count, 1)
    }

    func testAWakeThatDoesNotStartATakeWhileTheListenerRestartsIsNotReArmed() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        // The dictation refuses to start: the take ends at once and the listener, paused for it,
        // starts again by itself.
        dictation.unavailable = .modelMissing(recordingKept: false)
        let starts = wake.starts.count
        wake.detect()
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.modelMissing))
        XCTAssertEqual(wake.starts.count, starts + 1)
        XCTAssertTrue(wake.rearms.isEmpty, "started afresh, so no re-arm")
        XCTAssertTrue(controller.state.wakeListening)
    }

    func testSnapshotsDoNotTakeOverARecordingTake() async {
        let controller = makeController()
        await startTurn(controller)
        keys.send(.begin(.primary))
        brain.push(status: "running", output: "Working on it")
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
        XCTAssertEqual(controller.state.card?.reply, "Working on it")
    }

    func testWakeOffByDefault() {
        _ = makeController()
        XCTAssertTrue(wake.starts.isEmpty)
    }

    // MARK: What started a take, and what became of it

    func testEveryTakeRecordsWhatStartedIt() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)

        controller.perform(.orbClicked)
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .orb)
        dictation.finish("")

        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .socket(action: "ask"))
        dictation.finish("")

        wake.detect(score: 0.912)
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.912, phrase: "Hey Jarvis", frames: 2, peak: 0.912, confirmed: true, confirmMs: 0))
        dictation.finish("")

        keys.send(.begin(.primary))
        keys.send(.end)
        dictation.finish("at the cursor")

        keys.send(.begin(.primary))
        keys.send(.retarget(.alternate))
        keys.send(.end)
        dictation.finish("to the agent")
        await settled(controller)

        XCTAssertEqual(journal.records.map(\.trigger), [
            .orb, .socket(action: "ask"), .wake(score: 0.912, phrase: "Hey Jarvis", frames: 2, peak: 0.912, confirmed: true, confirmMs: 0),
            .key(.primary, retargeted: false), .key(.primary, retargeted: true),
        ])
        XCTAssertEqual(journal.records.map(\.mode), [.agent, .agent, .agent, .dictation, .agent])
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.912, phrase: "Hey Jarvis", frames: 2, peak: 0.912, confirmed: true, confirmMs: 0),
                       "an fn take leaves the last hands-free take's ending")
    }

    func testATakeSentToTheBrainIsJournaledWithItsLengthAndCount() async throws {
        let controller = makeController()
        clock.now = 5
        controller.perform(.orbClicked)
        speak(from: 5, to: 6)
        dictation.partial("What time is it?")
        levels(0.01, from: 6, to: 8.5)
        XCTAssertEqual(dictation.stops, 1)
        dictation.finish("What time is it?")
        XCTAssertTrue(journal.records.isEmpty, "written once the brain has taken it")
        await settled(controller)
        let record = try XCTUnwrap(journal.records.last)
        XCTAssertEqual(record, VoiceTakeRecord(date: date(at: 5), trigger: .orb, mode: .agent, seconds: 3,
                                               end: .pause, outcome: .sent, characters: 16))
    }

    func testATakeTypedAtTheCursorIsJournaled() {
        let controller = makeController()
        clock.now = 1
        keys.send(.begin(.primary))
        clock.now = 2.5
        keys.send(.end)
        dictation.finish("hello there")
        XCTAssertEqual(journal.records, [VoiceTakeRecord(date: date(at: 1), trigger: .key(.primary, retargeted: false),
                                                         mode: .dictation, seconds: 1.5, end: .stop, outcome: .typed,
                                                         characters: 11)])
        withExtendedLifetime(controller) {}
    }

    /// A take the wake word started that finishes while the agent works is dropped, not typed
    /// anywhere: the orb says so and the journal records it with the count, never the words.
    func testAWakeTakeThatFinishesWhileTheAgentWorksIsDroppedNotTyped() async throws {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        wake.detect()
        controller.perform(.stop)
        brain.push(status: "running", requestId: "other")
        dictation.finish("seventy seconds of an audiobook")
        await settled(controller)
        XCTAssertTrue(dictation.inserted.isEmpty, "nothing is typed")
        XCTAssertTrue(brain.submitted.isEmpty)
        XCTAssertEqual(VoiceHostController.wakeDroppedBusy, "Heard you, but the agent is still working")
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.wakeDroppedBusy))
        let record = try XCTUnwrap(journal.records.last)
        XCTAssertEqual(record.outcome, .dropped)
        XCTAssertEqual(record.reason, VoiceHostController.wakeDroppedBusy)
        XCTAssertEqual(record.mode, .agent)
        XCTAssertEqual(record.characters, 31)
        XCTAssertEqual(record.trigger, .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973, confirmed: true,
                                             confirmMs: 0))
        XCTAssertEqual(lines("take dropped").count, 1)
        XCTAssertFalse(logged.contains { $0.contains("audiobook") }, "never the words")
        clock.advance(to: VoiceHostController.failureDisplay)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testAWakeTakeThatFinishesWhileTheBrainIsOffOrBlockedIsDropped() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        wake.detect()
        controller.perform(.stop)
        var off = settings
        off.brainEnabled = false
        controller.apply(off)
        dictation.finish("remember milk")
        XCTAssertTrue(dictation.inserted.isEmpty)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.wakeDroppedBrainOff))
        XCTAssertEqual(VoiceHostController.wakeDroppedBrainOff, "Heard you, but the brain is off")
        XCTAssertEqual(journal.records.last?.outcome, .dropped)

        controller.apply(settings)
        wake.detect()
        controller.perform(.stop)
        brain.onHealthChanged?(.unavailable(Self.noWorkspace))
        dictation.finish("remember eggs")
        await settled(controller)
        XCTAssertTrue(dictation.inserted.isEmpty)
        XCTAssertTrue(brain.submitted.isEmpty)
        let blocked = "Heard you, but the agent cannot take it: Choose a workspace folder for the agent"
        XCTAssertEqual(VoiceHostController.wakeDropped(Self.noWorkspace), blocked)
        XCTAssertEqual(controller.state.phase, .failed(blocked))
        XCTAssertEqual(journal.records.map(\.outcome), [.dropped, .dropped])
        XCTAssertEqual(journal.records.last?.reason, blocked)
    }

    /// The fn key's agent gesture, the orb and the socket's `ask` keep typing an agent take the
    /// brain cannot take at the cursor, saying so.
    func testTakesNotStartedByTheWakeWordAreStillTypedWhenTheAgentCannotTakeThem() async {
        let controller = makeController()
        /// Starts a take while the agent is free; it finishes once the agent is busy.
        func take(_ words: String, _ start: () -> Void) {
            brain.push(status: "idle", requestId: "other")
            start()
            brain.push(status: "running", requestId: "other")
            dictation.finish(words)
        }
        take("from a script") {
            controller.perform(.start(.agent), trigger: .socket(action: "ask"))
            controller.perform(.stop)
        }
        take("from the orb") {
            controller.perform(.orbClicked)
            controller.perform(.stop)
        }
        take("from the key") {
            keys.send(.begin(.alternate))
            keys.send(.end)
        }
        await settled(controller)
        XCTAssertEqual(dictation.inserted, ["from a script", "from the orb", "from the key"])
        XCTAssertEqual(journal.records.map(\.outcome), [.typed, .typed, .typed])
        XCTAssertEqual(Set(journal.records.compactMap(\.reason)), [VoiceHostController.agentBusyPasted])
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusyPasted))
    }

    /// A take that finishes while a newer one records keeps its notice off the orb: the phase is
    /// the newer take's. Dropped (the wake word's) or typed (a script's), it is journaled all the same.
    func testATakeTheAgentCannotTakeLeavesANewerTakeAlone() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        wake.detect()
        let woken = dictation.takeID
        controller.perform(.stop)
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        brain.push(status: "running", requestId: "other")
        dictation.finish("overheard", take: woken, at: .caller)
        XCTAssertEqual(journal.records.map(\.outcome), [.dropped])
        XCTAssertEqual(controller.state.phase, .listening(.agent), "the newer take's, not the notice")

        let scripted = dictation.takeID
        controller.perform(.stop)
        brain.push(status: "idle", requestId: "other")
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        brain.push(status: "running", requestId: "other")
        dictation.finish("for later", take: scripted, at: .caller)
        XCTAssertEqual(dictation.inserted, ["for later"])
        XCTAssertEqual(journal.records.map(\.outcome), [.dropped, .typed])
        XCTAssertEqual(controller.state.phase, .listening(.agent), "the newer take's, not the notice")
    }

    /// Words for the agent from a take the host has no record of are dropped, not typed, when the
    /// agent cannot take them: what started it is unknown, so it may have been the wake word.
    func testAnAgentTakeOfUnknownOriginIsDroppedNotTyped() {
        let controller = makeController()
        brain.push(status: "running", requestId: "other")
        dictation.finish("from nowhere", take: UUID(), at: .caller)
        XCTAssertTrue(dictation.inserted.isEmpty, "nothing is typed")
        XCTAssertTrue(brain.submitted.isEmpty)
        XCTAssertTrue(journal.records.isEmpty, "there is no take to journal")
        XCTAssertEqual(lines("take dropped"), [
            "take dropped (Heard you, but the agent is still working), 12 characters: a take this host has no record of",
        ])
        XCTAssertFalse(logged.contains { $0.contains("nowhere") }, "never the words")
        withExtendedLifetime(controller) {}
    }

    func testTakesThrownAwayAreJournaledWithWhy() async {
        let controller = makeController()
        // Nothing heard by the endpointer.
        controller.perform(.orbClicked)
        levels(0.01, from: 0, to: 10.1)
        // Words that came out empty.
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        controller.perform(.stop)
        dictation.finish("  ")
        await settled(controller)
        // Cancelled.
        controller.perform(.start(.dictation), trigger: .socket(action: "dictate"))
        controller.perform(.cancel)
        // A discarded fn tap.
        keys.send(.begin(.primary))
        keys.send(.discard)
        // Failed.
        controller.perform(.orbClicked)
        dictation.onUpdate?(dictation.takeID, .failed(.tooShort))
        XCTAssertEqual(journal.records.map(\.outcome), [.nothingHeard, .nothingHeard, .cancelled, .cancelled, .failed])
        XCTAssertEqual(journal.records.map(\.end), [.nothingHeard, .stop, .cancelled, .cancelled, .failed])
        XCTAssertEqual(journal.records.last?.reason, "Recording too short")
        XCTAssertEqual(journal.records.compactMap(\.characters), [], "nothing was sent or typed")
    }

    func testTakesThatNeverStartAreJournaledAsRefused() {
        var settings = VoiceHostSettings()
        settings.brainEnabled = false
        let controller = makeController(settings)
        controller.perform(.orbClicked)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.brainOff))
        settings.brainEnabled = true
        controller.apply(settings)
        dictation.unavailable = .modelMissing(recordingKept: false)
        controller.perform(.start(.dictation), trigger: .socket(action: "dictate"))
        XCTAssertEqual(journal.records.map(\.outcome), [.refused, .refused])
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.brainOff, VoiceHostController.modelMissing])
        XCTAssertEqual(journal.records.map(\.trigger), [.orb, .socket(action: "dictate")])
        XCTAssertEqual(journal.records.compactMap(\.seconds), [])
    }

    func testATurnTheBrainRefusesIsJournaledAsRefused() async {
        let controller = makeController()
        brain.submitError = AgentSessionError.server(409, "turn already active")
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        controller.perform(.stop)
        dictation.finish("hello")
        await settled(controller)
        XCTAssertEqual(journal.records.map(\.outcome), [.refused])
        XCTAssertEqual(journal.records.last?.characters, 5)
        XCTAssertEqual(journal.records.last?.reason, "The brain did not take the turn (409)")
        XCTAssertEqual(journal.records.last?.end, .stop)
        XCTAssertFalse(logged.contains { $0.contains("turn already active") }, "never the brain's own words: \(logged)")
    }

    func testAWakeThatStartsNoTakeIsJournaledWithItsScore() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        // Detections the listener delivers after it was told to stop start nothing.
        controller.perform(.setMuted(true))
        wake.detect(score: 0.611)
        XCTAssertTrue(dictation.starts.isEmpty)
        XCTAssertEqual(controller.state.phase, .idle, "nothing shows on the orb")
        settings.voice.wakeWordEnabled = false
        controller.perform(.setMuted(false))
        controller.apply(settings)
        wake.detect(score: 0.702)
        XCTAssertTrue(dictation.starts.isEmpty)
        settings.voice.wakeWordEnabled = true
        controller.apply(settings)
        // A take already recording keeps going.
        controller.perform(.orbClicked)
        wake.detect(score: 0.85)
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        controller.perform(.cancel)
        // A detection of another phrase (a listener replaced since) starts nothing and leaves the
        // running listener alone.
        let starts = wake.starts.count
        wake.detect(score: 0.9, phrase: "Hey Computer")
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertEqual(wake.starts.count, starts)
        XCTAssertEqual(journal.records.filter { $0.outcome == .refused }.map(\.reason),
                       [VoiceHostController.voiceMuted, VoiceHostController.wakeOff, VoiceHostController.takeRecording,
                        VoiceHostController.otherWakePhrase])
        XCTAssertEqual(journal.records.filter { $0.outcome == .refused }.map(\.trigger),
                       [.wake(score: 0.611, phrase: "Hey Jarvis", frames: 2, peak: 0.611), .wake(score: 0.702, phrase: "Hey Jarvis", frames: 2, peak: 0.702),
                        .wake(score: 0.85, phrase: "Hey Jarvis", frames: 2, peak: 0.85), .wake(score: 0.9, phrase: "Hey Computer", frames: 2, peak: 0.9)])
        XCTAssertEqual(lines("take refused").count, 4, "\(logged)")
        XCTAssertTrue(confirmer.heard.isEmpty, "refused before its phrase was confirmed")
        XCTAssertTrue(lines("take refused").first?.contains("score 0.611") == true, "\(logged)")
    }

    func testALateDetectionTouchesNothingButTheJournal() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        settings.voice.speakReplies = true
        let controller = makeController(settings)
        await startTurn(controller, "first")
        brain.push(status: "running", output: "Working on it.")
        controller.perform(.start(.dictation), trigger: .socket(action: "dictate"))
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
        let before = controller.state
        let stops = speaker.stops
        let records = journal.records.count
        let starts = wake.starts.count
        wake.detect()
        XCTAssertEqual(controller.state, before, "the phase, the card and the orb are as they were")
        XCTAssertEqual(speaker.stops, stops, "the reply's speech is untouched")
        XCTAssertEqual(wake.starts.count, starts)
        XCTAssertEqual(journal.records.count, records + 1)
        XCTAssertEqual(journal.records.last?.outcome, .refused)
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.takeRecording)
        XCTAssertEqual(lines("take refused").count, 1)
    }

    func testTakesBeingTranscribedKeepTheirOwnOutcome() {
        let controller = makeController()
        brain.push(status: "running", requestId: "other")
        keys.send(.begin(.primary))
        let first = dictation.takeID
        keys.send(.retarget(.alternate))
        keys.send(.end)
        XCTAssertEqual(controller.state.phase, .transcribing(.dictation))
        keys.send(.begin(.primary))
        let second = dictation.takeID
        keys.send(.end)
        XCTAssertNotEqual(first, second)
        dictation.finish("first", take: first, at: .cursor)
        XCTAssertEqual(controller.state.phase, .transcribing(.dictation), "the orb follows the newer take")
        dictation.finish("second", take: second, at: .cursor)
        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertEqual(journal.records.map(\.outcome), [.typed, .typed])
        XCTAssertEqual(journal.records.map(\.reason), [VoiceHostController.agentBusyPasted, nil])
        XCTAssertEqual(journal.records.map(\.characters), [5, 6])
        XCTAssertEqual(journal.records.map(\.trigger), [.key(.primary, retargeted: true), .key(.primary, retargeted: false)])
    }

    func testTakesInFlightWhenTheHostQuitsAreJournaledAsCancelled() async {
        let controller = makeController()
        controller.perform(.start(.dictation), trigger: .socket(action: "dictate"))
        controller.perform(.stop)
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        controller.perform(.stop)
        dictation.finish("hello")
        controller.perform(.start(.dictation), trigger: .orb)
        XCTAssertTrue(journal.records.isEmpty)
        controller.prepareToQuit()
        // The brain takes the turn after the host began to quit; the cancelled line stands.
        await settled(controller)
        dictation.cancel()
        XCTAssertEqual(journal.records.map(\.outcome), [.cancelled, .cancelled, .cancelled])
        XCTAssertEqual(Set(journal.records.compactMap(\.reason)), [VoiceHostController.hostQuit])
        XCTAssertEqual(Set(journal.records.map(\.trigger.summary)),
                       ["socket action dictate", "socket action ask", "orb"])
        XCTAssertEqual(journal.records.first { $0.trigger == .socket(action: "ask") }?.characters, 5)
    }

    func testATurnTheBrainTookBeforeTheQuitStaysSent() async {
        let controller = makeController()
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        controller.perform(.stop)
        dictation.finish("hello")
        await settled(controller)
        controller.prepareToQuit()
        XCTAssertEqual(journal.records.map(\.outcome), [.sent])
    }

    func testTheLogTellsEachTakeWithoutItsWords() async throws {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        wake.detect(peak: 0.991)
        speak(from: 0, to: 1)
        dictation.partial("the secret plan")
        clock.now = 1
        controller.perform(.stop)
        dictation.finish("the secret plan")
        await settled(controller)
        XCTAssertEqual(lines("take started"), [#"take started: wake word "Hey Jarvis" (score 0.973, 2 frames, peak 0.991, confirmed in 0 ms), agent, "#
                        + "hands-free"])
        let ended = try XCTUnwrap(lines("take ended").first)
        XCTAssertTrue(ended.hasPrefix("take ended: stop"), ended)
        XCTAssertTrue(ended.contains("floor"), ended)
        XCTAssertTrue(ended.contains("threshold"), ended)
        XCTAssertEqual(lines("take sent"),
                       [#"take sent, 15 characters: wake word "Hey Jarvis" (score 0.973, 2 frames, peak 0.991, confirmed in 0 ms), "#
                        + "agent, take 1.0 s ended by stop"])
        XCTAssertFalse(logged.contains { $0.contains("secret") }, "\(logged)")
    }

    func testASpokenTurnKeepsWhatStartedItAndWhen() async throws {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        clock.now = 7
        wake.detect()
        clock.now = 9
        controller.perform(.stop)
        dictation.finish("what is on today")
        await settled(controller)
        brain.push(status: "idle", output: "Nothing.")
        let row = try XCTUnwrap(controller.conversation.rows.first)
        XCTAssertEqual(row.kind, .user)
        XCTAssertEqual(row.trigger, .wake(score: 0.973, phrase: "Hey Jarvis", frames: 2, peak: 0.973, confirmed: true,
                                          confirmMs: 0))
        XCTAssertEqual(row.date, date(at: 7), "when the take started")

        clock.now = 30
        XCTAssertNil(controller.send(typed: "and tomorrow?"))
        await settled(controller)
        let typed = try XCTUnwrap(controller.conversation.rows.last { $0.kind == .user })
        XCTAssertEqual(typed.source, .typed)
        XCTAssertEqual(typed.date, date(at: 30))
        XCTAssertNil(typed.trigger)
        XCTAssertEqual(journal.records.count, 1, "a typed turn is not a take")
    }

    // MARK: Presentation

    func testFullScreenHidesTheOrbAndKeepsTheWindowThatDidIt() {
        let controller = makeController()
        let safari = VoiceFullScreenEvidence(id: 4321, pid: 567, app: "Safari",
                                             frame: VoiceRect(CGRect(x: 0, y: 0, width: 2560, height: 1440)), layer: 0)
        controller.setHiddenForFullScreen(true, evidence: safari)
        XCTAssertTrue(controller.state.hiddenForFullScreen)
        XCTAssertEqual(presenter.states.last?.hiddenForFullScreen, true)
        XCTAssertEqual(controller.fullScreenEvidence, safari)
        XCTAssertEqual(presenter.evidenceAtRender.last, safari, "the presenter has it when it renders the hide")
        controller.setHiddenForFullScreen(false, evidence: safari)
        XCTAssertFalse(controller.state.hiddenForFullScreen)
        XCTAssertNil(controller.fullScreenEvidence, "kept only while the orb is hidden")
        XCTAssertEqual(presenter.evidenceAtRender.last, .some(nil))
    }

    func testEveryChangeIsRendered() {
        let controller = makeController()
        var published: [VoiceHostState] = []
        controller.onStateChange = { published.append($0) }
        let before = presenter.states.count
        // The press arms the orb, the take starts recording, the level moves.
        keys.send(.begin(.primary))
        dictation.level(0.3)
        XCTAssertEqual(presenter.states.count, before + 3)
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(presenter.states.last, controller.state)
    }
}
