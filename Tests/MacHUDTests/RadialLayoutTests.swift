import AppKit
import XCTest
@testable import MacHUDCore

/// The wheel's words, upright, on one soft field: where each sits, the rings' radii they need,
/// and the field behind them.
@MainActor
final class RadialLayoutTests: XCTestCase {
    static let counts = [3, 6, 8, 9, 12]
    static let short = ["Code", "Mail", "Focus", "Notes", "Music", "Chat", "Docs", "Plan", "Read"]
    static let long = ["Morning research and writing", "dev: Browsers", "Messaging", "Quarterly planning review",
                       "Supercalifragilisticexpialidocious research", "Customer support rotation",
                       "https://intranet.example.com/teams/design/reviews/weekly", "Design critique", "Evening reading"]

    /// `count` wedges: loadouts named from `names`, then Capture, Park and Widgets (three tool
    /// wedges, or two below four wedges).
    static func wedges(_ count: Int, _ names: [String], allScreens: Bool = false,
                       icons: Int = 3) -> [RadialMenu.Wedge] {
        let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        var tools = [RadialMenu.Wedge(name: "Capture", icons: [image], kind: .capture(offersAllScreens: allScreens)),
                     RadialMenu.Wedge(name: "Park", icons: [image], kind: .park(.init()))]
        if count > 3 { tools.append(RadialMenu.Wedge(name: "Widgets", icons: [image], kind: .widgets(.init()))) }
        let loadouts = (0..<max(0, count - tools.count)).map { i in
            RadialMenu.Wedge(name: names[i % names.count], icons: Array(repeating: image, count: icons),
                             kind: .loadout(names[i % names.count]))
        }
        return loadouts + tools
    }

    private func everyLayout(_ body: (RadialLayout, String) -> Void) {
        for count in Self.counts {
            for (label, names) in [("short", Self.short), ("long", Self.long)] {
                for allScreens in [false, true] {
                    body(RadialLayout(wedges: Self.wedges(count, names, allScreens: allScreens)),
                         "\(count) wedges, \(label) names\(allScreens ? ", all screens" : "")")
                }
            }
        }
    }

