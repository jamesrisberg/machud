import XCTest
@testable import VoiceHostCore

/// Levels arrive every 50 ms, as SpeakFree reports them.
final class SilenceEndpointerTests: XCTestCase {
    private let frame = 0.05

    /// Feeds `level(t)` from `start` up to (not including) `end`; the time the take ended at
    /// and why, or nil while it stayed open.
    @discardableResult
    private func feed(_ endpointer: inout SilenceEndpointer, from start: Double, to end: Double,
                      _ level: (Double) -> Double) -> (at: Double, ending: SilenceEndpointer.Ending)? {
        var step = 0
        while true {
            let time = start + Double(step) * frame
            guard time < end - 1e-9 else { return nil }
            if let ending = endpointer.observe(level: level(time), at: time) { return (time, ending) }
            step += 1
        }
    }

    private func settings(pause: Double = 2, sensitivity: HandsFreeSettings.Sensitivity = .medium,
                          endOfTurn: HandsFreeSettings.EndOfTurn = .auto) -> HandsFreeSettings {
        HandsFreeSettings(endOfTurn: endOfTurn, pause: pause, sensitivity: sensitivity)
    }

    private let quietRoom = { (_: Double) in 0.01 }
    private let speech = { (_: Double) in 0.5 }

    func testDefaults() {
        let endpointer = SilenceEndpointer()
        XCTAssertEqual(endpointer.pause, 2)
        XCTAssertEqual(endpointer.maximum, 120)
        XCTAssertTrue(endpointer.automatic)
    }

