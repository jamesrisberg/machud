import XCTest
@testable import VoiceHostCore

final class OrbAnimatorTests: XCTestCase {
    private func scene(_ form: OrbForm, _ motion: OrbMotion = .none) -> OrbScene {
        OrbScene(hidden: false, form: form, tint: .resting, motion: motion, accessibilityStatus: "Ready")
    }

    func testStretchEasesTowardTheWaveformAndSettles() {
        var animator = OrbAnimator()
        animator.advance(dt: 1.0 / 60, scene: scene(.waveform), level: 0, reduceMotion: false)
        XCTAssertGreaterThan(animator.stretch, 0)
        XCTAssertLessThan(animator.stretch, 1)
        XCTAssertFalse(animator.isSettled(for: scene(.waveform)))
        for _ in 0..<60 { animator.advance(dt: 1.0 / 60, scene: scene(.waveform), level: 0, reduceMotion: false) }
        XCTAssertEqual(animator.stretch, 1)
        XCTAssertTrue(animator.isSettled(for: scene(.waveform)))
    }

    func testStretchShrinksBack() {
        var animator = OrbAnimator(stretch: 1)
        for _ in 0..<60 { animator.advance(dt: 1.0 / 60, scene: scene(.orb), level: 0, reduceMotion: false) }
        XCTAssertEqual(animator.stretch, 0)
    }

    func testReduceMotionJumpsAndFreezesPhases() {
        var animator = OrbAnimator()
        animator.advance(dt: 1.0 / 60, scene: scene(.waveform, .spinner), level: 0, reduceMotion: true)
        XCTAssertEqual(animator.stretch, 1)
        let phase = animator.phase
        animator.advance(dt: 1.0 / 60, scene: scene(.waveform, .spinner), level: 0, reduceMotion: true)
        XCTAssertEqual(animator.phase, phase)
        XCTAssertTrue(animator.isSettled(for: scene(.waveform, .spinner), reduceMotion: true))
    }

    func testMotionKeepsTheDriverRunning() {
        let animator = OrbAnimator()
        XCTAssertTrue(animator.isSettled(for: scene(.orb)))
        XCTAssertFalse(animator.isSettled(for: scene(.orb, .spin)))
        XCTAssertFalse(animator.isSettled(for: scene(.orb, .pulse)))
    }

    func testLevelAttacksFastAndReleasesSlowly() {
        var animator = OrbAnimator()
        animator.advance(dt: 1.0 / 60, scene: scene(.orb, .pulse), level: 1, reduceMotion: false)
        let attacked = animator.level
        XCTAssertGreaterThan(attacked, 0.5)
        animator.advance(dt: 1.0 / 60, scene: scene(.orb, .pulse), level: 0, reduceMotion: false)
        XCTAssertGreaterThan(animator.level, attacked * 0.4, "release is gentler than attack")
    }

    func testLevelIsClamped() {
        var animator = OrbAnimator()
        for _ in 0..<30 { animator.advance(dt: 1.0 / 60, scene: scene(.orb, .pulse), level: 7, reduceMotion: false) }
        XCTAssertLessThanOrEqual(animator.level, 1)
    }

    func testLevelHistoryScrollsNewestLast() {
        var history = LevelHistory(capacity: 4)
        XCTAssertEqual(history.values, [0, 0, 0, 0])
        history.append(0.5)
        history.append(2)
        history.append(-1)
        XCTAssertEqual(history.values, [0, 0.5, 1, 0])
        history.append(0.25)
        history.append(0.75)
        XCTAssertEqual(history.values, [1, 0, 0.25, 0.75])
        history.reset()
        XCTAssertEqual(history.values, [0, 0, 0, 0])
    }

    func testBarHeightsSoftenTheEdges() {
        var history = LevelHistory(capacity: OrbLayout.barCount)
        for _ in 0..<OrbLayout.barCount { history.append(1) }
        let heights = OrbLayout.barHeights(history.values)
        XCTAssertEqual(heights.count, OrbLayout.barCount)
        XCTAssertLessThan(heights[0], heights[OrbLayout.barCount / 2])
        XCTAssertLessThan(heights[OrbLayout.barCount - 1], heights[OrbLayout.barCount / 2])
        XCTAssertLessThanOrEqual(heights.max()!, OrbLayout.barMaxHeight)
        XCTAssertEqual(OrbLayout.barHeights(Array(repeating: 0, count: OrbLayout.barCount)).max(), OrbLayout.barMinHeight)
    }
}
