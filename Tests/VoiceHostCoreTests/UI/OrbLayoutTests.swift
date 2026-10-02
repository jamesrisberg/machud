import HUDKit
import XCTest
@testable import VoiceHostCore

final class OrbLayoutTests: XCTestCase {
    /// A 14" MacBook Pro: 1512x982 points, 32 pt camera housing 185 pt wide.
    private let notched = HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                           safeAreaInsetTop: 32, notchWidth: 185)
    /// An external display with a 25 pt menu bar and no housing.
    private let plain = HUDNotchGeometry(screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                         visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    func testRestingOrbIsARoundShapeBelowTheAnchor() {
        let shape = OrbLayout.shape(stretch: 0, geometry: notched)
        XCTAssertEqual(shape.size.width, OrbLayout.orbDiameter)
        XCTAssertEqual(shape.size.height, OrbLayout.orbDiameter)
        XCTAssertEqual(shape.topOffset, OrbLayout.orbTopGap)
        XCTAssertEqual(shape.bottomRadius, OrbLayout.orbDiameter / 2)
        XCTAssertEqual(shape.topRadius, OrbLayout.orbDiameter / 2)
    }

    func testWaveformJoinsTheHousingWithSquareTopCorners() {
        let shape = OrbLayout.shape(stretch: 1, geometry: notched)
        XCTAssertEqual(shape.size.width, 185, "never narrower than the camera housing")
        XCTAssertEqual(shape.size.height, OrbLayout.waveformHeight)
        XCTAssertEqual(shape.topOffset, 0, "flush with the housing")
        XCTAssertEqual(shape.topRadius, 0, "no seam where it meets the notch")
        XCTAssertEqual(shape.bottomRadius, OrbLayout.waveformBottomRadius)
    }

    func testWaveformWithoutANotchHangsFromTheMenuBarWithRoundedTop() {
        let shape = OrbLayout.shape(stretch: 1, geometry: plain)
        XCTAssertEqual(shape.size.width, OrbLayout.waveformMinWidth)
        XCTAssertEqual(shape.topRadius, OrbLayout.waveformTopRadius)
    }

    func testMorphInterpolatesMonotonically() {
        var last = OrbLayout.shape(stretch: 0, geometry: notched)
        for step in 1...10 {
            let shape = OrbLayout.shape(stretch: CGFloat(step) / 10, geometry: notched)
            XCTAssertGreaterThan(shape.size.width, last.size.width)
            XCTAssertLessThanOrEqual(shape.topOffset, last.topOffset)
            last = shape
        }
    }

    func testStretchIsClamped() {
        XCTAssertEqual(OrbLayout.shape(stretch: -1, geometry: notched), OrbLayout.shape(stretch: 0, geometry: notched))
        XCTAssertEqual(OrbLayout.shape(stretch: 3, geometry: notched), OrbLayout.shape(stretch: 1, geometry: notched))
    }

    func testOrbWindowLeavesRoomForTheFullPulse() {
        let size = OrbLayout.windowSize(stretch: 0, geometry: notched)
        let pulsed = OrbLayout.orbDiameter * (1 + OrbLayout.pulseMax)
        XCTAssertGreaterThanOrEqual(size.width, pulsed)
        // The pulse scales about the shape's center; its bottom must stay inside the window.
        let center = OrbLayout.orbTopGap + OrbLayout.orbDiameter / 2
        XCTAssertGreaterThanOrEqual(size.height, center + pulsed / 2)
        XCTAssertGreaterThanOrEqual(center - pulsed / 2, 0, "and its top must not cross the anchor")
    }

    func testWaveformWindowIsExactlyTheBody() {
        let size = OrbLayout.windowSize(stretch: 1, geometry: notched)
        XCTAssertEqual(size, CGSize(width: 185, height: OrbLayout.waveformHeight))
    }

    func testOrbWindowIsCenteredUnderTheNotch() {
        let size = OrbLayout.windowSize(stretch: 0, geometry: notched)
        let frame = notched.anchorFrame(for: size)
        XCTAssertEqual(frame.midX, 756)
        XCTAssertEqual(frame.maxY, 982 - 32)
    }

    func testCardHangsBelowTheRestingOrbCenteredOnTheScreen() {
        let frame = OrbLayout.cardFrame(size: CGSize(width: 340, height: 120), geometry: notched)
        XCTAssertEqual(frame.midX, 756)
        XCTAssertEqual(frame.maxY, 950 - OrbLayout.orbTopGap - OrbLayout.orbDiameter - OrbLayout.cardGap)
        XCTAssertEqual(frame.height, 120)
    }

    func testCardHeightIsCapped() {
        let frame = OrbLayout.cardFrame(size: CGSize(width: 340, height: 5000), geometry: plain)
        XCTAssertEqual(frame.height, OrbLayout.cardMaxHeight)
        XCTAssertEqual(frame.midX, plain.screenFrame.midX)
    }

    // MARK: Resting float

    func testTheFloatOnlyDriftsDownWithinItsAmplitude() {
        var lowest: CGFloat = 0
        for step in 0...720 {
            let offset = OrbLayout.bob(phase: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(offset, 0, "never up into the notch or menu bar")
            XCTAssertLessThanOrEqual(offset, OrbLayout.bobAmplitude + 1e-9)
            lowest = max(lowest, offset)
        }
        XCTAssertEqual(lowest, OrbLayout.bobAmplitude, accuracy: 0.01)
        XCTAssertEqual(OrbLayout.bob(phase: 0), 0)
        XCTAssertEqual(OrbLayout.bob(phase: OrbLayout.bobPeriod / 2), OrbLayout.bobAmplitude, accuracy: 1e-9)
        XCTAssertEqual(OrbLayout.bob(phase: OrbLayout.bobPeriod), 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(OrbLayout.bobAmplitude, 4, "subtle: a few points")
        XCTAssertTrue((3...4).contains(OrbLayout.bobPeriod), "slow: 3-4 s a cycle")
    }

    func testTheOrbWindowHasRoomForTheFloat() {
        let size = OrbLayout.windowSize(stretch: 0, geometry: notched)
        XCTAssertGreaterThanOrEqual(size.height, OrbLayout.orbTopGap + OrbLayout.orbDiameter + OrbLayout.bobAmplitude)
        XCTAssertEqual(OrbLayout.bobRoom(stretch: 1), 0)
    }

    func testTheOrbFrameIsTheRestingOrbAndFloatsDown() {
        let rest = OrbLayout.orbFrame(geometry: notched)
        XCTAssertEqual(rest.midX, 756)
        XCTAssertEqual(rest.maxY, 950 - OrbLayout.orbTopGap)
        XCTAssertEqual(rest.size, CGSize(width: OrbLayout.orbDiameter, height: OrbLayout.orbDiameter))
        XCTAssertEqual(OrbLayout.orbFrame(geometry: notched, bob: 3).maxY, rest.maxY - 3)
    }

    func testTheBreathStaysInRange() {
        for step in 0...600 {
            XCTAssertTrue((0...1).contains(OrbLayout.breath(phase: Double(step) / 100)))
        }
    }

    // MARK: Card grow

    private var card: CGRect { OrbLayout.cardFrame(size: CGSize(width: 340, height: 200), geometry: notched) }
    private var orb: CGRect { OrbLayout.orbFrame(geometry: notched) }

    func testTheGrowStartsAsTheOrbAndEndsAsTheCard() {
        let start = OrbLayout.growShape(progress: 0, orb: orb, card: card)
        XCTAssertEqual(start.rect, orb)
        XCTAssertEqual(start.radius, OrbLayout.orbDiameter / 2, "a circle")
        let end = OrbLayout.growShape(progress: 1, orb: orb, card: card)
        XCTAssertEqual(end.rect, card)
        XCTAssertEqual(end.radius, OrbLayout.cardCornerRadius)
    }

    func testTheGrowOpensDownAndOutwardAroundTheOrb() {
        var last = OrbLayout.growShape(progress: 0, orb: orb, card: card)
        for step in 1...20 {
            let shape = OrbLayout.growShape(progress: CGFloat(step) / 20, orb: orb, card: card)
            XCTAssertGreaterThanOrEqual(shape.rect.width, last.rect.width)
            XCTAssertGreaterThanOrEqual(shape.rect.height, last.rect.height)
            XCTAssertLessThanOrEqual(shape.rect.maxY, last.rect.maxY, "the top edge only moves down")
            XCTAssertEqual(shape.rect.midX, 756, accuracy: 0.001, "no sideways slide")
            XCTAssertLessThanOrEqual(shape.radius, min(shape.rect.width, shape.rect.height) / 2 + 0.001)
            last = shape
        }
    }

    func testTheCollapseEndsOnTheOrb() {
        var grow = CardGrow()
        grow.target = 1
        grow.advance(dt: 1, reduceMotion: false)
        XCTAssertEqual(grow.progress, 1)
        grow.target = 0
        grow.advance(dt: OrbLayout.cardCloseDuration / 2, reduceMotion: false)
        XCTAssertEqual(grow.progress, 0.5, accuracy: 0.001)
        grow.advance(dt: OrbLayout.cardCloseDuration, reduceMotion: false)
        XCTAssertEqual(grow.progress, 0)
        XCTAssertEqual(OrbLayout.growShape(progress: grow.progress, orb: orb, card: card).rect, orb)
    }

    func testTheGrowTakesItsDurationAndReverses() {
        var grow = CardGrow()
        grow.target = 1
        grow.advance(dt: OrbLayout.cardOpenDuration / 2, reduceMotion: false)
        XCTAssertEqual(grow.progress, 0.5, accuracy: 0.001)
        XCTAssertFalse(grow.isSettled)
        grow.target = 0
        grow.advance(dt: 0.01, reduceMotion: false)
        XCTAssertLessThan(grow.progress, 0.5, "folds back from where it is")
    }

    func testReduceMotionDoesNotGrow() {
        var grow = CardGrow()
        grow.target = 1
        grow.advance(dt: 0.001, reduceMotion: true)
        XCTAssertEqual(grow.progress, 1)
    }

    func testTheWindowCoversTheOrbOnlyWhileTheShapeTravels() {
        XCTAssertEqual(OrbLayout.growWindowFrame(progress: 1, orb: orb, card: card), card)
        let traveling = OrbLayout.growWindowFrame(progress: 0.4, orb: orb, card: card)
        XCTAssertTrue(traveling.contains(orb) && traveling.contains(card))
    }

    func testTheContentFadesInOnceTheShapeIsMostlyOpen() {
        XCTAssertEqual(OrbLayout.contentAlpha(progress: 0), 0)
        XCTAssertEqual(OrbLayout.contentAlpha(progress: 0.5), 0)
        XCTAssertGreaterThan(OrbLayout.contentAlpha(progress: 0.8), 0)
        XCTAssertEqual(OrbLayout.contentAlpha(progress: 1), 1)
    }

    func testTheMessagePillKeepsItsRoundEnds() {
        let pill = CGRect(x: 600, y: 800, width: 180, height: 26)
        XCTAssertEqual(OrbLayout.growShape(progress: 1, orb: orb, card: pill).radius, 13)
    }

    func testBarsFitInsideTheWaveformBody() {
        let barsWidth = OrbLayout.recordDotRadius * 2 + OrbLayout.recordDotGap
            + CGFloat(OrbLayout.barCount) * OrbLayout.barWidth + CGFloat(OrbLayout.barCount - 1) * OrbLayout.barGap
        XCTAssertLessThan(barsWidth + 24, OrbLayout.waveformMinWidth)
        XCTAssertLessThan(OrbLayout.barMaxHeight, OrbLayout.waveformHeight)
    }

    // MARK: Conversation

    func testThePinnedConversationHangsWhereTheCardDoes() {
        let g = notched
        let card = OrbLayout.cardFrame(size: CGSize(width: OrbLayout.cardWidth, height: 120), geometry: g)
        let pinned = OrbLayout.pinnedFrame(contentHeight: 300, geometry: g)
        XCTAssertEqual(pinned.maxY, card.maxY)
        XCTAssertEqual(pinned.midX, g.screenFrame.midX, accuracy: 0.5)
        XCTAssertEqual(pinned.width, OrbLayout.pinnedWidth)
        XCTAssertEqual(pinned.height, 300)
        let tall = OrbLayout.pinnedFrame(contentHeight: 5000, geometry: g)
        XCTAssertEqual(tall.height, OrbLayout.pinnedMaxHeight(geometry: g))
        XCTAssertGreaterThanOrEqual(tall.minY, g.visibleFrame.minY)
        XCTAssertEqual(OrbLayout.pinnedFrame(contentHeight: 10, geometry: g).height, OrbLayout.pinnedMinHeight)
    }

    func testTheExpandedConversationIsLargeAndCenteredUnderTheNotch() {
        let g = notched
        let frame = OrbLayout.expandedFrame(geometry: g)
        XCTAssertEqual(frame.width, OrbLayout.expandedWidth)
        XCTAssertEqual(frame.midX, g.screenFrame.midX, accuracy: 0.5)
        XCTAssertEqual(frame.height, (g.screenFrame.height * OrbLayout.expandedHeightFraction).rounded(), accuracy: 1)
        XCTAssertEqual(frame.maxY, OrbLayout.cardFrame(size: CGSize(width: 10, height: 10), geometry: g).maxY)
        XCTAssertGreaterThanOrEqual(frame.minY, g.visibleFrame.minY)
    }

    func testTheExpandedConversationFitsASmallScreen() {
        let g = HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 375))
        let frame = OrbLayout.expandedFrame(geometry: g)
        XCTAssertLessThanOrEqual(frame.width, 600 - 2 * OrbLayout.expandedMargin)
        XCTAssertGreaterThanOrEqual(frame.minX, g.visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, g.visibleFrame.minY)
    }
}
