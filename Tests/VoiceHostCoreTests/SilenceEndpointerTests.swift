import XCTest
@testable import VoiceHostCore

final class SilenceEndpointerTests: XCTestCase {
    func testSilenceBeforeSpeechNeverEnds() {
        var endpointer = SilenceEndpointer(maximum: 30)
        for step in 0..<100 {
            XCTAssertFalse(endpointer.observe(level: 0.01, at: Double(step) * 0.1))
        }
    }

    func testEndsAfterSilenceOnceSpeechWasHeard() {
        var endpointer = SilenceEndpointer()
        XCTAssertFalse(endpointer.observe(level: 0.5, at: 0))
        XCTAssertFalse(endpointer.observe(level: 0.4, at: 0.5))
        XCTAssertFalse(endpointer.observe(level: 0.01, at: 0.75))
        XCTAssertFalse(endpointer.observe(level: 0.01, at: 1.75))
        XCTAssertTrue(endpointer.observe(level: 0.01, at: 2.0))
    }

    func testSpeechResetsTheSilenceClock() {
        var endpointer = SilenceEndpointer()
        _ = endpointer.observe(level: 0.5, at: 0)
        _ = endpointer.observe(level: 0.01, at: 0.25)
        _ = endpointer.observe(level: 0.5, at: 1.0)
        XCTAssertFalse(endpointer.observe(level: 0.01, at: 1.25))
        XCTAssertFalse(endpointer.observe(level: 0.01, at: 2.25))
        XCTAssertTrue(endpointer.observe(level: 0.01, at: 2.5))
    }

    func testMaximumLengthEndsTheTake() {
        var endpointer = SilenceEndpointer(maximum: 5)
        XCTAssertFalse(endpointer.observe(level: 0.5, at: 0))
        XCTAssertFalse(endpointer.observe(level: 0.5, at: 4.9))
        XCTAssertTrue(endpointer.observe(level: 0.5, at: 5))
    }

    func testMaximumCountsFromTheFirstObservation() {
        var endpointer = SilenceEndpointer(maximum: 5)
        XCTAssertFalse(endpointer.observe(level: 0.01, at: 100))
        XCTAssertTrue(endpointer.observe(level: 0.01, at: 105))
    }
}
