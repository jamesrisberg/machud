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
    private var missingRuntimes: Set<String> = []
    private let brainRoot = URL(fileURLWithPath: "/tmp/voice-tests/Brain")

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
            now: { clock.now }, schedule: { clock.schedule($0, $1) })
        controller.presenter = presenter
        controller.start()
        return controller
    }

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

    func testOrbClickStartsAnAgentTakeThatEndsOnSilence() {
        let controller = makeController()
        controller.perform(.orbClicked)
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        clock.now = 0.1
        dictation.level(0.6)
        XCTAssertEqual(controller.state.inputLevel, 0.6)
        clock.now = 0.5
        dictation.level(0.01)
        XCTAssertEqual(dictation.stops, 0)
        clock.now = 2.0
        dictation.level(0.01)
        XCTAssertEqual(dictation.stops, 1)
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
        XCTAssertNil(controller.refusal(for: .dictation))
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
        missingRuntimes = ["claude", "mclaude"]
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
        wake.onWake?()
        XCTAssertEqual(dictation.starts.count, starts)
        XCTAssertEqual(controller.state.phase, .failed(VoiceHostController.agentBusy))
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
        XCTAssertEqual(controller.refusal(for: .dictation), VoiceHostController.voiceOff)
        settings.enabled = true
        controller.apply(settings)
        XCTAssertNil(controller.refusal(for: .agent))
        controller.perform(.setMuted(true))
        XCTAssertEqual(controller.refusal(for: .agent), VoiceHostController.voiceMuted)
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
        wake.onWake?()
        XCTAssertEqual(dictation.starts, [.caller])
        XCTAssertFalse(wake.listening)
        controller.perform(.stop)
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
        wake.onWake?()
        XCTAssertEqual(controller.state.phase, .failed("The brain is off"))
        XCTAssertEqual(wake.starts.count, starts + 1)
        XCTAssertTrue(wake.listening)
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

    // MARK: Presentation

    func testFullScreenHidesTheOrb() {
        let controller = makeController()
        controller.setHiddenForFullScreen(true)
        XCTAssertTrue(controller.state.hiddenForFullScreen)
        XCTAssertEqual(presenter.states.last?.hiddenForFullScreen, true)
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
