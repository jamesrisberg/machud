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
        XCTAssertFalse(animator.isSettled(for: scene(.orb, .idle)))
    }

    // MARK: Armed

    func testArmedEasesInAndOutWithoutStretching() {
        var animator = OrbAnimator()
        for _ in 0..<30 { animator.advance(dt: 1.0 / 60, scene: scene(.orb, .armed), level: 0.5, reduceMotion: false) }
        XCTAssertEqual(animator.stretch, 0)
        XCTAssertGreaterThan(animator.armed, 0.9)
        XCTAssertFalse(animator.isSettled(for: scene(.orb, .armed)), "the ring follows the level")
        // Committing to the waveform: the armed look fades while the orb stretches.
        animator.advance(dt: 1.0 / 60, scene: scene(.waveform, .bars), level: 0.5, reduceMotion: false)
        XCTAssertGreaterThan(animator.armed, 0)
        XCTAssertGreaterThan(animator.stretch, 0)
        for _ in 0..<60 { animator.advance(dt: 1.0 / 60, scene: scene(.waveform, .bars), level: 0.5, reduceMotion: false) }
        XCTAssertEqual(animator.armed, 0)
    }

    func testArmedUnderReduceMotionJumps() {
        var animator = OrbAnimator()
        animator.advance(dt: 1.0 / 60, scene: scene(.orb, .armed), level: 0, reduceMotion: true)
        XCTAssertEqual(animator.armed, 1)
        animator.advance(dt: 1.0 / 60, scene: scene(.orb, .pulse), level: 0, reduceMotion: true)
        XCTAssertEqual(animator.armed, 0)
    }

    // MARK: Resting float

    func testTheFloatEasesInWhileResting() {
        var animator = OrbAnimator()
        for _ in 0..<(60 * 3) { animator.advance(dt: 1.0 / 60, scene: scene(.orb, .idle), level: 0, reduceMotion: false) }
        XCTAssertEqual(animator.float, 1)
        XCTAssertGreaterThan(animator.bobOffset, 0)
        XCTAssertLessThanOrEqual(animator.bobOffset, OrbLayout.bobAmplitude)
    }

    func testTheFloatEasesOutWhenSomethingElseTakesOver() {
        var animator = OrbAnimator(float: 1)
        for _ in 0..<100 { animator.advance(dt: 1.0 / 60, scene: scene(.orb, .idle), level: 0, reduceMotion: false) }
        let offset = animator.bobOffset
        XCTAssertGreaterThan(offset, 0)
        animator.advance(dt: 1.0 / 60, scene: scene(.orb, .pulse), level: 0, reduceMotion: false)
        XCTAssertLessThan(animator.float, 1)
        XCTAssertGreaterThan(animator.float, 0.5, "eases, never jumps")
        for _ in 0..<(60 * 3) { animator.advance(dt: 1.0 / 60, scene: scene(.orb, .pulse), level: 0, reduceMotion: false) }
        XCTAssertEqual(animator.float, 0)
        XCTAssertEqual(animator.bobOffset, 0)
    }

    func testTheFloatStopsForACardOrWhenMuted() {
        var withCard = scene(.orb, .idle)
        withCard.card = VoiceCard(prompt: "hi")
        XCTAssertEqual(OrbAnimator.floatTarget(for: withCard, reduceMotion: false), 0)
        XCTAssertEqual(OrbAnimator.floatTarget(for: scene(.orb, .none), reduceMotion: false), 0, "muted rests still")
        XCTAssertEqual(OrbAnimator.floatTarget(for: scene(.orb, .idle), reduceMotion: false), 1)
    }

    func testReduceMotionHasNoFloat() {
        var animator = OrbAnimator(float: 1)
        animator.advance(dt: 1.0 / 60, scene: scene(.orb, .idle), level: 0, reduceMotion: true)
        XCTAssertEqual(animator.float, 0)
        XCTAssertEqual(animator.bobOffset, 0)
        XCTAssertTrue(animator.isSettled(for: scene(.orb, .idle), reduceMotion: true))
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
