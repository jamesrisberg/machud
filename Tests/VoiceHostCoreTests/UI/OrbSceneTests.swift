import XCTest
@testable import VoiceHostCore

final class OrbSceneTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private let card = VoiceCard(prompt: "What's on my calendar?", reply: "Two meetings.")

    private func scene(_ state: VoiceHostState, at offset: TimeInterval = 0) -> OrbScene {
        var tracker = OrbSceneTracker()
        tracker.ingest(state, now: t0)
        return tracker.scene(now: t0.addingTimeInterval(offset))
    }

    // MARK: Phase mapping

    func testIdleIsARestingOrbThatBreathesAndFloats() {
        let s = scene(VoiceHostState())
        XCTAssertEqual(s.form, .orb)
        XCTAssertEqual(s.tint, .resting)
        XCTAssertEqual(s.motion, .idle)
        XCTAssertFalse(s.hidden)
        XCTAssertNil(s.card)
        XCTAssertNil(s.errorMessage)
    }

    func testMutedIdleIsDimmed() {
        XCTAssertEqual(scene(VoiceHostState(muted: true)).tint, .muted)
    }

    func testDictationStretchesIntoTheWaveform() {
        let listening = scene(VoiceHostState(phase: .listening(.dictation), inputLevel: 0.5))
        XCTAssertEqual(listening.form, .waveform)
        XCTAssertEqual(listening.motion, .bars)
        XCTAssertEqual(listening.tint, .dictation)
        let transcribing = scene(VoiceHostState(phase: .transcribing(.dictation)))
        XCTAssertEqual(transcribing.form, .waveform)
        XCTAssertEqual(transcribing.motion, .spinner)
    }

    func testAgentListeningStaysRoundAndPulsesInItsOwnTint() {
        let s = scene(VoiceHostState(phase: .listening(.agent), inputLevel: 0.4))
        XCTAssertEqual(s.form, .orb)
        XCTAssertEqual(s.motion, .pulse)
        XCTAssertEqual(s.tint, .agent)
        XCTAssertNotEqual(s.tint, scene(VoiceHostState(phase: .listening(.dictation))).tint)
    }

    // MARK: Armed (the fn gesture is undecided)

    func testAnUndecidedGestureIsArmedNotTheWaveform() {
        for phase in [VoicePhase.idle, .listening(.dictation)] {
            let s = scene(VoiceHostState(phase: phase, inputLevel: 0.4, gesturePending: true))
            XCTAssertEqual(s.form, .orb, "\(phase)")
            XCTAssertEqual(s.tint, .armed, "\(phase)")
            XCTAssertEqual(s.motion, .armed, "\(phase)")
            XCTAssertEqual(s.accessibilityStatus, "Listening")
        }
    }

    func testTheDecidedGestureCommits() {
        XCTAssertEqual(scene(VoiceHostState(phase: .listening(.dictation))).form, .waveform)
        let agent = scene(VoiceHostState(phase: .listening(.agent), gesturePending: true))
        XCTAssertEqual(agent.tint, .agent, "the agent is decided: no armed look")
        XCTAssertEqual(scene(VoiceHostState(phase: .failed("x"), gesturePending: true)).tint, .failed)
    }

    func testWorkingSpinsSubtly() {
        let s = scene(VoiceHostState(phase: .working))
        XCTAssertEqual(s.form, .orb)
        XCTAssertEqual(s.motion, .spin)
        XCTAssertEqual(s.tint, .working)
        XCTAssertEqual(scene(VoiceHostState(phase: .transcribing(.agent))).motion, .spin)
    }

    func testApprovalAndSpeakingBreathe() {
        XCTAssertEqual(scene(VoiceHostState(phase: .awaitingApproval)).tint, .approval)
        XCTAssertEqual(scene(VoiceHostState(phase: .awaitingApproval)).motion, .breathe)
        XCTAssertEqual(scene(VoiceHostState(phase: .speaking)).tint, .speaking)
        XCTAssertEqual(scene(VoiceHostState(phase: .speaking)).motion, .breathe)
    }

    func testFullScreenHidesEverything() {
        let s = scene(VoiceHostState(phase: .working, card: card, hiddenForFullScreen: true))
        XCTAssertTrue(s.hidden)
        XCTAssertNil(s.card)
    }

    func testEveryPhaseHasAnAccessibilityStatus() {
        let phases: [VoicePhase] = [.idle, .listening(.dictation), .listening(.agent), .transcribing(.dictation),
                                    .transcribing(.agent), .working, .awaitingApproval, .speaking, .failed("No mic")]
        let statuses = phases.map { scene(VoiceHostState(phase: $0)).accessibilityStatus }
        XCTAssertFalse(statuses.contains(""))
        XCTAssertEqual(Set(statuses).count, statuses.count - 1, "only the two transcribing phases share a status")
        XCTAssertEqual(scene(VoiceHostState(muted: true)).accessibilityStatus, "Muted")
        XCTAssertTrue(scene(VoiceHostState(phase: .failed("No mic"))).accessibilityStatus.contains("No mic"))
    }

    // MARK: Failure

    func testFailureShowsBrieflyThenRests() {
        let state = VoiceHostState(phase: .failed("Speech model not installed"))
        let now = scene(state)
        XCTAssertEqual(now.tint, .failed)
        XCTAssertEqual(now.errorMessage, "Speech model not installed")
        let later = scene(state, at: OrbSceneTracker.failureDisplay + 0.1)
        XCTAssertEqual(later.tint, .resting)
        XCTAssertNil(later.errorMessage)
    }

    func testARepeatedFailureStateDoesNotRestartTheClock() {
        var tracker = OrbSceneTracker()
        let state = VoiceHostState(phase: .failed("x"))
        tracker.ingest(state, now: t0)
        tracker.ingest(state, now: t0.addingTimeInterval(2))
        XCTAssertNil(tracker.scene(now: t0.addingTimeInterval(OrbSceneTracker.failureDisplay + 0.1)).errorMessage)
    }

    func testANewFailureMessageRestartsTheClock() {
        var tracker = OrbSceneTracker()
        tracker.ingest(VoiceHostState(phase: .failed("x")), now: t0)
        tracker.ingest(VoiceHostState(phase: .failed("y")), now: t0.addingTimeInterval(2))
        XCTAssertEqual(tracker.scene(now: t0.addingTimeInterval(OrbSceneTracker.failureDisplay + 0.1)).errorMessage, "y")
    }

    // MARK: Card

    func testCardShowsWhileTheBrainIsOnIt() {
        for phase: VoicePhase in [.working, .awaitingApproval, .speaking] {
            XCTAssertEqual(scene(VoiceHostState(phase: phase, card: card)).card, card, "\(phase)")
        }
    }

    func testCardIsHiddenWhileANewTakeRecords() {
        XCTAssertNil(scene(VoiceHostState(phase: .listening(.agent), card: card)).card)
        XCTAssertNil(scene(VoiceHostState(phase: .listening(.dictation), card: card)).card)
    }

    func testCardLingersAfterTheTurnThenFolds() {
        var tracker = OrbSceneTracker()
        tracker.ingest(VoiceHostState(phase: .speaking, card: card), now: t0)
        tracker.ingest(VoiceHostState(phase: .idle, card: card), now: t0)
        XCTAssertEqual(tracker.scene(now: t0.addingTimeInterval(1)).card, card)
        XCTAssertEqual(tracker.nextDeadline(now: t0.addingTimeInterval(1)), t0.addingTimeInterval(OrbSceneTracker.cardLinger))
        XCTAssertNil(tracker.scene(now: t0.addingTimeInterval(OrbSceneTracker.cardLinger + 0.1)).card)
    }

    func testAnIdleCardIsNotShownWithoutATurnOrHover() {
        XCTAssertNil(scene(VoiceHostState(phase: .idle, card: card)).card)
    }

    func testHoverOverTheRestingOrbPeeksTheLastCard() {
        var tracker = OrbSceneTracker()
        tracker.ingest(VoiceHostState(phase: .idle, card: card), now: t0)
        tracker.setHovering(true, now: t0)
        XCTAssertEqual(tracker.scene(now: t0).card, card)
        tracker.setHovering(false, now: t0.addingTimeInterval(5))
        XCTAssertEqual(tracker.scene(now: t0.addingTimeInterval(5.1)).card, card, "a short grace to reach the card")
        XCTAssertNil(tracker.scene(now: t0.addingTimeInterval(5 + OrbSceneTracker.hoverGrace + 0.1)).card)
    }

    func testHoverDoesNotPeekWhileDictating() {
        var tracker = OrbSceneTracker()
        tracker.ingest(VoiceHostState(phase: .listening(.dictation), card: card), now: t0)
        tracker.setHovering(true, now: t0)
        XCTAssertNil(tracker.scene(now: t0).card)
    }

    func testHoverWithoutACardShowsNothing() {
        var tracker = OrbSceneTracker()
        tracker.ingest(VoiceHostState(), now: t0)
        tracker.setHovering(true, now: t0)
        XCTAssertNil(tracker.scene(now: t0).card)
    }

    func testDismissedCardDisappearsAtOnce() {
        var tracker = OrbSceneTracker()
        tracker.ingest(VoiceHostState(phase: .speaking, card: card), now: t0)
        tracker.ingest(VoiceHostState(phase: .idle, card: nil), now: t0)
        XCTAssertNil(tracker.scene(now: t0).card)
        XCTAssertNil(tracker.nextDeadline(now: t0))
    }

    // MARK: Open session

    func testTheCardOffersTheSessionWhenThereIsOne() {
        let working = VoiceHostState(phase: .working, card: card, sessionKey: "claude:abc")
        XCTAssertEqual(scene(working).sessionLink, "Open Session")
        var named = working
        named.sessionProvider = "MechaHUD"
        XCTAssertEqual(scene(named).sessionLink, "Open in MechaHUD")
        XCTAssertNil(scene(VoiceHostState(phase: .working, card: card)).sessionLink)
        XCTAssertNil(scene(VoiceHostState(sessionKey: "claude:abc")).sessionLink, "no card, no button")
    }

    // MARK: Text

    func testLongRepliesKeepTheirTail() {
        let reply = String(repeating: "a", count: 2000) + " the end"
        let shown = OrbCardText.replyTail(reply, limit: 100)
        XCTAssertTrue(shown.hasPrefix("…"))
        XCTAssertTrue(shown.hasSuffix("the end"))
        XCTAssertLessThanOrEqual(shown.count, 101)
        XCTAssertEqual(OrbCardText.replyTail("short", limit: 100), "short")
    }

    func testProgressKeepsTheNewestLines() {
        XCTAssertEqual(OrbCardText.progressTail(["a", "b", "c", "d", "e"], limit: 3), ["c", "d", "e"])
        XCTAssertEqual(OrbCardText.progressTail(["a"], limit: 3), ["a"])
    }
}
