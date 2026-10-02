import XCTest
@testable import VoiceHostCore

/// Levels arrive every 50 ms, as SpeakFree reports them. `EndpointerScenarioTests` runs the
/// endpointer against jittered traces; these pin each rule on simple ones.
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
    /// Words: 0.4 s at 0.5 with a 0.1 s gap at the start of every half second.
    private let speech = { (t: Double) in (t + 1e-9).truncatingRemainder(dividingBy: 0.5) < 0.1 ? 0.01 : 0.5 }

    func testDefaults() {
        let endpointer = SilenceEndpointer()
        XCTAssertEqual(endpointer.pause, 2)
        XCTAssertEqual(endpointer.maximum, 120)
        XCTAssertTrue(endpointer.automatic)
    }

    func testSilenceBeforeSpeechEndsOnlyAsNothingHeard() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 9.95, quietRoom))
        let end = try XCTUnwrap(feed(&endpointer, from: 9.95, to: 20, quietRoom))
        XCTAssertEqual(end.ending, .nothingHeard)
        XCTAssertEqual(end.at, 10, accuracy: 0.001)
    }

    /// Loud talking with no quiet frame at all gives the floor nothing to go by, so the threshold
    /// never confirms it; levels above the absolute minimum keep it from being thrown away, and
    /// from 10 s it ends by a pause (on a trace this smooth, possibly before the talking stops).
    func testSpeechTheThresholdMissedIsNotThrownAway() throws {
        var endpointer = SilenceEndpointer()
        let steady = { (t: Double) in 0.65 + 0.25 * sin(t * 23) }
        let end = try XCTUnwrap(feed(&endpointer, from: 0, to: 12, steady) ?? feed(&endpointer, from: 12, to: 30, quietRoom))
        XCTAssertEqual(end.ending, .pause)
        XCTAssertGreaterThan(end.at, 10)
    }

    func testAPartialWithWordsIsEvidenceOfSpeech() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 2.3, quietRoom))
        endpointer.observe(partial: "Hello there.", at: 2.3)
        let end = try XCTUnwrap(feed(&endpointer, from: 2.3, to: 30, quietRoom))
        XCTAssertEqual(end.ending, .pause, "not thrown away")
        XCTAssertEqual(end.at, 10, accuracy: 0.001, "the quiet already lasts longer than the pause")
    }

    func testManualNeverEndsOnSilence() {
        var endpointer = SilenceEndpointer(settings: settings(endOfTurn: .manual))
        XCTAssertFalse(endpointer.automatic)
        XCTAssertNil(feed(&endpointer, from: 0, to: 20, quietRoom), "nothing heard is for automatic takes")
        feed(&endpointer, from: 20, to: 22, speech)
        endpointer.observe(partial: "That's it.", at: 22)
        XCTAssertNil(feed(&endpointer, from: 22, to: 100, quietRoom))
    }

    func testEndsAfterThePauseOnceAFinishedSentenceWasHeard() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 0.3, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 0.3, to: 2, speech))
        endpointer.observe(partial: "Turn on the desk lamp.", at: 2)
        let end = try XCTUnwrap(feed(&endpointer, from: 2, to: 10, quietRoom))
        XCTAssertEqual(end.ending, .pause)
        XCTAssertEqual(end.at, 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(endpointer.quiet(at: end.at)), 2, accuracy: 0.001)
    }

    func testANaturalPauseMidTakeDoesNotEndItAtDefaults() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 0.3, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 0.3, to: 2, speech))
        endpointer.observe(partial: "Open the notes for today.", at: 2)
        XCTAssertNil(feed(&endpointer, from: 2, to: 3.5, quietRoom), "a 1.5 s pause is thinking, not the end")
        XCTAssertNil(feed(&endpointer, from: 3.5, to: 5, speech))
        endpointer.observe(partial: "Open the notes for today. The second one.", at: 5)
        let end = try XCTUnwrap(feed(&endpointer, from: 5, to: 15, quietRoom))
        XCTAssertEqual(end.at, 7, accuracy: 0.001)
    }

    func testThePauseSettingSetsTheWait() throws {
        var endpointer = SilenceEndpointer(settings: settings(pause: 3.5))
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Done.", at: 1)
        let end = try XCTUnwrap(feed(&endpointer, from: 1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.5, accuracy: 0.001)
    }

    func testATrailingConjunctionExtendsThePause() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Move the browser to the left and", at: 1)
        let end = try XCTUnwrap(feed(&endpointer, from: 1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.5, accuracy: 0.001, "2 s plus 1.5 s of grace")
        XCTAssertTrue(endpointer.unfinished(at: end.at))
    }

    func testFinishingTheSentenceDropsTheGrace() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Play something, um", at: 1)
        XCTAssertNil(feed(&endpointer, from: 1, to: 2.5, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2.5, to: 3.5, speech))
        endpointer.observe(partial: "Play something, um, calm.", at: 3.5)
        let end = try XCTUnwrap(feed(&endpointer, from: 3.5, to: 10, quietRoom))
        XCTAssertEqual(end.at, 5.5, accuracy: 0.001)
    }

    /// Speech heard after the latest partial is not in it yet: the words may not be finished.
    func testSpeechAfterTheLatestPartialExtendsThePause() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Close the window.", at: 0.8)
        XCTAssertNil(feed(&endpointer, from: 1, to: 2, speech))
        XCTAssertNil(feed(&endpointer, from: 2, to: 5.45, quietRoom), "2 s plus the grace")
        let end = try XCTUnwrap(feed(&endpointer, from: 5.45, to: 10, quietRoom))
        XCTAssertEqual(end.at, 5.5, accuracy: 0.001)
    }

    func testAPartialThatCatchesUpEndsTheTakeAfterThePause() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 2, speech)
        endpointer.observe(partial: "Close the", at: 1.2)
        XCTAssertNil(feed(&endpointer, from: 2, to: 3, quietRoom))
        endpointer.observe(partial: "Close the window.", at: 3)
        let end = try XCTUnwrap(feed(&endpointer, from: 3, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4, accuracy: 0.001)
    }

    /// No partial yet: the grace lasts until one would have arrived (streaming sends its first
    /// about 2.3 s in), so a host without streaming does not wait the extra 1.5 s on every take.
    func testWithoutPartialsTheGraceLastsUntilOneIsExpected() throws {
        var short = SilenceEndpointer()
        feed(&short, from: 0, to: 0.5, speech)
        let shortEnd = try XCTUnwrap(feed(&short, from: 0.5, to: 10, quietRoom))
        XCTAssertEqual(shortEnd.at, 3, accuracy: 0.001, "held from 2.5 s to 3 s")

        var long = SilenceEndpointer()
        feed(&long, from: 0, to: 2.5, speech)
        let longEnd = try XCTUnwrap(feed(&long, from: 2.5, to: 10, quietRoom))
        XCTAssertEqual(longEnd.at, 4.5, accuracy: 0.001, "no grace once a partial was due")
    }

    func testUnfinishedSentences() {
        for text in ["and", "I need the file and", "but", "so", "because", "or", "um", "Uh", "like",
                     "open the", "a", "go to", "with", "first,", "I think, um.", "the  ", "wait —"] {
            XCTAssertTrue(SilenceEndpointer.isUnfinished(text), text)
        }
        for text in ["", "Turn it off.", "What time is it?", "Hello", "and that is all", "Brand", "sand"] {
            XCTAssertFalse(SilenceEndpointer.isUnfinished(text), text)
        }
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

    func testABriefSpikeBeforeSpeechIsNotSpeech() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, quietRoom)
        feed(&endpointer, from: 1, to: 1.1) { _ in 0.9 }
        let end = try XCTUnwrap(feed(&endpointer, from: 1.1, to: 30, quietRoom))
        XCTAssertEqual(end.ending, .nothingHeard, "a click is not speech")
    }

    func testABriefSpikeInAPauseDoesNotRestartTheClock() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Close it.", at: 1)
        XCTAssertNil(feed(&endpointer, from: 1, to: 2, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2, to: 2.1) { _ in 0.9 })
        let end = try XCTUnwrap(feed(&endpointer, from: 2.1, to: 10, quietRoom))
        XCTAssertEqual(end.at, 3, accuracy: 0.001)
    }

    func testSustainedSpeechRestartsTheClock() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 1, speech)
        endpointer.observe(partial: "Close it.", at: 1)
        XCTAssertNil(feed(&endpointer, from: 1, to: 2, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2, to: 2.3, speech))
        endpointer.observe(partial: "Close it. Now.", at: 2.3)
        let end = try XCTUnwrap(feed(&endpointer, from: 2.3, to: 10, quietRoom))
        XCTAssertEqual(end.at, 4.3, accuracy: 0.001)
    }

    /// Between the marks nothing changes: speech stays speech until the level drops below the
    /// lower mark.
    func testHysteresisKeepsSpeechThroughSoftDips() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 0.3, quietRoom)
        feed(&endpointer, from: 0.3, to: 1, speech)
        let between = (endpointer.threshold + endpointer.quietThreshold) / 2
        XCTAssertGreaterThan(endpointer.threshold, endpointer.quietThreshold)
        XCTAssertNil(feed(&endpointer, from: 1, to: 2) { _ in between })
        XCTAssertNil(endpointer.quiet(at: 2), "still speaking")
        endpointer.observe(partial: "Done.", at: 2)
        let end = try XCTUnwrap(feed(&endpointer, from: 2, to: 12, quietRoom))
        XCTAssertEqual(end.at, 4, accuracy: 0.001)
    }

    /// A soft frame between the marks does not restart the count toward speech, so resuming after
    /// a quiet moment needs 150 ms near the threshold, not 150 ms strictly above it.
    func testASoftFrameDoesNotRestartTheCountTowardSpeech() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 0.3, quietRoom)
        feed(&endpointer, from: 0.3, to: 1, speech)
        endpointer.observe(partial: "Done.", at: 1)
        XCTAssertNil(feed(&endpointer, from: 1, to: 2.5, quietRoom))
        let threshold = endpointer.threshold
        let between = (threshold + endpointer.quietThreshold) / 2
        // Above, between, above, between: 150 ms without falling to quiet.
        let alternating = { (t: Double) in Int((t * 20).rounded()) % 2 == 0 ? threshold * 1.5 : between }
        XCTAssertNil(feed(&endpointer, from: 2.5, to: 2.7, alternating))
        XCTAssertNil(endpointer.quiet(at: 2.7), "speech resumed")
    }

    /// A noisy room (a fan, a café): noise around 0.15 on SpeakFree's scale, soft speech a
    /// little above it, falling to the noise for 100 ms between words. The take stays open
    /// through the speech and a thinking pause, and ends once the speaking stops.
    func testSoftSpeechInANoisyRoom() throws {
        let noise = { (t: Double) in 0.15 + 0.03 * sin(t * 37) + 0.015 * sin(t * 91) }
        let softSpeech = { (t: Double) -> Double in
            // Words of half a second with 100 ms gaps.
            t.truncatingRemainder(dividingBy: 0.6) > 0.5 ? noise(t) : 0.4 + 0.06 * sin(t * 23)
        }
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 0.5, noise))
        XCTAssertNil(feed(&endpointer, from: 0.5, to: 4, softSpeech))
        endpointer.observe(partial: "Find the invoice from March and", at: 4)
        XCTAssertNil(feed(&endpointer, from: 4, to: 5.5, noise))
        XCTAssertNil(feed(&endpointer, from: 5.5, to: 9, softSpeech))
        endpointer.observe(partial: "Find the invoice from March and send it to Sam.", at: 9)
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

    /// The floor is the trailing three seconds' lowest level: a fan that starts mid-take reads as
    /// speech until the quiet room has left the window, then lifts the floor, and the take ends.
    func testTheFloorFollowsARoomThatGetsLouder() throws {
        var endpointer = SilenceEndpointer()
        feed(&endpointer, from: 0, to: 0.3, quietRoom)
        feed(&endpointer, from: 0.3, to: 1.5, speech)
        endpointer.observe(partial: "Turn it down.", at: 1.5)
        let fan = { (_: Double) in 0.06 }
        // The last quiet frame (1.05 s, a gap between words) leaves the window after 4.05 s.
        XCTAssertNil(feed(&endpointer, from: 1.5, to: 5.5, fan))
        XCTAssertEqual(endpointer.floor, 0.072, accuracy: 0.001)
        endpointer.observe(partial: "Turn it down.", at: 5.5)
        let end = try XCTUnwrap(feed(&endpointer, from: 5.5, to: 15, fan))
        XCTAssertEqual(end.ending, .pause)
        XCTAssertEqual(end.at, 6.1, accuracy: 0.051, "2 s after the fan stopped reading as speech")
    }

    /// A loud first phrase with no quiet before it is not heard as speech (the floor has nothing
    /// lower to go by), but it cannot end the take either; the next words are heard.
    func testALoudStartDoesNotEndTheTake() throws {
        var endpointer = SilenceEndpointer()
        XCTAssertNil(feed(&endpointer, from: 0, to: 1.5) { t in 0.65 + 0.25 * sin(t * 23) })
        XCTAssertNil(feed(&endpointer, from: 1.5, to: 2, quietRoom))
        XCTAssertNil(feed(&endpointer, from: 2, to: 3) { _ in 0.2 })
        endpointer.observe(partial: "Lights off and the blinds down.", at: 3)
        let end = try XCTUnwrap(feed(&endpointer, from: 3, to: 10, quietRoom))
        XCTAssertEqual(end.at, 5, accuracy: 0.001)
        XCTAssertLessThan(endpointer.floor, 0.05)
    }
}
