import SpeakFreeLib
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// `gesturePending`: from the fn press that begins a take until the gesture is decided, so the
/// orb can hold a neutral look instead of morphing into the waveform and back.
@MainActor
final class VoiceHostGestureTests: XCTestCase {
    private var dictation: FakeDictation!
    private var keys: FakeKeys!
    private var clock: ManualClock!
    private let window = KeyGestureRecognizer.Configuration().doubleTapWindow
    private let tapMax = KeyGestureRecognizer.Configuration().tapMaxDuration

    override func setUp() async throws {
        dictation = FakeDictation()
        keys = FakeKeys()
        clock = ManualClock()
    }

    private func makeController(keyMode: VoiceHostSettings.KeyMode = .toggle,
                                agentGesture: Bool = true) -> VoiceHostController {
        var settings = VoiceHostSettings()
        settings.keyMode = keyMode
        settings.agentGesture = agentGesture
        let clock = self.clock!
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: keys, brain: FakeBrain(), speaker: FakeSpeaker(),
            wake: nil, brainStateRoot: URL(fileURLWithPath: "/tmp/voice-tests/Brain"),
            detectRuntimes: FakeRuntimes.detect(), now: { clock.now }, schedule: { clock.schedule($0, $1) })
        controller.start()
        return controller
    }

    func testKeysGetTheRecognizerConfigurationTheControllerTimesWith() {
        _ = makeController()
        XCTAssertEqual(keys.configurations, [VoiceHostController.gestureConfiguration(alternateEnabled: true)])
    }

    func testATapIsPendingUntilItsDoubleTapWindowLapses() {
        let controller = makeController(keyMode: .toggle)
        keys.send(.begin(.primary))
        XCTAssertTrue(controller.state.gesturePending)
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
        clock.advance(to: 0.1)
        keys.release()
        clock.advance(to: 0.1 + window - 0.01)
        XCTAssertTrue(controller.state.gesturePending)
        clock.advance(to: 0.1 + window)
        XCTAssertFalse(controller.state.gesturePending)
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
    }

    func testTheSecondTapCommitsToTheAgent() {
        let controller = makeController(keyMode: .toggle)
        keys.send(.begin(.primary))
        clock.advance(to: 0.1)
        keys.release()
        clock.advance(to: 0.25)
        keys.send(.retarget(.alternate))
        XCTAssertFalse(controller.state.gesturePending)
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        // The lapsed window's timer leaves the decided gesture alone.
        clock.advance(to: 1)
        XCTAssertFalse(controller.state.gesturePending)
    }

    func testAPressHeldPastATapIsDictation() {
        for mode in [VoiceHostSettings.KeyMode.hold, .toggle] {
            clock = ManualClock()
            keys = FakeKeys()
            dictation = FakeDictation()
            let controller = makeController(keyMode: mode)
            keys.send(.begin(.primary))
            clock.advance(to: tapMax - 0.01)
            XCTAssertTrue(controller.state.gesturePending, "\(mode)")
            clock.advance(to: tapMax)
            XCTAssertFalse(controller.state.gesturePending, "\(mode)")
            XCTAssertEqual(controller.state.phase, .listening(.dictation))
        }
    }

    func testAReleaseAfterATapLengthDecidesAtOnce() {
        let controller = makeController(keyMode: .toggle)
        keys.send(.begin(.primary))
        // The tap-length timer has not run yet (a late main queue); the release is late anyway.
        clock.now = tapMax + 0.05
        keys.release()
        XCTAssertFalse(controller.state.gesturePending)
    }

    func testHoldModeQuickTapEndsWithTheRecognizersDiscard() {
        let controller = makeController(keyMode: .hold)
        keys.send(.begin(.primary))
        clock.advance(to: 0.1)
        keys.release()
        XCTAssertTrue(controller.state.gesturePending)
        keys.send(.discard)
        XCTAssertFalse(controller.state.gesturePending)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testEndClearsIt() {
        let controller = makeController(keyMode: .hold)
        keys.send(.begin(.primary))
        keys.send(.end)
        XCTAssertFalse(controller.state.gesturePending)
    }

    func testTheTakeEndingClearsIt() {
        let controller = makeController(keyMode: .toggle)
        keys.send(.begin(.primary))
        controller.perform(.cancel)
        XCTAssertFalse(controller.state.gesturePending)
        XCTAssertEqual(controller.state.phase, .idle)
    }

    func testNothingIsPendingWithoutTheAgentGesture() {
        let controller = makeController(agentGesture: false)
        keys.send(.begin(.primary))
        XCTAssertFalse(controller.state.gesturePending)
        XCTAssertEqual(controller.state.phase, .listening(.dictation))
    }

    func testARefusedTakeIsNotPending() {
        dictation.unavailable = .modelMissing(recordingKept: false)
        let controller = makeController()
        keys.send(.begin(.primary))
        XCTAssertFalse(controller.state.gesturePending)
    }

    func testAnEarlierGesturesTimerLeavesANewOneAlone() {
        let controller = makeController(keyMode: .hold)
        keys.send(.begin(.primary))
        clock.advance(to: 0.1)
        keys.release()
        keys.send(.discard)
        clock.advance(to: 0.15)
        keys.send(.begin(.primary))
        // The first gesture's timers (tap length at 0.2, window at 0.4) fire meanwhile.
        clock.advance(to: 0.15 + tapMax - 0.01)
        XCTAssertTrue(controller.state.gesturePending)
    }

    func testAnOrbOrSocketTakeIsNeverPending() {
        let controller = makeController()
        controller.perform(.start(.dictation))
        XCTAssertFalse(controller.state.gesturePending)
    }

    func testItIsOnTheWire() throws {
        let data = try JSONEncoder().encode(VoiceHostState(gesturePending: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["gesturePending"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostState.self, from: data).gesturePending, true)
    }
}