    private static func distance(to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX, 0, -rect.maxX), max(rect.minY, 0, -rect.maxY))
    }

    private static func farthest(_ rect: CGRect) -> CGFloat {
        hypot(max(abs(rect.minX), abs(rect.maxX)), max(abs(rect.minY), abs(rect.maxY)))
    }

    // MARK: Words

    func testNoTwoRestingWordsOverlap() {
        everyLayout { layout, what in
            for (a, first) in layout.words.enumerated() {
                for second in layout.words[(a + 1)...] {
                    XCTAssertFalse(first.frame.intersects(second.frame),
                                   "\(what): \(first.role) \(first.fit.lines) and \(second.role) \(second.fit.lines)")
                }
                XCTAssertFalse(first.frame.intersects(layout.hintZone), "\(what): \(first.role) and the hint")
            }
        }
    }

    /// Buttons and names lie wholly outside the dead zone; the centre's word and the digits
    /// wholly inside it.
    func testNoWordCrossesTheDeadZone() {
        everyLayout { layout, what in
            let dead = layout.geometry.deadZone
            for word in layout.words {
                switch word.role {
                case .centre, .digit:
                    XCTAssertLessThanOrEqual(Self.farthest(word.frame), dead, "\(what): \(word.role)")
                case .button, .name:
                    XCTAssertGreaterThanOrEqual(Self.distance(to: word.frame), dead, "\(what): \(word.role)")
                }
            }
        }
    }

    /// Each button's word sits in the middle of its region, so the word under the pointer is
    /// the one that lights; a pointer over a name selects its wedge's last ring.
    func testTheWordUnderThePointerIsTheOneThatLights() {
        everyLayout { layout, what in
            let g = layout.geometry
            for word in layout.words {
                let middle = CGPoint(x: word.frame.midX, y: word.frame.midY)
                switch word.role {
                case .button(let i, let ring):
                    XCTAssertEqual(g.selection(at: middle), .wedge(index: i, ring: ring), "\(what): \(word.role)")
                    let band = g.band(ring, of: i)
                    XCTAssertEqual(RadialGeometry.radius(of: middle), (band.r0 + band.r1) / 2, accuracy: 0.01, "\(what)")
                case .name(let i):
                    let anchor = CGPoint(x: g.nameRadius * CGFloat(sin(g.centerAngle(of: i))),
                                         y: g.nameRadius * CGFloat(cos(g.centerAngle(of: i))))
                    XCTAssertEqual(g.selection(at: anchor), .wedge(index: i, ring: g.lastRing(of: i)), "\(what): \(word.role)")
                case .centre:
                    XCTAssertEqual(g.selection(at: middle), .cancel)
                case .digit:
                    break
                }
            }
        }
    }

    /// Along a horizontal spoke the words sit side by side, so every ring is at least as deep
    /// as its widest label; with many wedges the rings move out, the dead zone stays.
    func testEachRingIsDeepEnoughForItsLabelOnAHorizontalSpoke() {
        everyLayout { layout, what in
            let g = layout.geometry
            for word in layout.words {
                guard case .button(let i, let ring) = word.role else { continue }
                let band = g.band(ring, of: i)
                XCTAssertGreaterThanOrEqual(band.r1 - band.r0, word.frame.width, "\(what): \(word.fit.lines)")
            }
        }
        let few = RadialLayout(wedges: Self.wedges(6, Self.short)).geometry
        let many = RadialLayout(wedges: Self.wedges(12, Self.short)).geometry
        XCTAssertEqual(few.deadZone, many.deadZone)
        XCTAssertGreaterThan(many.innerEdge, few.innerEdge)
    }

    /// The button under the pointer grows about its own centre and still touches no other word,
    /// even along a horizontal spoke where a wedge's words sit side by side.
    func testAGrownButtonTouchesNoOtherWord() {
        everyLayout { layout, what in
            for button in layout.words {
                guard case .button = button.role else { continue }
                let f = button.frame
                let grown = f.insetBy(dx: -f.width * (RadialWheelView.grow - 1) / 2, dy: -f.height * (RadialWheelView.grow - 1) / 2)
                for other in layout.words where other.role != button.role {
                    XCTAssertFalse(grown.intersects(other.frame), "\(what): \(button.fit.lines) grown and \(other.fit.lines)")
                }
            }
        }
    }

    /// A name is anchored at the name radius and grows away from the centre: on the right half
    /// it starts at its anchor, on the left half it ends there, at the top and the bottom it is
    /// centred on it; above the centre it sits above its anchor, below it under it.
    func testNamesGrowAwayFromTheCentre() {
        everyLayout { layout, what in
            let g = layout.geometry
            for word in layout.words {
                guard case .name(let i) = word.role else { continue }
                let a = g.centerAngle(of: i)
                let anchor = CGPoint(x: g.nameRadius * CGFloat(sin(a)), y: g.nameRadius * CGFloat(cos(a)))
                let f = word.frame
                XCTAssertGreaterThanOrEqual(Self.distance(to: f), g.outerEdge, "\(what): \(word.fit.lines)")
                if sin(a) > 0.6 { XCTAssertEqual(f.minX, anchor.x, accuracy: 0.01, "\(what): right half starts at its anchor") }
                if sin(a) < -0.6 { XCTAssertEqual(f.maxX, anchor.x, accuracy: 0.01, "\(what): left half ends at its anchor") }
                if abs(sin(a)) < 0.01 { XCTAssertEqual(f.midX, anchor.x, accuracy: 0.01, "\(what): centred at the top or bottom") }
                if cos(a) > 0.6 { XCTAssertEqual(f.minY, anchor.y, accuracy: 0.01, "\(what): above its anchor") }
                if cos(a) < -0.6 { XCTAssertEqual(f.maxY, anchor.y, accuracy: 0.01, "\(what): under its anchor") }
            }
        }
    }

    /// Short names and every button label read whole at full size; a long name wraps to two
    /// lines; every line of every word lies inside its frame.
    func testWordsAreWholeWhereTheyFitAndInsideTheirFrames() {
        everyLayout { layout, what in
            for word in layout.words {
                for line in word.fit.lines {
                    XCTAssertLessThanOrEqual(TextFit.width(line, font: word.font), word.frame.width + 0.01, "\(what): \(line)")
                }
                XCTAssertLessThanOrEqual(word.textHeight, word.frame.height + 0.01, "\(what): \(word.role)")
                if case .button = word.role {
                    XCTAssertFalse(word.fit.truncated, "\(what): \(word.fit.lines)")
                    XCTAssertEqual(word.fit.lines.count, 1, "\(what): \(word.fit.lines)")
                    XCTAssertEqual(word.fit.size, word.style.preferred, "\(what): \(word.fit.lines)")
                }
            }
        }
        for count in Self.counts {
            let layout = RadialLayout(wedges: Self.wedges(count, Self.short))
            for word in layout.words where word.role.isName {
                XCTAssertEqual(word.fit.lines.count, 1, "\(count) wedges: \(word.fit.lines)")
                XCTAssertFalse(word.fit.truncated)
                XCTAssertEqual(word.fit.size, word.style.preferred)
            }
            let long = RadialLayout(wedges: Self.wedges(count, ["Morning research and writing"]))
            let name = long.words.first { $0.role == .name(0) }
            XCTAssertEqual(name?.fit.lines, ["Morning research", "and writing"], "\(count) wedges")
        }
    }

    /// App icons sit in a row with the name on wheels of up to eight wedges, none beyond.
    func testIconsShowUpToEightWedges() {
        for count in Self.counts {
            let layout = RadialLayout(wedges: Self.wedges(count, Self.short, icons: 7))
            let icons = layout.words.filter(\.role.isName).map(\.icons)
            if count <= 8 {
                XCTAssertEqual(icons.max(), RadialLayout.maxIcons, "\(count) wedges")
            } else {
                XCTAssertEqual(icons.max(), 0, "\(count) wedges")
            }
        }
    }

    // MARK: The hint

    /// The hint sits under every word, inside the field, on up to two lines inside its zone.
    func testTheHintSitsUnderTheWheelAndIsNeverClipped() {
        everyLayout { layout, what in
            for word in layout.words { XCTAssertGreaterThanOrEqual(word.frame.minY, layout.hintZone.maxY, "\(what): \(word.role)") }
            for hint in ["Apply Code", RadialMenu.idleHint,
                         "Clear this screen and apply Quarterly planning with the whole design and research team",
                         "Park Safari · " + String(repeating: "A rather long page title ", count: 8)] {
                let fit = layout.fitHint(hint)
                XCTAssertLessThanOrEqual(fit.lines.count, 2)
                XCTAssertLessThanOrEqual(CGFloat(fit.lines.count) * layout.hintLineHeight(fit), layout.hintZone.height + 0.01)
                for line in fit.lines {
                    XCTAssertLessThanOrEqual(TextFit.width(line, font: layout.hintStyle.font(fit.size)), layout.hintZone.width + 0.01, hint)
                }
            }
        }
    }

    // MARK: The field

    /// Every word, and the hint's zone, lies where the field is strong enough to read on.
    func testEveryWordLiesWhereTheFieldIsStrongEnoughToReadOn() {
        everyLayout { layout, what in
            for reduced in [false, true] {
                let field = RadialField(layout: layout, reduced: reduced)
                for (role, frame) in layout.words.map({ ("\($0.role)", $0.frame) }) + [("hint", layout.hintZone)] {
                    for x in stride(from: frame.minX, through: frame.maxX, by: max(1, frame.width / 6)) {
                        for y in [frame.minY, frame.midY, frame.maxY] {
                            XCTAssertGreaterThanOrEqual(field.alpha(at: CGPoint(x: x, y: y)), RadialField.readable,
                                                        "\(what)\(reduced ? ", reduced" : ""): \(role)")
                        }
                    }
                }
            }
        }
    }

    /// The field is strongest in the middle and fades to nothing inside the canvas, with no
    /// step anywhere along a line out from the centre.
    func testTheFieldFadesToNothingWithoutAnEdge() {
        everyLayout { layout, what in
            for reduced in [false, true] {
                let field = RadialField(layout: layout, reduced: reduced)
                XCTAssertEqual(field.alpha(at: .zero), 1, accuracy: 0.001, what)
                let s = field.support
                for x in stride(from: s.minX, through: s.maxX, by: 8) {
                    XCTAssertEqual(field.alpha(at: CGPoint(x: x, y: s.minY)), 0, what)
                    XCTAssertEqual(field.alpha(at: CGPoint(x: x, y: s.maxY)), 0, what)
                }
                for y in stride(from: s.minY, through: s.maxY, by: 8) {
                    XCTAssertEqual(field.alpha(at: CGPoint(x: s.minX, y: y)), 0, what)
                    XCTAssertEqual(field.alpha(at: CGPoint(x: s.maxX, y: y)), 0, what)
                }
                for degrees in stride(from: 0.0, to: 360, by: 7.5) {
                    let a = degrees * .pi / 180
                    var previous = field.alpha(at: .zero)
                    for r in stride(from: 1.0, through: Double(max(s.width, s.height)), by: 1) {
                        let p = CGPoint(x: r * sin(a), y: r * cos(a))
                        let value = field.alpha(at: p)
                        XCTAssertLessThan(abs(value - previous), 0.04, "\(what): a step at \(Int(degrees))° r \(Int(r))")
                        previous = value
                    }
                }
            }
        }
    }

    /// With Reduce transparency on, the field is a plain soft disc: its strength depends on the
    /// distance from the centre only.
    func testWithReduceTransparencyTheFieldIsASoftDisc() {
        let layout = RadialLayout(wedges: Self.wedges(8, Self.long))
        let field = RadialField(layout: layout, reduced: true)
        for r in stride(from: 0.0, through: Double(field.support.width / 2), by: 9) {
            let values = stride(from: 0.0, to: 360, by: 15).map { degrees -> CGFloat in
                let a = degrees * .pi / 180
                return field.alpha(at: CGPoint(x: r * sin(a), y: r * cos(a)))
            }
            XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 0.001, "radius \(r)")
        }
    }

    /// The pictures the window draws from: a mask of the field, and the wheel's own tint, both
    /// zero at the canvas's edge, the tint strongest in the middle.
    func testTheFieldsImagesFadeToNothingAtTheCanvasEdge() throws {
        let field = RadialField(layout: RadialLayout(wedges: Self.wedges(6, Self.short)), reduced: false)
        for image in [field.maskImage, field.tintImage] {
            let rep = NSBitmapImageRep(cgImage: image)
            for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1),
                           (rep.pixelsWide / 2, 0), (0, rep.pixelsHigh / 2)] {
                XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent, 0, accuracy: 0.004)
            }
        }
        let tint = NSBitmapImageRep(cgImage: field.tintImage)
        let scale = CGFloat(tint.pixelsWide) / field.support.width
        let middle = try XCTUnwrap(tint.colorAt(x: Int(-field.support.minX * scale), y: Int(field.support.maxY * scale)))
        XCTAssertEqual(middle.alphaComponent, RadialField.tintAlpha(field: 1), accuracy: 0.01, "the wheel's centre")
        XCTAssertGreaterThan(RadialField.tintAlpha(field: 1), RadialField.tintAlpha(field: 0.5))
    }

    /// The total darkness over the blur (the backdrop's own tint and the wheel's) is the field's
    /// strength times `RadialField.darkness`: white words read on a white desktop.
    func testTheTintMakesWhiteWordsReadOnAWhiteDesktop() {
        for f in stride(from: 0.0, through: 1.0, by: 0.05) {
            let total = 1 - (1 - RadialBackdrop.ownTint * f) * (1 - RadialField.tintAlpha(field: f))
            XCTAssertEqual(total, RadialField.darkness * f, accuracy: 0.0001)
        }
        // White on white under the darkness where every word sits: at least 4.5 to 1.
        let shade = 1 - RadialField.darkness * RadialField.readable
        let luminance = shade <= 0.04045 ? shade / 12.92 : pow((shade + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5)
    }

    // MARK: The screen

    /// The wheel never outgrows the screen it opens on: on a 1024 by 640 display (a 13-inch at
    /// Larger Text, less the menu bar) or with a Dock at the bottom, with many wedges and long
    /// names, and wherever the pointer is, every word and the hint are on screen.
    func testTheWheelFitsTheScreenItOpensOn() {
        let screens = [CGRect(x: 0, y: 0, width: 1024, height: 616), CGRect(x: 0, y: 70, width: 1024, height: 546),
                       CGRect(x: 1024, y: -200, width: 1440, height: 875)]
        for visible in screens {
            for count in [3, 8, 12, 22] {
                let wedges = Self.wedges(count, Self.long, allScreens: true)
                for pointer in [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.maxY),
                                CGPoint(x: visible.midX, y: visible.minY + 3), CGPoint(x: visible.midX, y: visible.midY)] {
                    let placed = RadialMenu.place(wedges: wedges, at: pointer, visibleFrame: visible)
                    let words = placed.layout.bounds.offsetBy(dx: placed.center.x, dy: placed.center.y)
                    XCTAssertTrue(visible.insetBy(dx: 1, dy: 1).contains(words), "\(count) wedges at \(pointer) in \(visible): \(words)")
                    XCTAssertLessThanOrEqual(placed.layout.scale, 1)
                }
            }
        }
        let roomy = RadialMenu.place(wedges: Self.wedges(8, Self.long), at: CGPoint(x: 900, y: 500),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1100))
        XCTAssertEqual(roomy.layout.scale, 1, "full size where it fits")
        XCTAssertEqual(roomy.center, CGPoint(x: 900, y: 500), "centred on the pointer where it fits")
    }
}
