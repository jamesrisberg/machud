import AppKit
import XCTest
@testable import MacHUDCore

/// Names and button labels on the wheel follow their arc and are fitted, never clipped: they
/// shrink to a floor, then wrap to a second line, and only then truncate at a word boundary.
@MainActor
final class RadialTextFitTests: XCTestCase {
    private static let counts = [3, 6, 9, 12]
    private static let names = ["Code", "Messaging", "dev: Browsers", "Morning research and writing",
                                "Capture", "Park", "Widgets",
                                "Quarterly planning with the whole design and research team"]
    private static let kinds: [RadialMenu.Wedge.Kind] = [.loadout("L"), .capture(offersAllScreens: false),
                                                         .capture(offersAllScreens: true), .park(.init()), .widgets]

    private func width(_ text: String, _ style: TextFit.Style, _ size: CGFloat) -> CGFloat {
        TextFit.width(text, font: style.font(size))
    }

    /// Every line stays inside its band and within the arc its wedge leaves for text at its
    /// lowest point (the descenders), measured independently of the fitter.
    private func assertInside(_ text: ArcText, style: TextFit.Style, band: (inner: CGFloat, outer: CGFloat),
                              geometry g: RadialGeometry, _ what: String, line: UInt = #line) {
        let font = style.font(text.fit.size)
        XCTAssertGreaterThanOrEqual(text.fit.size, style.floor, what, line: line)
        XCTAssertLessThanOrEqual(text.fit.size, style.preferred, what, line: line)
        XCTAssertFalse(text.fit.lines.isEmpty, what, line: line)
        XCTAssertLessThanOrEqual(text.fit.lines.count, style.maxLines, what, line: line)
        XCTAssertEqual(text.baselines.count, text.fit.lines.count, what, line: line)
        for (i, (string, baseline)) in zip(text.fit.lines, text.baselines).enumerated() {
            let foot = baseline + font.descender
            let w = TextFit.width(string, font: font)
            XCTAssertLessThanOrEqual(w, g.textAngle(at: foot) * Double(foot) + 0.01, "\(what) line \(i) '\(string)'", line: line)
            XCTAssertGreaterThanOrEqual(foot, band.inner - 0.01, "\(what) line \(i)", line: line)
            XCTAssertLessThanOrEqual(baseline + font.ascender, band.outer + 0.01, "\(what) line \(i)", line: line)
        }
        if text.baselines.count == 2 { XCTAssertGreaterThan(text.baselines[0], text.baselines[1], "the first line is outermost") }
    }

    func testNoNameOrLabelEverLeavesItsArc() {
        for count in Self.counts {
            let g = RadialGeometry(count: count, ringCounts: Array(repeating: 3, count: count))
            for name in Self.names {
                assertInside(g.fitName(name), style: .name, band: g.nameTextBand, geometry: g, "\(count) wedges: \(name)")
            }
            for kind in Self.kinds {
                let rings = RadialGeometry.Ring.allCases.prefix(RadialMenu.ringCount(for: kind))
                let g = RadialGeometry(count: count, ringCounts: [rings.count])
                for ring in rings {
                    let label = RadialMenu.ringLabel(ring, for: kind)
                    assertInside(g.fitLabel(label, ring: ring, of: 0), style: .label, band: g.labelBand(ring, of: 0),
                                 geometry: g, "\(count) wedges: \(label)")
                }
            }
        }
    }

    func testShortNamesAndEveryLabelReadWhole() {
        for count in Self.counts {
            let g = RadialGeometry(count: count)
            for name in ["Code", "Messaging", "dev: Browsers", "Capture", "Park", "Widgets"] {
                let fit = g.fitName(name).fit
                XCTAssertEqual(fit.lines, [name], "\(count) wedges")
                XCTAssertFalse(fit.truncated)
            }
            XCTAssertEqual(g.fitName("Code").fit.size, TextFit.Style.name.preferred)
            for kind in Self.kinds {
                let rings = RadialGeometry.Ring.allCases.prefix(RadialMenu.ringCount(for: kind))
                let g = RadialGeometry(count: count, ringCounts: [rings.count])
                for ring in rings {
                    let label = RadialMenu.ringLabel(ring, for: kind)
                    let fit = g.fitLabel(label, ring: ring, of: 0).fit
                    XCTAssertFalse(fit.truncated, "\(count) wedges: \(label) as \(fit.lines)")
                    XCTAssertEqual(fit.lines.joined(separator: " "), label)
                }
            }
        }
    }

    func testALongNameWrapsToASecondLineBeforeItTruncates() {
        let name = "Morning research and writing"
        XCTAssertEqual(RadialGeometry(count: 3).fitName(name).fit.lines, [name])
        for count in [9, 12] {
            let fit = RadialGeometry(count: count).fitName(name).fit
            XCTAssertEqual(fit.lines.count, 2, "\(count) wedges")
            XCTAssertEqual(fit.lines.joined(separator: " "), name)
            XCTAssertFalse(fit.truncated)
        }
    }

