import BrainKit
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// The conversation behind the orb's card: the card's peek, pinned and expanded states, typed
/// turns, and the transcript the host keeps.
@MainActor
final class VoiceHostConversationTests: XCTestCase {
    private var dictation: FakeDictation!
    private var brain: FakeBrain!
    private var speaker: FakeSpeaker!
    private var presenter: RecordingPresenter!
    private var clock: ManualClock!
    private var store: FakeConversationStore!

    override func setUp() async throws {
        dictation = FakeDictation()
        brain = FakeBrain()
        speaker = FakeSpeaker()
        presenter = RecordingPresenter()
        clock = ManualClock()
        store = FakeConversationStore()
    }

    private func makeController(_ settings: VoiceHostSettings = VoiceHostSettings()) -> VoiceHostController {
        let clock = self.clock!
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: nil, brain: brain, speaker: speaker, wake: nil,
            brainStateRoot: URL(fileURLWithPath: "/tmp/voice-tests/Brain"), conversationStore: store,
            detectRuntimes: FakeRuntimes.detect(), now: { clock.now }, schedule: { clock.schedule($0, $1) })
        controller.presenter = presenter
        controller.start()
        return controller
    }

    private func settled(_ controller: VoiceHostController) async {
        await controller.pendingWork?.value
    }

    private func voiceTurn(_ controller: VoiceHostController, _ text: String) async {
        controller.perform(.start(.agent))
        controller.perform(.stop)
        dictation.finish(text)
        await settled(controller)
    }

    // MARK: Card states

    func testTheCardStartsAsAPeek() {
        XCTAssertEqual(makeController().state.cardMode, .peek)
    }

    func testHoverPinsTheCardAndLeavingUnpinsAfterAGrace() {
        let controller = makeController()
        controller.perform(.cardHovered(true))
        XCTAssertEqual(controller.state.cardMode, .pinned)
        controller.perform(.cardHovered(false))
        XCTAssertEqual(controller.state.cardMode, .pinned, "a short grace after leaving")
        clock.advance(to: VoiceHostController.pinGrace - 0.01)
        XCTAssertEqual(controller.state.cardMode, .pinned)
        clock.advance(to: VoiceHostController.pinGrace + 0.01)
        XCTAssertEqual(controller.state.cardMode, .peek)
    }

    func testComingBackWithinTheGraceKeepsItPinned() {
        let controller = makeController()
        controller.perform(.cardHovered(true))
        controller.perform(.cardHovered(false))
        clock.advance(to: VoiceHostController.pinGrace / 2)
        controller.perform(.cardHovered(true))
        clock.advance(to: VoiceHostController.pinGrace * 2)
        XCTAssertEqual(controller.state.cardMode, .pinned)
    }

    func testAClickExpandsAndEscOrTheScrimCollapses() {
        let controller = makeController()
        controller.perform(.cardHovered(true))
        controller.perform(.cardClicked)
        XCTAssertEqual(controller.state.cardMode, .expanded)
        controller.perform(.cardHovered(false))
        clock.advance(to: VoiceHostController.pinGrace * 2)
        XCTAssertEqual(controller.state.cardMode, .expanded, "hover does not fold the expanded panel")
        controller.perform(.setCardMode(.peek))
        XCTAssertEqual(controller.state.cardMode, .peek)
    }

    func testHoverDoesNotChangeTheExpandedPanel() {
        let controller = makeController()
        controller.perform(.setCardMode(.expanded))
        controller.perform(.cardHovered(true))
        XCTAssertEqual(controller.state.cardMode, .expanded)
    }

    func testDismissingTheCardReturnsToPeek() {
        let controller = makeController()
        controller.perform(.setCardMode(.expanded))
        controller.perform(.dismissCard)
        XCTAssertEqual(controller.state.cardMode, .peek)
    }

    func testVoiceKeepsWorkingWhileTheConversationIsExpanded() async {
        let controller = makeController()
        controller.perform(.setCardMode(.expanded))
        await voiceTurn(controller, "what's next")
        XCTAssertEqual(brain.submitted.map(\.text), ["what's next"])
        XCTAssertEqual(controller.state.cardMode, .expanded)
        XCTAssertEqual(controller.conversation.rows.first?.text, "what's next")
        XCTAssertEqual(controller.conversation.rows.first?.source, .voice)
    }

    // MARK: Typed turns

    func testATypedTurnGoesToTheSameSession() async {
        let controller = makeController()
        XCTAssertNil(controller.send(typed: "  list my files  "))
        await settled(controller)
        XCTAssertEqual(brain.submitted.map(\.text), ["list my files"])
        XCTAssertEqual(controller.state.phase, .working)
        XCTAssertEqual(controller.state.card?.prompt, "list my files")
        brain.push(status: "idle", output: "Three files.")
        XCTAssertEqual(controller.conversation.rows.map(\.text), ["list my files", "Three files."])
        XCTAssertEqual(controller.conversation.rows.first?.source, .typed)
        XCTAssertEqual(controller.state.card?.reply, "Three files.")
    }

    func testRepliesToTypedTurnsAreNotSpokenByDefault() async {
        var settings = VoiceHostSettings()
        settings.voice.speakReplies = true
        let controller = makeController(settings)
        _ = controller.send(typed: "hello")
        await settled(controller)
        brain.push(status: "running", output: "Hi there.")
        XCTAssertEqual(speaker.spoken, "")
    }

    func testRepliesToTypedTurnsAreSpokenWhenAskedFor() async {
        var settings = VoiceHostSettings()
        settings.speakTypedReplies = true
        let controller = makeController(settings)
        _ = controller.send(typed: "hello")
        await settled(controller)
        brain.push(status: "running", output: "Hi there.")
        XCTAssertEqual(speaker.spoken, "Hi there.")
    }

    func testATypedTurnWhileTheAgentWorksSaysItIsBusy() async {
        let controller = makeController()
        await voiceTurn(controller, "first")
        brain.push(status: "running", output: "Working")
        XCTAssertEqual(controller.send(typed: "second"), VoiceHostController.agentBusy)
        XCTAssertEqual(brain.submitted.map(\.text), ["first"])
        XCTAssertEqual(controller.state.phase, .working, "the running turn keeps its phase")
        XCTAssertEqual(controller.conversation.rows.map(\.text), ["first", "Working"])
    }

    func testATypedTurnIsRefusedWhileTheBrainIsOff() {
        var settings = VoiceHostSettings()
        settings.brainEnabled = false
        let controller = makeController(settings)
        XCTAssertEqual(controller.send(typed: "hello"), VoiceHostController.brainOff)
        XCTAssertTrue(brain.submitted.isEmpty)
    }

    func testATypedTurnIsRefusedWhileAnAgentTakeRecords() {
        let controller = makeController()
        controller.perform(.start(.agent))
        XCTAssertEqual(controller.send(typed: "hello"), VoiceHostController.takeRecording)
        XCTAssertTrue(brain.submitted.isEmpty)
    }

    func testAnEmptyTypedTurnIsRefused() {
        let controller = makeController()
        XCTAssertEqual(controller.send(typed: "  \n "), VoiceHostController.nothingToSend)
    }

    func testATypedTurnTheBrainRefusesLeavesNoUserRow() async {
        brain.submitError = AgentSessionError.server(409, "turn already active")
        let controller = makeController()
        XCTAssertNil(controller.send(typed: "hello"))
        await settled(controller)
        XCTAssertTrue(controller.conversation.rows.isEmpty)
        guard case .failed = controller.state.phase else { return XCTFail("\(controller.state.phase)") }
    }

    // MARK: Approvals

    func testAnswersAreMarkedInTheConversation() async {
        let controller = makeController()
        _ = controller.send(typed: "clean up")
        await settled(controller)
        brain.push(status: "approval", approvals: [AgentApproval(id: "a1", kind: "command", reason: "Delete")])
        XCTAssertEqual(controller.conversation.pendingApprovalIDs, ["a1"])
        controller.perform(.approve(id: "a1"))
        await settled(controller)
        XCTAssertEqual(brain.approvals.map(\.id), ["a1"])
        XCTAssertEqual(controller.conversation.rows.last?.decision, .delivering)
        brain.push(status: "running")
        XCTAssertEqual(controller.conversation.rows.last?.decision, .allowed)
    }

    // MARK: Presenter and persistence

    func testThePresenterGetsTheConversation() async {
        let controller = makeController()
        _ = controller.send(typed: "hello")
        await settled(controller)
        brain.push(status: "idle", output: "Hi")
        XCTAssertEqual(presenter.conversations.last?.map(\.text), ["hello", "Hi"])
    }

    func testTheConversationIsKeptAndComesBackAfterARestart() async {
        let controller = makeController()
        _ = controller.send(typed: "hello")
        await settled(controller)
        brain.push(status: "running", output: "H")
        brain.push(status: "idle", output: "Hi")
        XCTAssertEqual(store.saved.last?.rows.map(\.text), ["hello", "Hi"], "a finished turn is saved at once")
        XCTAssertEqual(store.saved.last?.threadId, "thread")

        let restarted = makeController()
        XCTAssertEqual(restarted.conversation.rows.map(\.text), ["hello", "Hi"])
        XCTAssertEqual(restarted.state.card, VoiceCard(prompt: "hello", reply: "Hi"),
                       "hovering the orb peeks the last exchange after a restart")
        withExtendedLifetime(controller) {}
    }

    func testStreamingTextIsSavedAfterAPause() async {
        let controller = makeController()
        _ = controller.send(typed: "hello")
        await settled(controller)
        let saves = store.saved.count
        brain.push(status: "running", output: "Hi th")
        brain.push(status: "running", output: "Hi there")
        XCTAssertEqual(store.saved.count, saves)
        clock.advance(to: VoiceHostController.conversationSaveDelay + 0.01)
        XCTAssertEqual(store.saved.count, saves + 1)
        XCTAssertEqual(store.saved.last?.rows.last?.text, "Hi there")
    }

    func testANewSessionClearsTheConversation() async {
        let controller = makeController()
        _ = controller.send(typed: "hello")
        await settled(controller)
        brain.push(status: "idle", output: "Hi")
        let reset = FakeBrain.snapshot(status: "idle", output: "", progress: "", approvals: [], error: nil,
                                       requestId: nil, turnId: nil, threadId: "thread-2")
        brain.onSnapshot?(reset)
        XCTAssertTrue(controller.conversation.rows.isEmpty)
        XCTAssertEqual(store.saved.last?.rows.count, 0)
    }

    // MARK: Speech in step with the card

    private func spokenSettings() -> VoiceHostSettings {
        var settings = VoiceHostSettings()
        settings.voice.speakReplies = true
        return settings
    }

    func testTheVoiceWarmsUpWhenATurnThatWillBeSpokenIsSubmitted() async {
        let controller = makeController(spokenSettings())
        XCTAssertEqual(speaker.warmUps, 0)
        await voiceTurn(controller, "hello")
        XCTAssertEqual(speaker.warmUps, 1)
        brain.push(status: "idle", output: "Hi.")
        speaker.complete()
        _ = controller.send(typed: "and you?")
        await settled(controller)
        XCTAssertEqual(speaker.warmUps, 1, "a typed turn's reply is not spoken by default")
    }

    func testATypedTurnWarmsUpWhenItsReplyIsSpoken() async {
        var settings = VoiceHostSettings()
        settings.speakTypedReplies = true
        let controller = makeController(settings)
        _ = controller.send(typed: "hello")
        XCTAssertEqual(speaker.warmUps, 1)
        withExtendedLifetime(controller) {}
    }

    func testNothingWarmsUpWhenRepliesAreNotSpoken() async {
        let controller = makeController()
        await voiceTurn(controller, "hello")
        XCTAssertEqual(speaker.warmUps, 0)
    }

    func testThePeekRevealsTheReplyInStepWithTheVoice() async {
        let controller = makeController(spokenSettings())
        await voiceTurn(controller, "hello")
        let reply = "Hi there. How are you today?"
        brain.push(status: "running", output: reply)
        XCTAssertEqual(controller.state.card?.reply, reply, "the card keeps the whole reply")
        XCTAssertEqual(controller.state.card?.shownReply, "", "nothing before the voice starts")
        speaker.startChunk(0, 0..<9)
        XCTAssertEqual(controller.state.card?.shownReply, "Hi there.")
        speaker.startChunk(1, 9..<28)
        XCTAssertEqual(controller.state.card?.shownReply, reply)
        XCTAssertEqual(controller.conversation.rows.last?.text, reply, "the conversation is never paced")
        brain.push(status: "idle", output: reply + " Bye.")
        XCTAssertEqual(controller.state.card?.shownReply, reply)
        speaker.complete()
        XCTAssertEqual(controller.state.card?.shownReply, reply + " Bye.", "all of it once the voice is done")
        XCTAssertNil(controller.state.card?.spokenUpTo)
    }

    func testStoppingTheVoiceShowsTheWholeReply() async {
        let controller = makeController(spokenSettings())
        await voiceTurn(controller, "hello")
        brain.push(status: "running", output: "One. Two. Three.")
        speaker.startChunk(0, 0..<4)
        XCTAssertEqual(controller.state.card?.shownReply, "One.")
        controller.perform(.orbClicked)
        XCTAssertEqual(controller.state.card?.shownReply, "One. Two. Three.")
    }

    func testAFailedOrInterruptedTurnShowsTheWholeReply() async {
        let controller = makeController(spokenSettings())
        await voiceTurn(controller, "hello")
        brain.push(status: "running", output: "One. Two.")
        speaker.startChunk(0, 0..<4)
        brain.push(status: "interrupted", output: "One. Two.")
        XCTAssertEqual(controller.state.card?.shownReply, "One. Two.")
    }

    func testAReplyThatIsNotSpokenIsShownWhole() async {
        let controller = makeController()
        await voiceTurn(controller, "hello")
        brain.push(status: "running", output: "Hi there.")
        XCTAssertEqual(controller.state.card?.shownReply, "Hi there.")
        speaker.startChunk(0, 0..<2)
        XCTAssertEqual(controller.state.card?.shownReply, "Hi there.", "a preview's chunks do not pace the card")
    }

    func testAPreviewDuringAWaitingReplyLeavesTheReplyUnpacedAndUnspoken() async {
        let controller = makeController(spokenSettings())
        await voiceTurn(controller, "hello")
        brain.push(status: "running", output: "")
        XCTAssertEqual(controller.state.card?.spokenUpTo, 0)
        XCTAssertNil(controller.say("Testing the voice"))
        XCTAssertNil(controller.state.card?.spokenUpTo, "the preview's chunks do not pace the reply")
        speaker.startChunk(0, 0..<7)
        brain.push(status: "running", output: "Hi there.")
        XCTAssertEqual(controller.state.card?.shownReply, "Hi there.")
        XCTAssertEqual(speaker.spoken, "Testing the voice", "the reply is not spoken after the preview")
    }

    func testASpeakerThatReportsNoChunksDoesNotPaceTheCard() async {
        speaker.reportsChunks = false
        let controller = makeController(spokenSettings())
        await voiceTurn(controller, "hello")
        brain.push(status: "running", output: "Hi there.")
        XCTAssertEqual(controller.state.card?.shownReply, "Hi there.")
        XCTAssertEqual(speaker.spoken, "Hi there.", "still spoken")
    }

    func testFullScreenFoldsAnExpandedCardBackToThePeek() {
        let controller = makeController()
        controller.perform(.setCardMode(.expanded))
        controller.setHiddenForFullScreen(true)
        XCTAssertEqual(controller.state.cardMode, .peek)
        controller.setHiddenForFullScreen(false)
        XCTAssertEqual(controller.state.cardMode, .peek, "it does not come back and take the keyboard")
    }

    func testAChunkNeverHidesTextAlreadyShown() async {
        let controller = makeController(spokenSettings())
        await voiceTurn(controller, "hello")
        brain.push(status: "running", output: "One. Two.")
        speaker.startChunk(1, 5..<9)
        speaker.startChunk(0, 0..<4)
        XCTAssertEqual(controller.state.card?.shownReply, "One. Two.")
    }
}

/// The conversation file, in memory.
@MainActor
final class FakeConversationStore: ConversationStoring {
    var record: ConversationRecord?
    private(set) var saved: [ConversationRecord] = []

    func load() -> ConversationRecord? { record }
    func save(_ record: ConversationRecord) {
        saved.append(record)
        self.record = record
    }
}
