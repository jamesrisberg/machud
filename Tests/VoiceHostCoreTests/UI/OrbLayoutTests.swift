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

    func testCollapsedCardFrameKeepsTheTopEdge() {
        let full = OrbLayout.cardFrame(size: CGSize(width: 340, height: 200), geometry: notched)
        let collapsed = OrbLayout.collapsed(full)
        XCTAssertEqual(collapsed.maxY, full.maxY)
        XCTAssertEqual(collapsed.midX, full.midX)
        XCTAssertLessThan(collapsed.height, full.height)
        XCTAssertLessThan(collapsed.width, full.width)
    }

    func testBarsFitInsideTheWaveformBody() {
        let barsWidth = OrbLayout.recordDotRadius * 2 + OrbLayout.recordDotGap
            + CGFloat(OrbLayout.barCount) * OrbLayout.barWidth + CGFloat(OrbLayout.barCount - 1) * OrbLayout.barGap
        XCTAssertLessThan(barsWidth + 24, OrbLayout.waveformMinWidth)
        XCTAssertLessThan(OrbLayout.barMaxHeight, OrbLayout.waveformHeight)
    }
}
