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
    /// The take and wake-listener lines the controller logged.
    private var logged: [String] = []
    private var missingRuntimes: Set<String> = []
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
        logged = []
        missingRuntimes = []
    }

    private func makeController(_ settings: VoiceHostSettings = VoiceHostSettings(),
                                brain: BrainDriving?? = nil) -> VoiceHostController {
        let clock = self.clock!
        let fakeBrain = self.brain!
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: keys,
            brain: brain ?? self.brain, speaker: speaker, wake: wake,
            wakeModels: [WakePhraseModel(model: WakeModels.heyJarvis, store: wakeStore)], brainStateRoot: brainRoot,
            sessions: sessions, detectRuntimes: FakeRuntimes.detect(missing: missingRuntimes),
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
        let controller = makeController()
        brain.onHealthChanged?(.ready)
        XCTAssertNil(controller.state.brainProblem)
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

    func testWakeWhileATurnRunsIsRefused() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        await startTurn(controller)
        let starts = dictation.starts.count
        wake.detect(score: 0.61)
        XCTAssertEqual(dictation.starts.count, starts)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusy))
        let refused = try? XCTUnwrap(journal.records.last)
        XCTAssertEqual(refused?.outcome, .refused)
        XCTAssertEqual(refused?.reason, VoiceHostController.agentBusy)
        XCTAssertEqual(refused?.trigger, .wake(score: 0.61, phrase: "Hey Jarvis"))
        XCTAssertNil(refused?.seconds, "it never recorded")
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

    func testWakeStartsAnAgentTakeAndPausesWhileRecording() async {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        XCTAssertTrue(controller.state.wakeListening)
        wake.detect()
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertFalse(wake.listening)
        controller.perform(.stop)
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.973, phrase: "Hey Jarvis"))
        dictation.finish("hello")
        await settled(controller)
        XCTAssertTrue(wake.listening)
    }

    func testWakeListensAgainWhenNoTakeStarts() {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        settings.brainEnabled = false
        let controller = makeController(settings)
        let starts = wake.starts.count
        wake.detect()
        XCTAssertEqual(controller.state.phase, .failed("The brain is off"))
        XCTAssertEqual(wake.starts.count, starts + 1)
        XCTAssertTrue(wake.listening)
        XCTAssertEqual(journal.records.map(\.outcome), [.refused])
        XCTAssertEqual(journal.records.last?.reason, VoiceHostController.brainOff)
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
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.912, phrase: "Hey Jarvis"))
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
            .orb, .socket(action: "ask"), .wake(score: 0.912, phrase: "Hey Jarvis"),
            .key(.primary, retargeted: false), .key(.primary, retargeted: true),
        ])
        XCTAssertEqual(journal.records.map(\.mode), [.agent, .agent, .agent, .dictation, .agent])
        XCTAssertEqual(controller.state.lastTakeEnd?.trigger, .wake(score: 0.912, phrase: "Hey Jarvis"),
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

    /// An agent take that finishes while the agent works is typed at the cursor; the journal says so and why.
    func testAWakeTakeThatFinishesWhileTheAgentWorksIsJournaledAsTyped() async throws {
        var settings = VoiceHostSettings()
        settings.voice.wakeWordEnabled = true
        let controller = makeController(settings)
        wake.detect()
        controller.perform(.stop)
        brain.push(status: "running", requestId: "other")
        dictation.finish("seventy seconds of an audiobook")
        await settled(controller)
        XCTAssertEqual(dictation.inserted, ["seventy seconds of an audiobook"])
        let record = try XCTUnwrap(journal.records.last)
        XCTAssertEqual(record.outcome, .typed)
        XCTAssertEqual(record.reason, VoiceHostController.agentBusyPasted)
        XCTAssertEqual(record.mode, .agent)
        XCTAssertEqual(record.characters, 31)
        XCTAssertEqual(record.trigger, .wake(score: 0.973, phrase: "Hey Jarvis"))
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
                       [.wake(score: 0.611, phrase: "Hey Jarvis"), .wake(score: 0.702, phrase: "Hey Jarvis"),
                        .wake(score: 0.85, phrase: "Hey Jarvis"), .wake(score: 0.9, phrase: "Hey Computer")])
        XCTAssertEqual(lines("take refused").count, 4, "\(logged)")
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
        wake.detect()
        speak(from: 0, to: 1)
        dictation.partial("the secret plan")
        clock.now = 1
        controller.perform(.stop)
        dictation.finish("the secret plan")
        await settled(controller)
        XCTAssertEqual(lines("take started"), [#"take started: wake word "Hey Jarvis" (score 0.973), agent, hands-free"#])
        let ended = try XCTUnwrap(lines("take ended").first)
        XCTAssertTrue(ended.hasPrefix("take ended: stop"), ended)
        XCTAssertTrue(ended.contains("floor"), ended)
        XCTAssertTrue(ended.contains("threshold"), ended)
        XCTAssertEqual(lines("take sent"),
                       [#"take sent, 15 characters: wake word "Hey Jarvis" (score 0.973), agent, take 1.0 s ended by stop"#])
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
        XCTAssertEqual(row.trigger, .wake(score: 0.973, phrase: "Hey Jarvis"))
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
        controller.setHiddenForFullScreen(false, evidence: safari)
        XCTAssertFalse(controller.state.hiddenForFullScreen)
        XCTAssertNil(controller.fullScreenEvidence, "kept only while the orb is hidden")
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