    func testSilenceBeforeSpeechNeverEnds() {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 60, quietRoom))
    }

    func testEndsAfterThePauseOnceAFinishedSentenceWasHeard() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 0.3, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 0.3, to: 2, speech))
        endpointer.observe(partial: "Turn on the desk lamp.")
        let end = try XCTUnwrap(feed(&endpointer, from: 2, to: 10, quietRoom))
        XCTAssertEqual(end.ending, .pause)
        XCTAssertEqual(end.at, 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(endpointer.quiet(at: end.at)), 2, accuracy: 0.001)
    }

    func testANaturalPauseMidTakeDoesNotEndItAtDefaults() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 0.3, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 0.3, to: 2, speech))
        endpointer.observe(partial: "Open the notes for today.")
        XCTAssertNil(feed(&endpointer, from: 2, to: 3.5, quietRoom), "a 1.5 s pause is thinking, not the end")
        XCTAssertNil(feed(&endpointer, from: 3.5, to: 5, speech))
        let end = try XCTUnwrap(feed(&endpointer, from: 5, to: 15, quietRoom))
        XCTAssertEqual(end.at, 7, accuracy: 0.001)
    }

    func testThePauseSettingSetsTheWait() throws {
        var endpointer = SilenceEndpointer(settings: settings(pause: 3.5))
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Done.")
        let end = try XCTUnwrap(feed(&endpointer, from: 1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.5, accuracy: 0.001)
    }

    func testATrailingConjunctionExtendsThePause() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Move the browser to the left and")
        let end = try XCTUnwrap(feed(&endpointer, from: 1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.5, accuracy: 0.001, "2 s plus 1.5 s of grace")
        XCTAssertTrue(endpointer.unfinished)
    }

    func testFinishingTheSentenceDropsTheGrace() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Play something, um")
        XCTAssertNil(feed(&endpointer, from: 1, to: 2.5, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2.5, to: 3.5, speech))
        endpointer.observe(partial: "Play something, um, calm.")
        let end = try XCTUnwrap(feed(&endpointer, from: 3.5, to: 10, quietRoom))
        XCTAssertEqual(end.at, 5.5, accuracy: 0.001)
    }

    func testNoPartialYetExtendsThePause() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        let end = try XCTUnwrap(feed(&endpointer, from: 1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.5, accuracy: 0.001)
    }

    func testUnfinishedSentences() {
        for text in ["and", "I need the file and", "but", "so", "because", "or", "um", "Uh", "like",
                     "open the", "a", "go to", "with", "first,", "I think, um.", "the  ", "wait —"] {
            XCTAssertTrue(SilenceEndpointer.isUnfinished(text), text)
        }
        for text in ["Turn it off.", "What time is it?", "Hello", "and that is all", "Brand", "sand"] {
            XCTAssertFalse(SilenceEndpointer.isUnfinished(text), text)
        }
    }

    func testManualNeverEndsOnSilence() {
        var endpointer = SilenceEndpointer(settings: settings(endOfTurn: .manual))
        XCTAssertFalse(endpointer.automatic)
        feed(&endpointer, from: 0, to: 2, speech)
        endpointer.observe(partial: "That's it.")
        XCTAssertNil(feed(&endpointer, from: 2, to: 100, quietRoom))
    }

    func testMaximumIs120Seconds() throws {
        var endpointer = SilenceEndpointer()
        let end = try XCTUnwrap(feed(&endpointer, from: 0, to: 200, speech))
        XCTAssertEqual(end.ending, .maximum)
        XCTAssertEqual(end.at, 120, accuracy: 0.001)
    }

    func testMaximumAppliesWhenManualToo() throws {
        var endpointer = SilenceEndpointer(settings: settings(endOfTurn: .manual))
        let end = try XCTUnwrap(feed(&endpointer, from: 10, to: 200, quietRoom))
        XCTAssertEqual(end.ending, .maximum)
        XCTAssertEqual(end.at, 130, accuracy: 0.001, "counted from the first level")
    }

    func testABriefSpikeBeforeSpeechIsNotSpeech() {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, quietRoom)
        feed(&endpointer, from: 1, to: 1.1) { _ in 0.9 }
        XCTAssertNil(feed(&endpointer, from: 1.1, to: 30, quietRoom), "a click is not speech")
    }

    func testABriefSpikeInAPauseDoesNotRestartTheClock() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Close it.")
        XCTAssertNil(feed(&endpointer, from: 1, to: 2, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2, to: 2.1) { _ in 0.9 })
        let end = try XCTUnwrap(feed(&endpointer, from: 2.1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 3, accuracy: 0.001)
    }

    func testSustainedSpeechRestartsTheClock() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Close it.")
        XCTAssertNil(feed(&endpointer, from: 1, to: 2, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2, to: 2.3, speech))
        let end = try XCTUnwrap(feed(&endpointer, from: 2.3, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.3, accuracy: 0.001)
    }

    /// Between the marks nothing changes: speech stays speech until the level drops below the
    /// lower mark.
    func testHysteresisKeepsSpeechThroughSoftDips() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 0.3, quietRoom)
        feed(&endpointer, from: 0.3, to: 1, speech)
        endpointer.observe(partial: "Done.")
        let between = (endpointer.threshold + endpointer.quietThreshold) / 2
        XCTAssertGreaterThan(endpointer.threshold, endpointer.quietThreshold)
        XCTAssertNil(feed(&endpointer, from: 1, to: 6) { _ in between })
        let end = try XCTUnwrap(feed(&endpointer, from: 6, to: 12, quietRoom))
        XCTAssertEqual(end.at, 8, accuracy: 0.001)
    }

    /// A noisy room (a fan, a café): noise around 0.15 on SpeakFree's scale, soft speech a
    /// little above it with short dips between words. The take stays open through the speech
    /// and a thinking pause, and ends once the speaking stops.
    func testSoftSpeechInANoisyRoom() throws {
        let noise = { (t: Double) in 0.15 + 0.03 * sin(t * 37) + 0.015 * sin(t * 91) }
        let softSpeech = { (t: Double) -> Double in
            // Words of about half a second with 100 ms gaps that sink toward the noise.
            t.truncatingRemainder(dividingBy: 0.6) > 0.5 ? 0.26 : 0.36 + 0.06 * sin(t * 23)
        }
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 0.5, noise))
        XCTAssertNil(feed(&endpointer, from: 0.5, to: 4, softSpeech))
        endpointer.observe(partial: "Find the invoice from March and")
        XCTAssertNil(feed(&endpointer, from: 4, to: 5.5, noise))
        XCTAssertNil(feed(&endpointer, from: 5.5, to: 9, softSpeech))
        endpointer.observe(partial: "Find the invoice from March and send it to Sam.")
        let end = try XCTUnwrap(feed(&endpointer, from: 9, to: 30, noise))
        XCTAssertEqual(end.ending, .pause)
        XCTAssertEqual(end.at, 11, accuracy: 0.11)
        XCTAssertGreaterThan(endpointer.floor, 0.08, "the floor follows the room")
        XCTAssertLessThan(endpointer.floor, 0.2)
    }

    func testSensitivityMovesTheThreshold() {
        func threshold(_ sensitivity: HandsFreeSettings.Sensitivity, noise: Double) -> Double {
            var endpointer = SilenceEndpointer(settings: settings(sensitivity: sensitivity))
            feed(&endpointer, from: 0, to: 1) { _ in noise }
            return endpointer.threshold
        }
        for noise in [0.01, 0.12] {
            XCTAssertLessThan(threshold(.high, noise: noise), threshold(.medium, noise: noise))
            XCTAssertLessThan(threshold(.medium, noise: noise), threshold(.low, noise: noise))
        }
        XCTAssertGreaterThan(threshold(.medium, noise: 0.12), threshold(.medium, noise: 0.01),
                             "the threshold rises with the room")
    }

    /// Speaking straight away (after the wake word) puts speech into the first 300 ms: the floor
    /// estimate is capped, and falls back to the room at the first quiet.
    func testSpeechFromTheFirstFrameIsHeard() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 2, speech))
        endpointer.observe(partial: "Lights off.")
        let end = try XCTUnwrap(feed(&endpointer, from: 2, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4, accuracy: 0.001)
        XCTAssertLessThan(endpointer.floor, 0.05)
    }
}
