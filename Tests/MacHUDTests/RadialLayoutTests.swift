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

    /// Points over `frame`, a quarter point inside its edges: corners, edges and within.
    private static func over(_ frame: CGRect) -> [CGPoint] {
        let inner = frame.insetBy(dx: 0.25, dy: 0.25)
        var points: [CGPoint] = []
        for u in 0...8 {
            for v in 0...4 {
                points.append(CGPoint(x: inner.minX + inner.width * CGFloat(u) / 8, y: inner.minY + inner.height * CGFloat(v) / 4))
            }
        }
        return points
    }

    /// Each button's word sits in the middle of its region and lies wholly inside it, at rest
    /// and grown under the pointer, so the word under the pointer is the one that lights,
    /// wherever on the word the pointer is; a pointer anywhere over a name selects its wedge's
    /// last ring.
    func testTheWordUnderThePointerIsTheOneThatLights() {
        everyLayout { layout, what in
            let g = layout.geometry
            for word in layout.words {
                let middle = CGPoint(x: word.frame.midX, y: word.frame.midY)
                switch word.role {
                case .button(let i, let ring):
                    let band = g.band(ring, of: i)
                    XCTAssertEqual(RadialGeometry.radius(of: middle), (band.r0 + band.r1) / 2, accuracy: 0.01, "\(what)")
                    XCTAssertGreaterThanOrEqual(word.grow, RadialLayout.minimumGrow, "\(what): \(word.fit.lines)")
                    XCTAssertLessThanOrEqual(word.grow, RadialWheelView.grow, "\(what): \(word.fit.lines)")
                    for (state, frame) in [("resting", word.frame), ("grown", RadialLayout.grown(word.frame, by: word.grow))] {
                        for p in Self.over(frame) where g.selection(at: p) != .wedge(index: i, ring: ring) {
                            XCTFail("\(what): \(word.fit.lines) \(state) at \(p) selects \(g.selection(at: p))")
                            break
                        }
                    }
                case .name(let i):
                    for p in Self.over(word.frame) where g.selection(at: p) != .wedge(index: i, ring: g.lastRing(of: i)) {
                        XCTFail("\(what): name \(word.fit.lines) at \(p) selects \(g.selection(at: p))")
                        break
                    }
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
                let grown = RadialLayout.grown(f, by: button.grow)
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

    /// Every place a word can be: each word's box (a button's grown under the pointer, a name's
    /// with its icons), the digits, the centre and the hint's two-line zone.
    private static func places(_ layout: RadialLayout) -> [(String, CGRect)] {
        layout.words.map { word -> (String, CGRect) in
            if case .button = word.role { return ("\(word.role) grown", RadialLayout.grown(word.frame, by: word.grow)) }
            return ("\(word.role)", word.frame)
        } + [("hint", layout.hintZone)]
    }

    private static func samples(_ frame: CGRect) -> [CGPoint] {
        stride(from: frame.minX, through: frame.maxX, by: max(1, frame.width / 8)).flatMap { x in
            stride(from: frame.minY, through: frame.maxY, by: max(1, frame.height / 4)).map { CGPoint(x: x, y: $0) }
        }
    }

    /// Under every place a word can be the blur is full, so no sharp desktop shows through
    /// there, and the tint is strong enough to read on.
    func testUnderEveryWordTheBlurIsFullAndTheTintReads() {
        everyLayout { layout, what in
            for reduced in [false, true] {
                let field = RadialField(layout: layout, reduced: reduced)
                for (role, frame) in Self.places(layout) {
                    for p in Self.samples(frame) {
                        XCTAssertGreaterThanOrEqual(field.blur(at: p), 1 - 1 / 255, "\(what)\(reduced ? ", reduced" : ""): \(role) blur")
                        XCTAssertGreaterThanOrEqual(field.tint(at: p), RadialField.readable, "\(what)\(reduced ? ", reduced" : ""): \(role) tint")
                    }
                }
            }
        }
    }

    /// The blur's image, as the backdrop stretches it, is full (within one 8-bit step) over
    /// every place a word can be, the pixels around it included, since a stretched image
    /// blends its neighbouring pixels.
    func testTheBlurImageIsFullOverEveryWord() {
        everyLayout { layout, what in
            for reduced in [false, true] {
                let field = RadialField(layout: layout, reduced: reduced)
                let image = field.blurImage
                guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return XCTFail(what) }
                let step = field.support.width / CGFloat(image.width)
                for (role, frame) in Self.places(layout) {
                    let c0 = max(0, Int(((frame.minX - field.support.minX) / step).rounded(.down)) - 1)
                    let c1 = min(image.width - 1, Int(((frame.maxX - field.support.minX) / step).rounded(.up)) + 1)
                    let r0 = max(0, Int(((field.support.maxY - frame.maxY) / step).rounded(.down)) - 1)
                    let r1 = min(image.height - 1, Int(((field.support.maxY - frame.minY) / step).rounded(.up)) + 1)
                    var least: UInt8 = 255
                    for row in r0...r1 {
                        for column in c0...c1 { least = min(least, bytes[row * image.bytesPerRow + column * 4 + 3]) }
                    }
                    XCTAssertGreaterThanOrEqual(least, 254, "\(what)\(reduced ? ", reduced" : ""): \(role)")
                }
            }
        }
    }

    /// Both profiles fade to nothing inside the canvas with no step anywhere along a line out
    /// from the centre; the blur is full in the middle, and so is the tint, which is weaker
    /// toward the rim.
    func testTheFieldFadesToNothingWithoutAnEdge() {
        everyLayout { layout, what in
            for reduced in [false, true] {
                let field = RadialField(layout: layout, reduced: reduced)
                for (profile, value) in [("blur", field.blur), ("tint", field.tint)] as [(String, (CGPoint) -> CGFloat)] {
                    XCTAssertEqual(value(.zero), 1, accuracy: 0.001, "\(what) \(profile)")
                    let s = field.support
                    for x in stride(from: s.minX, through: s.maxX, by: 8) {
                        XCTAssertEqual(value(CGPoint(x: x, y: s.minY)), 0, "\(what) \(profile)")
                        XCTAssertEqual(value(CGPoint(x: x, y: s.maxY)), 0, "\(what) \(profile)")
                    }
                    for y in stride(from: s.minY, through: s.maxY, by: 8) {
                        XCTAssertEqual(value(CGPoint(x: s.minX, y: y)), 0, "\(what) \(profile)")
                        XCTAssertEqual(value(CGPoint(x: s.maxX, y: y)), 0, "\(what) \(profile)")
                    }
                    for degrees in stride(from: 0.0, to: 360, by: 15) {
                        let a = degrees * .pi / 180
                        var previous = value(.zero)
                        for r in stride(from: 1.0, through: Double(max(s.width, s.height)), by: 1) {
                            let next = value(CGPoint(x: r * sin(a), y: r * cos(a)))
                            XCTAssertLessThan(abs(next - previous), 0.04, "\(what) \(profile): a step at \(Int(degrees))° r \(Int(r))")
                            previous = next
                        }
                    }
                }
            }
        }
    }

    /// With Reduce transparency on, the field is a plain soft disc: both profiles depend on the
    /// distance from the centre only.
    func testWithReduceTransparencyTheFieldIsASoftDisc() {
        let layout = RadialLayout(wedges: Self.wedges(8, Self.long))
        let field = RadialField(layout: layout, reduced: true)
        for value in [field.blur, field.tint] as [(CGPoint) -> CGFloat] {
            for r in stride(from: 0.0, through: Double(field.support.width / 2), by: 9) {
                let values = stride(from: 0.0, to: 360, by: 15).map { degrees -> CGFloat in
                    let a = degrees * .pi / 180
                    return value(CGPoint(x: r * sin(a), y: r * cos(a)))
                }
                XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 0.001, "radius \(r)")
            }
        }
    }

    /// The pictures the window draws from, the blur's and the tint's, are zero at the canvas's
    /// edge and full in the middle.
    func testTheFieldsImagesFadeToNothingAtTheCanvasEdge() throws {
        let field = RadialField(layout: RadialLayout(wedges: Self.wedges(6, Self.short)), reduced: false)
        for image in [field.blurImage, field.tintImage] {
            let rep = NSBitmapImageRep(cgImage: image)
            for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1),
                           (rep.pixelsWide / 2, 0), (0, rep.pixelsHigh / 2)] {
                XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent, 0, accuracy: 0.004)
            }
            let scale = CGFloat(rep.pixelsWide) / field.support.width
            let middle = try XCTUnwrap(rep.colorAt(x: Int(-field.support.minX * scale), y: Int(field.support.maxY * scale)))
            XCTAssertEqual(middle.alphaComponent, 1, accuracy: 0.01, "full in the wheel's centre")
        }
    }

    /// Each image is its profile in black: the blur's alpha is the blur profile, the tint's the
    /// tint profile, whose strength is the tint view's darkness (`RadialBackdrop.darkness(for:)`).
    func testTheImagesAreTheProfiles() throws {
        let field = RadialField(layout: RadialLayout(wedges: Self.wedges(8, Self.long)), reduced: false)
        for (image, value) in [(field.blurImage, field.blur), (field.tintImage, field.tint)] as [(CGImage, (CGPoint) -> CGFloat)] {
            let rep = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(rep.pixelsWide) / field.support.width
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: -80), CGPoint(x: -200, y: 150), CGPoint(x: 0, y: -300),
                      CGPoint(x: 380, y: 260), CGPoint(x: -430, y: -330)] {
                let pixel = try XCTUnwrap(rep.colorAt(x: Int((p.x - field.support.minX) * scale), y: Int((field.support.maxY - p.y) * scale)))
                XCTAssertEqual(pixel.alphaComponent, value(p), accuracy: 0.03, "\(p)")
                XCTAssertEqual(pixel.redComponent + pixel.greenComponent + pixel.blueComponent, 0, accuracy: 0.01, "black")
            }
        }
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
