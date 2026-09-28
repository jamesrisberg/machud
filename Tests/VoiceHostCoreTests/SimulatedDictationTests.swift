import XCTest
@testable import VoiceHostCore

@MainActor
final class SimulatedDictationTests: XCTestCase {
    func testHandsFreeTakeEndsOnSilenceAndReachesTheBrain() async {
        let clock = ManualClock()
        let dictation = SimulatedDictation(transcript: "simulated words", levelInterval: 0.25, speechDuration: 1,
                                           transcriptionDelay: 0.5, schedule: { clock.schedule($0, $1) })
        let brain = FakeBrain()
        let controller = VoiceHostController(
            settings: VoiceHostSettings(), dictation: dictation, keys: nil, brain: brain, speaker: nil, wake: nil,
            brainStateRoot: FileManager.default.temporaryDirectory, now: { clock.now },
            schedule: { clock.schedule($0, $1) })
        controller.start()
        controller.perform(.start(.agent))
        XCTAssertEqual(controller.state.phase, .listening(.agent))
        var time = 0.0
        while dictation.isCapturing, time < 10 {
            time += 0.25
            clock.advance(to: time)
        }
        XCTAssertEqual(time, 2.25, "a second of speech, then 1.2 s of silence at 0.25 s ticks")
        XCTAssertEqual(controller.state.phase, .transcribing(.agent))
        clock.advance(to: time + 0.5)
        await controller.pendingWork?.value
        XCTAssertEqual(brain.submitted.map(\.text), ["simulated words"])
        XCTAssertEqual(controller.state.phase, .working)
    }

    func testCancelStopsTheTake() {
        let clock = ManualClock()
        let dictation = SimulatedDictation(schedule: { clock.schedule($0, $1) })
        var updates: [DictationUpdate] = []
        dictation.onUpdate = { _, update in updates.append(update) }
        _ = dictation.start(.cursor)
        dictation.cancel()
        clock.advance(to: 5)
        XCTAssertEqual(updates, [.recording(.cursor), .failed(.cancelled)])
        XCTAssertFalse(dictation.isCapturing)
    }
}
