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

    // MARK: the name band

    /// Each wedge's name sits on a band outside its last ring. The band is not a button: a
    /// pointer over it still selects the wedge's last ring, whatever the wedge has.
    func testThePointerOverTheNameBandSelectsTheLastRing() {
        let g = RadialGeometry(count: 3, ringCounts: [3, 2, 3])
        XCTAssertGreaterThan(g.nameBand.inner, g.outerEdge)
        XCTAssertGreaterThan(g.nameBand.outer, g.nameBand.inner)
        for r in [g.nameBand.inner, (g.nameBand.inner + g.nameBand.outer) / 2, g.nameBand.outer] {
            XCTAssertEqual(g.selection(at: offset(angle: g.centerAngle(of: 0), radius: r)), .wedge(index: 0, ring: .outer))
            XCTAssertEqual(g.selection(at: offset(angle: g.centerAngle(of: 1), radius: r)), .wedge(index: 1, ring: .middle))
        }
    }

    /// Every ring's label band lies inside that ring, clear of the digit by the dead zone.
    func testEachLabelSitsInsideItsRing() {
        let g = RadialGeometry(count: 2, ringCounts: [3, 2])
        for i in 0..<2 {
            for ring in g.rings(of: i) {
                let band = g.band(ring, of: i)
                let label = g.labelBand(ring, of: i)
                XCTAssertGreaterThanOrEqual(label.inner, band.r0, "\(i) \(ring)")
                XCTAssertLessThanOrEqual(label.outer, band.r1, "\(i) \(ring)")
                XCTAssertGreaterThan(label.outer - label.inner, 24, "room for a line or two")
            }
        }
        XCTAssertGreaterThanOrEqual(g.labelBand(.inner, of: 0).inner, g.deadZone + 14, "the digit sits below the label")
    }

    /// Up to eight wedges the wheel keeps its size; past that its rings move out, so a word on
    /// the inner ring still has room. The dead zone never moves, and the middle and outer rings
    /// keep their depth.
    func testAWheelWithManyWedgesMovesItsRingsOut() {
        for count in 1...8 {
            XCTAssertEqual(RadialGeometry.growth(count: count), 0, "\(count) wedges")
            XCTAssertEqual(RadialGeometry(count: count).outerEdge, 196)
        }
        var last: CGFloat = 196
        for count in 9...12 {
            let g = RadialGeometry(count: count)
            XCTAssertGreaterThan(g.outerEdge, last, "\(count) wedges")
            last = g.outerEdge
            XCTAssertEqual(g.deadZone, 46)
            XCTAssertEqual(g.middleEdge - g.innerEdge, 48, accuracy: 0.001)
            XCTAssertEqual(g.outerEdge - g.middleEdge, 48, accuracy: 0.001)
        }
        for count in 1...12 {
            let g = RadialGeometry(count: count)
            let band = g.labelBand(.inner, of: 0)
            let line = (band.inner + band.outer) / 2 - 6   // the foot of one line centred in the band
            XCTAssertGreaterThanOrEqual(g.textAngle(at: line) * Double(line), 40, "\(count) wedges")
        }
    }

    // MARK: rings: labels, outcomes, hints

    @MainActor
    func testRingLabelsDependOnWedgeKind() {
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: .loadout("Work")), "Preview")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: .loadout("Work")), "Apply")
        XCTAssertEqual(RadialMenu.ringLabel(.outer, for: .loadout("Work")), "Clear + Apply")
        let everyScreen = RadialMenu.Wedge.Kind.capture(offersAllScreens: true)
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: everyScreen), "This screen")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: everyScreen), "All screens")
        XCTAssertEqual(RadialMenu.ringLabel(.outer, for: everyScreen), "Draw layout")
        XCTAssertEqual(RadialMenu.ringCount(for: .loadout("Work")), 3)
        XCTAssertEqual(RadialMenu.ringCount(for: everyScreen), 3)
    }

    @MainActor
    func testEachRingCommitsItsOwnOutcome() {
        XCTAssertEqual(RadialMenu.outcome(of: .loadout("Work"), ring: .inner), .preview(loadout: "Work"))
        XCTAssertEqual(RadialMenu.outcome(of: .loadout("Work"), ring: .middle), .apply(loadout: "Work", clear: false))
        XCTAssertEqual(RadialMenu.outcome(of: .loadout("Work"), ring: .outer), .apply(loadout: "Work", clear: true))
        let everyScreen = RadialMenu.Wedge.Kind.capture(offersAllScreens: true)
        XCTAssertEqual(RadialMenu.outcome(of: everyScreen, ring: .inner), .capture(allScreens: false))
        XCTAssertEqual(RadialMenu.outcome(of: everyScreen, ring: .middle), .capture(allScreens: true))
        XCTAssertEqual(RadialMenu.outcome(of: everyScreen, ring: .outer), .drawLayout)
        let park = RadialMenu.Wedge.Kind.park(.init(focused: "Safari · Docs", parked: ["Mail"]))
        XCTAssertEqual(RadialMenu.outcome(of: park, ring: .inner), .park(restore: false))
        XCTAssertEqual(RadialMenu.outcome(of: park, ring: .middle), .park(restore: true))
        XCTAssertEqual(RadialMenu.outcome(of: .park(.init()), ring: .middle), .park(restore: true))
        XCTAssertEqual(RadialMenu.outcome(of: .widgets, ring: .inner), .widgets(edit: false))
        XCTAssertEqual(RadialMenu.outcome(of: .widgets, ring: .outer), .widgets(edit: true))
    }

    /// The line under the wheel says what releasing does, and nothing else: no section name,
    /// no counts, no dash.
    @MainActor
    func testTheHintSaysOnlyWhatTheHighlightedButtonDoes() {
        XCTAssertEqual(RadialMenu.hint(.inner, for: .loadout("Morning research")), "Preview Morning research")
        XCTAssertEqual(RadialMenu.hint(.middle, for: .loadout("Morning research")), "Apply Morning research")
        XCTAssertEqual(RadialMenu.hint(.outer, for: .loadout("Morning research")),
                       "Clear this screen and apply Morning research")
        let everyScreen = RadialMenu.Wedge.Kind.capture(offersAllScreens: true)
        XCTAssertEqual(RadialMenu.hint(.inner, for: everyScreen), "Capture this screen as a loadout")
        XCTAssertEqual(RadialMenu.hint(.middle, for: everyScreen), "Capture every screen as a loadout")
        XCTAssertEqual(RadialMenu.hint(.outer, for: everyScreen), "Draw a new layout")
        XCTAssertEqual(RadialMenu.hint(.middle, for: .capture(offersAllScreens: false)), "Draw a new layout")
        XCTAssertEqual(RadialMenu.hint(.inner, for: .widgets), "Reveal widgets")
        XCTAssertEqual(RadialMenu.hint(.middle, for: .widgets), "Edit widgets")

        let wedges = [RadialMenu.Wedge(name: "Code", kind: .loadout("Code")),
                      RadialMenu.Wedge(name: "Widgets", kind: .widgets)]
        XCTAssertEqual(RadialMenu.hint(for: .cancel, in: wedges), "Release on a button · centre cancels")
        XCTAssertEqual(RadialMenu.hint(for: .wedge(index: 0, ring: .middle), in: wedges), "Apply Code")
        XCTAssertEqual(RadialMenu.hint(for: .wedge(index: 1, ring: .middle), in: wedges), "Edit widgets")
        XCTAssertEqual(RadialMenu.hint(for: .wedge(index: 5, ring: .inner), in: wedges), "Release on a button · centre cancels")
        for wedge in wedges {
            for ring in RadialGeometry.Ring.allCases {
                let hint = RadialMenu.hint(ring, for: wedge.kind)
                XCTAssertFalse(hint.contains("—") || hint.contains(" · ") || hint.contains("…"), hint)
            }
        }
    }

    /// Without multi-desktop loadouts (experimental) the capture wedge captures the screen under
    /// the pointer only: two rings, this screen and a new layout, and no all-screens ring.
    @MainActor
    func testWithoutMultiDesktopLoadoutsTheCaptureWedgeCapturesThisScreenOnly() {
        let thisScreen = RadialMenu.Wedge.Kind.capture(offersAllScreens: false)
        XCTAssertEqual(RadialMenu.ringCount(for: thisScreen), 2)
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: thisScreen), "This screen")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: thisScreen), "Draw layout")
        XCTAssertEqual(RadialMenu.outcome(of: thisScreen, ring: .inner), .capture(allScreens: false))
        XCTAssertEqual(RadialMenu.outcome(of: thisScreen, ring: .middle), .drawLayout)
        XCTAssertEqual(RadialMenu.outcome(of: thisScreen, ring: .outer), .drawLayout)

        let wedges = [RadialMenu.Wedge(name: "Capture", kind: thisScreen)]
        let json = RadialMenu.json(wedges: wedges, geometry: RadialGeometry(count: 1, ringCounts: [RadialMenu.ringCount(for: thisScreen)]))
        let wedge = (json["wedges"] as? [[String: Any]])?.first
        XCTAssertEqual(wedge?["kind"] as? String, "capture")
        XCTAssertEqual(wedge?["name"] as? String, "Capture")
        XCTAssertEqual(wedge?["rings"] as? [String], ["This screen", "Draw layout"])
        XCTAssertEqual(wedge?["hints"] as? [String], ["Capture this screen as a loadout", "Draw a new layout"])
    }

    /// `menu` lists each wedge's name, its rings' labels and the hint each ring shows, and the
    /// selection with the hint showing now; nothing reports a subtitle.
    @MainActor
    func testTheMenuJSONCarriesNamesLabelsAndHints() {
        let wedges = [RadialMenu.Wedge(name: "Morning research and writing", kind: .loadout("Morning research and writing")),
                      RadialMenu.Wedge(name: "Park", kind: .park(.init(focused: "Notes · Groceries")))]
        let g = RadialGeometry(count: 2, ringCounts: wedges.map { RadialMenu.ringCount(for: $0.kind) })
        let json = RadialMenu.json(wedges: wedges, geometry: g)
        let out = json["wedges"] as? [[String: Any]]
        XCTAssertEqual(out?[0]["name"] as? String, "Morning research and writing")
        XCTAssertEqual(out?[0]["rings"] as? [String], ["Preview", "Apply", "Clear + Apply"])
        XCTAssertEqual(out?[0]["hints"] as? [String], ["Preview Morning research and writing",
                                                        "Apply Morning research and writing",
                                                        "Clear this screen and apply Morning research and writing"])
        XCTAssertEqual(out?[1]["rings"] as? [String], ["Park", "Restore"])
        XCTAssertEqual(out?[1]["hints"] as? [String], ["Park Notes · Groceries", "Nothing is parked"])
        XCTAssertEqual(out?[0]["digit"] as? Int, 1)
        XCTAssertNil(out?[0]["subtitle"])
        XCTAssertNil(out?[0]["title"])
        let rings = json["rings"] as? [String: Double]
        XCTAssertEqual(rings?["names"], Double(g.nameBand.outer))

        let selected = RadialMenu.json(wedges: wedges, geometry: g, selection: .wedge(index: 0, ring: .outer))["selection"] as? [String: Any]
        XCTAssertEqual(selected?["name"] as? String, "Morning research and writing")
        XCTAssertEqual(selected?["ring"] as? String, "outer")
        XCTAssertEqual(selected?["hint"] as? String, "Clear this screen and apply Morning research and writing")
        let idle = RadialMenu.json(wedges: wedges, geometry: g, selection: .cancel)["selection"] as? [String: Any]
        XCTAssertEqual(idle?["kind"] as? String, "cancel")
        XCTAssertEqual(idle?["hint"] as? String, "Release on a button · centre cancels")
    }
}

