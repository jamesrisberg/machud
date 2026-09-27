import XCTest
@testable import MacHUDCore

final class RadialGeometryTests: XCTestCase {
    private let tau = 2 * Double.pi

    private func offset(angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
    }

    // MARK: angle

    func testAngleIsClockwiseFromStraightUp() {
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: 0, y: 10)), 0, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: 10, y: 0)), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: 0, y: -10)), .pi, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: -10, y: 0)), 3 * .pi / 2, accuracy: 1e-9)
    }

    func testAngleIsAlwaysInRange() {
        for degrees in stride(from: -720, through: 720, by: 7) {
            let a = Double(degrees) * .pi / 180
            let value = RadialGeometry.angle(of: offset(angle: a, radius: 100))
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, tau)
        }
    }

    // MARK: angle -> wedge

    func testFourWedgesFaceTheCompassPoints() {
        let g = RadialGeometry(count: 4)
        XCTAssertEqual(g.index(atAngle: 0), 0)              // up
        XCTAssertEqual(g.index(atAngle: .pi / 2), 1)        // right
        XCTAssertEqual(g.index(atAngle: .pi), 2)            // down
        XCTAssertEqual(g.index(atAngle: 3 * .pi / 2), 3)    // left
    }

    func testWedgeBoundariesRoundToTheNeighbour() {
        let g = RadialGeometry(count: 4)
        let half = g.wedgeAngle / 2       // 45 degrees
        XCTAssertEqual(g.index(atAngle: half - 0.001), 0)
        XCTAssertEqual(g.index(atAngle: half + 0.001), 1)
        // Just clockwise of straight up wraps back to wedge 0, not to the last wedge.
        XCTAssertEqual(g.index(atAngle: tau - 0.001), 0)
        XCTAssertEqual(g.index(atAngle: tau - half + 0.001), 0)
        XCTAssertEqual(g.index(atAngle: tau - half - 0.001), 3)
    }

    func testEveryWedgeCentreSelectsItself() {
        for count in 1...12 {
            let g = RadialGeometry(count: count)
            for i in 0..<count {
                XCTAssertEqual(g.index(atAngle: g.centerAngle(of: i)), i, "count \(count) wedge \(i)")
                let inside = g.selection(at: offset(angle: g.centerAngle(of: i), radius: 70))
                XCTAssertEqual(inside, .wedge(index: i, ring: .inner), "count \(count) wedge \(i)")
            }
        }
    }

    func testWedgeAnglesTileTheCircleWithoutGaps() {
        let g = RadialGeometry(count: 5)
        for i in 0..<5 {
            XCTAssertEqual(g.endAngle(of: i), g.startAngle(of: i + 1), accuracy: 1e-12)
            XCTAssertEqual(g.endAngle(of: i) - g.startAngle(of: i), g.wedgeAngle, accuracy: 1e-12)
        }
        XCTAssertEqual(g.wedgeAngle * 5, tau, accuracy: 1e-12)
    }

    func testSingleWedgeSwallowsEveryAngle() {
        let g = RadialGeometry(count: 1)
        for degrees in stride(from: 0, to: 360, by: 3) {
            let a = Double(degrees) * .pi / 180
            XCTAssertEqual(g.index(atAngle: a), 0)
        }
    }

    func testNoWedgesAlwaysCancels() {
        let g = RadialGeometry(count: 0)
        XCTAssertEqual(g.selection(at: CGPoint(x: 0, y: 500)), .cancel)
    }

    // MARK: radius -> ring

    func testRadiusPicksTheRing() {
        let g = RadialGeometry(count: 4)
        XCTAssertEqual(g.ring(radius: g.innerEdge - 1), .inner)
        XCTAssertEqual(g.ring(radius: g.innerEdge), .middle)
        XCTAssertEqual(g.ring(radius: g.middleEdge - 1), .middle)
        XCTAssertEqual(g.ring(radius: g.middleEdge), .outer)
        XCTAssertEqual(g.ring(radius: g.outerEdge + 400), .outer)
    }

    func testDeadZoneCancels() {
        let g = RadialGeometry(count: 4)
        XCTAssertEqual(g.selection(at: .zero), .cancel)
        XCTAssertEqual(g.selection(at: offset(angle: 0, radius: g.deadZone - 1)), .cancel)
        XCTAssertEqual(g.selection(at: offset(angle: 0, radius: g.deadZone)), .wedge(index: 0, ring: .inner))
    }

    func testDraggingOutwardWalksTheRings() {
        let g = RadialGeometry(count: 3)
        let a = g.centerAngle(of: 2)
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 60)), .wedge(index: 2, ring: .inner))
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 120)), .wedge(index: 2, ring: .middle))
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 170)), .wedge(index: 2, ring: .outer))
        // Past the drawn edge the outer ring keeps selecting.
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 900)), .wedge(index: 2, ring: .outer))
    }

    func testAWedgeWithFewerRingsKeepsItsLastOne() {
        // Wedge 1 has two rings (the park wedge): its middle ring reaches the edge and beyond.
        let g = RadialGeometry(count: 2, ringCounts: [3, 2])
        let a = g.centerAngle(of: 1)
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 60)), .wedge(index: 1, ring: .inner))
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 120)), .wedge(index: 1, ring: .middle))
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 170)), .wedge(index: 1, ring: .middle))
        XCTAssertEqual(g.selection(at: offset(angle: a, radius: 900)), .wedge(index: 1, ring: .middle))
        XCTAssertEqual(g.rings(of: 1), [.inner, .middle])
        XCTAssertEqual(g.rings(of: 0), [.inner, .middle, .outer])
        XCTAssertEqual(g.band(.middle, of: 1).r1, g.outerEdge, "the last ring runs to the edge")
        XCTAssertEqual(g.band(.middle, of: 0).r1, g.middleEdge)
        XCTAssertEqual(g.band(.inner, of: 0).r0, g.deadZone)
    }

    func testShiftForcesTheLastRing() {
        let g = RadialGeometry(count: 3, ringCounts: [3, 2, 3])
        let o = offset(angle: g.centerAngle(of: 0), radius: 70)
        XCTAssertEqual(g.selection(at: o, shift: false), .wedge(index: 0, ring: .inner))
        XCTAssertEqual(g.selection(at: o, shift: true), .wedge(index: 0, ring: .outer))
        XCTAssertEqual(g.selection(at: offset(angle: g.centerAngle(of: 1), radius: 70), shift: true), .wedge(index: 1, ring: .middle))
        // Shift does not defeat the dead zone.
        XCTAssertEqual(g.selection(at: .zero, shift: true), .cancel)
    }

    func testSelectionAccessors() {
        XCTAssertNil(RadialGeometry.Selection.cancel.index)
        XCTAssertNil(RadialGeometry.Selection.cancel.ring)
        let s = RadialGeometry.Selection.wedge(index: 7, ring: .outer)
        XCTAssertEqual(s.index, 7)
        XCTAssertEqual(s.ring, .outer)
    }

    @MainActor
    func testRingLabelsDependOnWedgeKind() {
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: .loadout("Work")), "Preview")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: .loadout("Work")), "Apply")
        XCTAssertEqual(RadialMenu.ringLabel(.outer, for: .loadout("Work")), "Clear this screen + Apply")
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: .capture), "Capture this screen as a loadout")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: .capture), "Capture all screens as a loadout")
        XCTAssertEqual(RadialMenu.ringLabel(.outer, for: .capture), "Draw a new layout")
        XCTAssertEqual(RadialMenu.ringCount(for: .loadout("Work")), 3)
        XCTAssertEqual(RadialMenu.ringCount(for: .capture), 3)
    }
}

final class ParkWedgeTests: XCTestCase {
    @MainActor
    func testParkWedgeHasTwoRings() {
        XCTAssertEqual(RadialMenu.ringCount(for: .park), 2)
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: .park), "Park front window")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: .park), "Restore parked")
    }
}