    /// One line at a smaller size wins over two lines at the full size.
    func testAFitShrinksBeforeItWraps() {
        let style = TextFit.Style.name
        let text = "Morning research"
        let budget = width(text, style, style.preferred) - 6
        let fit = TextFit.fit(text, style: style) { lines, _ in Array(repeating: budget, count: lines) }
        XCTAssertEqual(fit.lines, [text])
        XCTAssertLessThan(fit.size, style.preferred)
        XCTAssertGreaterThanOrEqual(fit.size, style.floor)
        XCTAssertLessThanOrEqual(width(text, style, fit.size), budget)
    }

    /// When two lines at the floor are not enough, the last line ends in an ellipsis after a
    /// whole word.
    func testTruncationFallsOnAWordBoundary() throws {
        let style = TextFit.Style.name
        let text = "Quarterly planning with the whole design and research team"
        let budget: CGFloat = 80
        let fit = TextFit.fit(text, style: style) { lines, _ in Array(repeating: budget, count: lines) }
        XCTAssertTrue(fit.truncated)
        XCTAssertEqual(fit.size, style.floor)
        XCTAssertEqual(fit.lines.count, 2)
        let last = try XCTUnwrap(fit.lines.last)
        XCTAssertTrue(last.hasSuffix("…"), last)
        let shown = (fit.lines.dropLast() + [String(last.dropLast())]).joined(separator: " ")
        XCTAssertTrue(text.hasPrefix(shown), shown)
        XCTAssertTrue(text.dropFirst(shown.count).hasPrefix(" "), "cut between words: \(shown)")
        for line in fit.lines { XCTAssertLessThanOrEqual(width(line, style, fit.size), budget) }
    }

    func testAWordTooLongForItsLineLosesLettersNotTheEllipsis() {
        let style = TextFit.Style(weight: .semibold, preferred: 11, floor: 9, maxLines: 1)
        let fit = TextFit.fit("Supercalifragilistic", style: style) { lines, _ in Array(repeating: 40, count: lines) }
        XCTAssertTrue(fit.truncated)
        XCTAssertEqual(fit.lines.count, 1)
        XCTAssertTrue(fit.lines[0].hasPrefix("Super"), fit.lines[0])
        XCTAssertTrue(fit.lines[0].hasSuffix("…"))
        XCTAssertLessThanOrEqual(width(fit.lines[0], style, fit.size), 40)
    }

    /// A band too shallow for two lines keeps one.
    func testABandTooShallowForTwoLinesKeepsOne() {
        let text = ArcText.fit("Morning research and writing", style: .name, inner: 200, outer: 218, angle: 0.4, inset: 4)
        XCTAssertEqual(text.fit.lines.count, 1)
        XCTAssertTrue(text.fit.truncated)
    }

    /// Text stands on its arc with its top pointing outward, wherever it is: upright at the top,
    /// running down the right side, and upside-down at the bottom. Nothing is flipped to read.
    func testTextStandsOnItsArcTopsOutwardEvenAtTheBottom() {
        let c = CGPoint(x: 300, y: 300)
        func place(_ x: CGFloat, at a: Double) -> (point: CGPoint, rotation: CGFloat) {
            ArcText.place(x: x, lineWidth: 40, radius: 100, centerAngle: a, center: c)
        }
        // Top: left to right, upright.
        XCTAssertLessThan(place(0, at: 0).point.x, place(40, at: 0).point.x)
        XCTAssertEqual(place(20, at: 0).rotation, 0, accuracy: 1e-9)
        XCTAssertEqual(place(20, at: 0).point.y, 400, accuracy: 1e-9)
        // Right side: top to bottom, tops pointing right.
        XCTAssertGreaterThan(place(0, at: .pi / 2).point.y, place(40, at: .pi / 2).point.y)
        XCTAssertEqual(place(20, at: .pi / 2).rotation, -.pi / 2, accuracy: 1e-9)
        // Bottom: right to left on screen, upside-down.
        XCTAssertGreaterThan(place(0, at: .pi).point.x, place(40, at: .pi).point.x)
        XCTAssertEqual(place(20, at: .pi).rotation, -.pi, accuracy: 1e-9)
        XCTAssertEqual(place(20, at: .pi).point.y, 200, accuracy: 1e-9)
    }

    /// The hint under the wheel is fitted to the wheel's width: wrapped, shrunk, and at worst
    /// truncated, never cut off by the window.
    @MainActor
    func testTheHintFitsInsideTheWheelsWindow() {
        for count in Self.counts {
            let g = RadialGeometry(count: count)
            let width = RadialMenu.canvas(for: g).hintWidth
            XCTAssertLessThan(width, RadialMenu.canvas(for: g).size.width)
            for hint in ["Apply Code", RadialMenu.idleHint,
                         "Clear this screen and apply Quarterly planning with the whole design and research team",
                         "Park Safari · " + String(repeating: "A rather long page title ", count: 8)] {
                let fit = RadialMenu.fitHint(hint, width: width)
                XCTAssertLessThanOrEqual(fit.lines.count, 2)
                for line in fit.lines {
                    XCTAssertLessThanOrEqual(TextFit.width(line, font: TextFit.Style.hint.font(fit.size)), width, hint)
                }
            }
        }
        let short = RadialMenu.fitHint("Apply Code", width: 400)
        XCTAssertEqual(short.lines, ["Apply Code"])
        XCTAssertEqual(short.size, TextFit.Style.hint.preferred)
    }
}