final class ParkWedgeTests: XCTestCase {
    @MainActor
    func testParkWedgeHasTwoRings() {
        XCTAssertEqual(RadialMenu.ringCount(for: .park(.init())), 2)
        XCTAssertEqual(RadialMenu.ringLabel(.inner, for: .park(.init())), "Park")
        XCTAssertEqual(RadialMenu.ringLabel(.middle, for: .park(.init())), "Restore")
    }

    /// Park says which window it would park, or asks for one; Restore says which window (or how
    /// many) it would bring back, and with nothing parked says what Park says when there is
    /// nothing to do.
    @MainActor
    func testTheParkHintsNameTheWindow() {
        func hints(_ focused: String?, _ parked: [String]) -> [String] {
            let kind = RadialMenu.Wedge.Kind.park(.init(focused: focused, parked: parked))
            return [RadialMenu.hint(.inner, for: kind), RadialMenu.hint(.middle, for: kind)]
        }
        XCTAssertEqual(hints(nil, []), ["Focus a window to park", "Focus a window to park"])
        XCTAssertEqual(hints("Safari · Docs", []), ["Park Safari · Docs", "Nothing is parked"])
        XCTAssertEqual(hints("Safari · Docs", ["Mail · Inbox"]), ["Park Safari · Docs", "Restore Mail · Inbox"])
        XCTAssertEqual(hints(nil, ["Mail · Inbox"]), ["Focus a window to park", "Restore Mail · Inbox"])
        XCTAssertEqual(hints(nil, ["Mail · Inbox", "Notes", "Terminal"]), ["Focus a window to park", "Restore 3 parked windows"])
        let kind = RadialMenu.Wedge.Kind.park(.init(focused: "Safari · Docs", parked: ["Mail"]))
        XCTAssertEqual(RadialMenu.hint(.outer, for: kind), "Restore Mail", "a ring past the last is the last")
    }
}
