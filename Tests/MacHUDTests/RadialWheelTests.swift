import AppKit
import HUDKit
import XCTest
@testable import MacHUDCore

/// The wheel's glass bubbles: one around every word showing and none for what does not show,
/// the petal highlighted and the path to it lit, popping out as they appear (fading only with
/// Reduce motion), going fast, and never in the way of the selection. No window is shown.
@MainActor
final class RadialWheelTests: XCTestCase {
    private static let cases: [(tree: [RadialNode], what: String)] = [
        (RadialLayoutTests.tree(0, RadialLayoutTests.short, widgets: nil), "no loadouts, no widgets"),
        (RadialLayoutTests.tree(3, RadialLayoutTests.short, allScreens: true), "3 loadouts"),
        (RadialLayoutTests.tree(6, RadialLayoutTests.long), "6 long loadouts"),
        (RadialLayoutTests.tree(14, RadialLayoutTests.short), "14 loadouts"),
        (RadialLayoutTests.tree(20, RadialLayoutTests.long, allScreens: true), "20 long loadouts"),
    ]

    private func wheel(_ tree: [RadialNode], scale: CGFloat = 1) -> (RadialWheelView, RadialLayout) {
        let layout = RadialLayout(tree: tree, scale: scale)
        let canvas = RadialWheelView.canvas(for: layout)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: canvas.size))
        view.reducesMotion = { false }
        view.configure(layout: layout, canvas: canvas, tree: tree)
        return (view, layout)
    }

    private func bubble(_ view: RadialWheelView, _ path: [String]) -> RadialBubble? { view.bubble(.word(.node(path))) }

    /// Every path the pointer can take: each branch open, and each petal showing highlighted.
    private func selections(_ layout: RadialLayout) -> [[String]] {
        Array(Set(layout.branches.flatMap { [$0] + layout.showing(open: $0) }))
    }

    // MARK: What shows

    /// With any path highlighted, every petal showing has exactly one bubble, showing, whose
    /// frame holds its word (icons included); the centre's disc holds Esc / Cancel and the
    /// digits, the hint's bubble holds its line, and every other bubble is gone.
    func testEveryWordShowingHasOneBubbleThatHoldsIt() {
        for (tree, what) in Self.cases {
            let (view, layout) = wheel(tree)
            for selection in selections(layout) {
                view.settle(selection: selection)
                let showing = Set(layout.showing(open: layout.openBranch(selection)))
                var roles: [RadialBubble.Role] = []
                for bubble in view.showingBubbles {
                    roles.append(bubble.role)
                    XCTAssertFalse(bubble.isHidden, "\(what), \(selection): \(bubble.role)")
                    XCTAssertGreaterThan(bubble.alphaValue, 0.5, "\(what), \(selection): \(bubble.role)")
                    let frame = view.wheelFrame(of: bubble)
                    switch bubble.role {
                    case .word(.node(let path)):
                        XCTAssertTrue(showing.contains(path), "\(what), \(selection): \(path) does not show")
                        XCTAssertTrue(frame.contains(layout.word(path)!.frame), "\(what), \(selection): \(path)")
                    case .word(.centre):
                        for word in layout.words where word.role.path == nil {
                            XCTAssertTrue(frame.contains(word.frame), "\(what): the centre's disc holds \(word.role)")
                        }
                        XCTAssertLessThanOrEqual(frame.width / 2, layout.deadZone, "\(what): no bigger than the dead zone")
                    case .hint:
                        XCTAssertTrue(layout.hintZone(open: selection).insetBy(dx: -8, dy: -8).contains(frame), "\(what), \(selection)")
                    case .word(.digit):
                        XCTFail("the digits are in the centre's disc")
                    }
                }
                XCTAssertEqual(roles.count, Set(roles).count, "\(what), \(selection): one bubble each")
                XCTAssertEqual(Set(roles), Set(showing.map { .word(.node($0)) } + [.word(.centre), .hint]), "\(what), \(selection)")
                for path in layout.words.compactMap(\.role.path) where !showing.contains(path) {
                    if let gone = bubble(view, path) { XCTAssertTrue(gone.isHidden && !gone.isShowing, "\(what), \(selection): \(path)") }
                }
            }
        }
    }

    /// Bubbles that show together never touch at rest: the layout's room between words holds
    /// both bubbles' padding, the centre's disc keeps clear of the top petals, and the hint's
    /// bubble of every word above it.
    func testBubblesShowingTogetherNeverTouch() {
        for (tree, what) in Self.cases {
            for scale in [1, 0.79] as [CGFloat] {
                let (view, layout) = wheel(tree, scale: scale)
                for branch in layout.branches {
                    view.settle(selection: branch)
                    let frames = view.showingBubbles.map { ($0.role, view.wheelFrame(of: $0)) }
                    for (i, a) in frames.enumerated() {
                        for b in frames[(i + 1)...] where a.1.intersects(b.1) {
                            XCTFail("\(what) at \(scale), open \(branch): \(a.0) touches \(b.0)")
                        }
                    }
                }
            }
        }
    }

    /// The petal highlighted is lit: accent-tinted, its words at full strength, its border
    /// brighter, grown as far as its word grows and above its neighbours. The path to it stays
    /// lit, its siblings step back, and the rest are at rest.
    func testThePetalHighlightedIsLitAndThePathStaysLit() throws {
        let tree = RadialLayoutTests.tree(6, RadialLayoutTests.short)
        let (view, layout) = wheel(tree)
        view.settle(selection: ["loadouts", "Mail", "apply"])
        let lit = try XCTUnwrap(bubble(view, ["loadouts", "Mail", "apply"]))
        XCTAssertEqual(lit.emphasis, .lit)
        XCTAssertEqual(lit.scale, layout.word(["loadouts", "Mail", "apply"])!.grow)
        XCTAssertGreaterThan(lit.scale, 1)
        XCTAssertEqual(lit.wordOpacity, 1)
        XCTAssertEqual(lit.layer?.zPosition, 1)
        XCTAssertEqual(lit.tintColor, RadialGlass.tint(.lit))
        XCTAssertNotEqual(RadialGlass.tint(.lit), RadialGlass.tint(.rest))
        for path in [["loadouts"], ["loadouts", "Mail"]] {
            let on = try XCTUnwrap(bubble(view, path))
            XCTAssertEqual(on.emphasis, .path, "\(path)")
            XCTAssertEqual(on.tintColor, RadialGlass.tint(.path))
            XCTAssertEqual(on.wordOpacity, 1)
        }
        XCTAssertEqual(bubble(view, ["loadouts", "Mail", "clear"])?.emphasis, .receded)
        XCTAssertEqual(bubble(view, ["loadouts", "Code"])?.emphasis, .beyond, "the path has gone on past it")
        XCTAssertEqual(bubble(view, ["capture"])?.emphasis, .beyond)
        XCTAssertEqual(bubble(view, ["capture"])?.wordOpacity, RadialGlass.beyondText, "its words step back")
        XCTAssertEqual(bubble(view, ["capture"])?.alphaValue, 1, "its glass does not")
        XCTAssertEqual(bubble(view, ["loadouts", "Mail", "clear"])?.scale, 1)
        let rest = try XCTUnwrap(bubble(view, ["park"]))
        view.settle(selection: [])
        XCTAssertEqual(rest.emphasis, .rest)
        XCTAssertEqual(rest.tintColor, RadialGlass.tint(.rest))
        XCTAssertEqual(rest.wordOpacity, RadialGlass.restText)
        XCTAssertEqual(view.bubble(.word(.centre))?.picture("cancel")?.opacity, 1, "nothing highlighted: Cancel")
        view.settle(selection: ["park"])
        XCTAssertEqual(view.bubble(.word(.centre))?.picture("esc")?.opacity ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(view.bubble(.word(.centre))?.picture("cancel")?.opacity, 0)
    }

    /// A white word reads at better than 4.5 to 1 in its bubble over a white desktop: the
    /// glass's tint and the wheel's over the blur, with the gloss's brightest band (white at
    /// 28 %) a third of the way over it.
    func testWhiteWordsReadOnAWhiteDesktop() {
        let shade = (1 - RadialGlass.glassTint) * (1 - RadialGlass.restTint)
        let glossed = shade + (1 - shade) * 0.28 / 3
        let luminance = glossed <= 0.04045 ? glossed / 12.92 : pow((glossed + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5)
    }

    // MARK: Popping out

    /// The bloom is a spring from 0.6 to 1 with a small overshoot, over about a quarter of a second.
    func testTheBloomSpringsOutWithASmallOvershoot() {
        let samples = RadialMotion.spring(from: RadialMotion.bloomFrom, to: 1)
        XCTAssertEqual(samples.first, 0.6)
        XCTAssertEqual(samples.last, 1)
        let peak = samples.max() ?? 0
        XCTAssertGreaterThan(peak, 1.01)
        XCTAssertLessThan(peak, 1.08)
        XCTAssertEqual(Double(samples.count - 1) * RadialMotion.step, RadialMotion.bloomDuration, accuracy: 0.01)
        XCTAssertEqual(samples[samples.count - 2], 1, accuracy: 0.01, "settled before it ends")
    }

    /// The bloom of a bubble's layer, as its sizes.
    private func bloom(_ bubble: RadialBubble?) -> (begin: CFTimeInterval, sizes: [CGFloat])? {
        guard let animation = bubble?.layer?.animation(forKey: "scale") as? CAKeyframeAnimation,
              let values = animation.values as? [NSValue] else { return nil }
        return (animation.beginTime, values.map { $0.caTransform3DValue.m11 })
    }

    private func fade(_ bubble: RadialBubble?) -> CABasicAnimation? { bubble?.layer?.animation(forKey: "opacity") as? CABasicAnimation }

    /// Opening the wheel pops the centre out, then the top petals, then the hint, each fading
    /// in as it springs from 0.6 of its size.
    func testOpeningPopsTheCentreAndTheTopPetalsOut() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.open()
        let centre = try XCTUnwrap(bloom(view.bubble(.word(.centre))))
        let top = try XCTUnwrap(bloom(bubble(view, ["capture"])))
        let hint = try XCTUnwrap(bloom(view.bubble(.hint)))
        for sizes in [centre.sizes, top.sizes, hint.sizes] {
            XCTAssertEqual(sizes.first ?? 0, 0.6, accuracy: 0.001)
            XCTAssertEqual(sizes.last, 1)
            XCTAssertGreaterThan(sizes.max() ?? 0, 1)
        }
        XCTAssertLessThan(centre.begin, top.begin)
        XCTAssertLessThan(top.begin, hint.begin)
        XCTAssertEqual(try XCTUnwrap(fade(bubble(view, ["capture"]))).fromValue as? Float, 0)
        XCTAssertEqual(bubble(view, ["capture"])?.isShowing, true)
        XCTAssertEqual(bubble(view, ["capture"])?.alphaValue, 1, "its own opacity is where it ends")
    }

    /// A branch unfolding pops its children out after it, outward: jumping to a loadout's
    /// action pops the loadouts out and then that loadout's actions; an outer row of loadouts
    /// follows the inner one. The petal highlighted springs to its grown size.
    func testABranchUnfoldsOutward() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(10, RadialLayoutTests.short))
        view.open()
        view.selection = ["loadouts", "Code", "apply"]
        let inner = try XCTUnwrap(bloom(bubble(view, ["loadouts", "Mail"])))
        let outer = try XCTUnwrap(bloom(bubble(view, ["loadouts", "Chat"])))
        let action = try XCTUnwrap(bloom(bubble(view, ["loadouts", "Code", "preview"])))
        XCTAssertLessThan(inner.begin, outer.begin, "the outer row after the inner")
        XCTAssertLessThan(inner.begin, action.begin, "a loadout's actions after the loadouts")
        XCTAssertGreaterThan(try XCTUnwrap(bloom(bubble(view, ["loadouts", "Code", "apply"]))).sizes.last ?? 0, 1, "lit, it grows")
        XCTAssertLessThan(action.begin - inner.begin, 0.2, "slightly")
    }

    /// A bubble going away shrinks and fades in about 0.12 s; one coming back while it goes
    /// pops out again from where it is.
    func testABubbleGoingAwayShrinksAndFadesFast() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.open()
        view.selection = ["loadouts"]
        let mail = try XCTUnwrap(bubble(view, ["loadouts", "Mail"]))
        view.selection = ["park"]
        XCTAssertFalse(mail.isShowing)
        XCTAssertEqual(mail.alphaValue, 0, "gone, as far as anything but the screen is concerned")
        let out = try XCTUnwrap(fade(mail))
        XCTAssertEqual(out.duration, 0.12, accuracy: 0.001)
        XCTAssertEqual(out.toValue as? Float, 0)
        let shrink = try XCTUnwrap(mail.layer?.animation(forKey: "scale") as? CABasicAnimation)
        XCTAssertEqual(shrink.duration, 0.12, accuracy: 0.001)
        XCTAssertLessThan((shrink.toValue as? NSValue)?.caTransform3DValue.m11 ?? 1, 1)
        view.selection = ["loadouts"]
        XCTAssertTrue(mail.isShowing)
        XCTAssertNotNil(bloom(mail))
    }

    /// With Reduce motion on, bubbles only fade: no spring and no shrink, coming or going, and a
    /// petal highlighted takes its grown size at once.
    func testWithReduceMotionBubblesOnlyFade() throws {
        let (view, layout) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.reducesMotion = { true }
        view.open()
        view.selection = ["loadouts", "Mail"]
        for path in [["capture"], ["loadouts", "Mail"], ["loadouts", "Mail", "apply"]] {
            let b = try XCTUnwrap(bubble(view, path))
            XCTAssertNil(b.layer?.animation(forKey: "scale"), "\(path)")
            XCTAssertNotNil(fade(b), "\(path) fades in")
            XCTAssertEqual(b.layer?.sublayerTransform.m11 ?? 0, b.scale, accuracy: 0.0001)
        }
        XCTAssertEqual(bubble(view, ["loadouts", "Mail"])?.layer?.sublayerTransform.m11 ?? 0,
                       layout.word(["loadouts", "Mail"])!.grow, accuracy: 0.0001)
        let code = try XCTUnwrap(bubble(view, ["loadouts", "Code"]))
        view.selection = ["park"]
        XCTAssertNil(code.layer?.animation(forKey: "scale"))
        XCTAssertEqual(fade(code)?.toValue as? Float, 0)
    }

    /// Selecting acts on the layout at once, whatever the bubbles are doing: the branch's
    /// children are showing and a release does the action from the moment it is highlighted,
    /// while they are still popping out.
    func testTheSelectionNeverWaitsForTheBubbles() throws {
        let menu = RadialMenu()
        menu.warpPointer = { _ in }
        menu.wheel.reducesMotion = { false }
        let display = RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900)
        menu.prepare(tree: RadialLayoutTests.tree(3, RadialLayoutTests.short), at: .zero, on: display, movesPointer: false)
        menu.wheel.open()
        XCTAssertTrue(menu.select(path: ["loadouts", "Mail", "apply"]))
        XCTAssertEqual(menu.releaseOutcome, .apply(loadout: "Mail", clear: false))
        let apply = try XCTUnwrap(bubble(menu.wheel, ["loadouts", "Mail", "apply"]))
        XCTAssertTrue(apply.isShowing)
        XCTAssertEqual(apply.emphasis, .lit)
        XCTAssertNotNil(apply.layer?.animation(forKey: "scale"), "still popping out")
        // The pointer on a word that is still popping out picks it.
        let word = menu.layout.word(["loadouts", "Mail", "clear"])!
        menu.pointerMoved(to: CGPoint(x: menu.center.x + 60, y: menu.center.y + 60), delta: CGVector(dx: 1, dy: 1))
        menu.pointerMoved(to: CGPoint(x: menu.center.x + word.frame.midX, y: menu.center.y + word.frame.midY), delta: CGVector(dx: 1, dy: 1))
        XCTAssertEqual(menu.selection, ["loadouts", "Mail", "clear"])
        XCTAssertEqual(bubble(menu.wheel, ["loadouts", "Mail", "clear"])?.emphasis, .lit)
    }

    /// Every bubble is HUDKit's glass on the window server's blur, with the family's border, its
    /// corners a capsule's for one line and rounder than its words' for more.
    func testEveryBubbleIsTheFamilysGlass() {
        let (view, layout) = wheel(RadialLayoutTests.tree(6, RadialLayoutTests.long))
        view.settle(selection: ["loadouts", "dev: Browsers"])
        for bubble in view.showingBubbles {
            let style = bubble.glass.style
            XCTAssertEqual(style.material, .windowBlur)
            XCTAssertFalse(style.gloss, "the bubble draws the gloss over its own tint")
            XCTAssertLessThanOrEqual(style.cornerRadius, bubble.frame.height / 2 + 0.001)
            if bubble.role == .word(.centre) {
                XCTAssertEqual(style.cornerRadius, bubble.frame.height / 2, accuracy: 0.001, "a disc")
                XCTAssertEqual(bubble.frame.width, bubble.frame.height)
            } else {
                XCTAssertEqual(style.cornerRadius, min(bubble.frame.height / 2, RadialGlass.corner * layout.scale), accuracy: 0.001)
            }
            XCTAssertTrue(bubble.glass.subviews.contains { $0 is HUDGlossView })
        }
    }

    // MARK: Pictures, closing and layouts

    /// The picture a bubble shows for its word.
    private func picture(_ bubble: RadialBubble?) -> CGImage? {
        guard let layer = bubble?.face.layer?.sublayers?.first(where: { $0.name == nil }), let contents = layer.contents else { return nil }
        return (contents as! CGImage)
    }

    /// The red of the picture's pixel at the middle of its icon row's first icon.
    private func iconRed(_ image: CGImage, bubble: RadialBubble, word: RadialLayout.Word, wheel: RadialWheelView) -> CGFloat? {
        let rep = NSBitmapImageRep(cgImage: image)
        let frame = wheel.wheelFrame(of: bubble)
        let s = word.frame.minY - frame.minY
        let side = RadialLayout.iconSize
        let row = CGFloat(word.icons) * side + CGFloat(word.icons - 1) * RadialLayout.iconSpacing
        let x = word.frame.midX - row / 2 + side / 2 - frame.minX
        let y = s + side / 2
        let pixels = CGFloat(image.width) / frame.width
        return rep.colorAt(x: Int(x * pixels), y: Int((frame.height - y) * pixels))?.redComponent
    }

    private static func swatch(_ colour: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            colour.setFill()
            rect.fill()
            return true
        }
    }

    /// A loadout whose app changes, with as many icons as before, shows its new icon the next
    /// time it shows: the layout is the same, the picture is not.
    func testALoadoutsNewIconShowsTheNextTimeItShows() throws {
        func tree(_ colour: NSColor) -> [RadialNode] {
            RadialMenu.tree(loadouts: ["Code", "Mail", "Notes"].map { .init(name: $0, icons: [Self.swatch(colour), Self.swatch(colour)]) },
                            offersAllScreens: false, park: .init(), widgets: .init())
        }
        let red = tree(.red), blue = tree(.blue)
        let layout = RadialLayout(tree: red)
        XCTAssertEqual(RadialLayout(tree: blue), layout, "the same layout")
        let canvas = RadialWheelView.canvas(for: layout)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: canvas.size))
        view.configure(layout: layout, canvas: canvas, tree: red)
        view.settle(selection: ["loadouts"])
        let mail = try XCTUnwrap(bubble(view, ["loadouts", "Mail"]))
        let word = try XCTUnwrap(layout.word(["loadouts", "Mail"]))
        let before = try XCTUnwrap(picture(mail))
        XCTAssertGreaterThan(try XCTUnwrap(iconRed(before, bubble: mail, word: word, wheel: view)), 0.8, "red")
        view.close()
        view.configure(layout: RadialLayout(tree: blue), canvas: canvas, tree: blue, selection: [])
        view.settle(selection: ["loadouts"])
        let after = try XCTUnwrap(picture(bubble(view, ["loadouts", "Mail"])))
        XCTAssertFalse(after === before)
        XCTAssertLessThan(try XCTUnwrap(iconRed(after, bubble: mail, word: word, wheel: view)), 0.2, "blue now")
    }

    /// Closed while a bubble is going away, the wheel hides it at once with nothing left
    /// running, and reopened it never resumes mid-exit: the bubble stays gone until its word
    /// shows again, then pops out from the start.
    func testClosingDuringAnExitThenReopeningStartsAfresh() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.open()
        view.selection = ["loadouts"]
        let mail = try XCTUnwrap(bubble(view, ["loadouts", "Mail"]))
        view.selection = ["park"]
        XCTAssertNotNil(fade(mail), "going away")
        view.close()
        for bubble in [mail] + view.showingBubbles {
            XCTAssertTrue(bubble.isHidden, "\(bubble.role)")
            XCTAssertNil(bubble.layer?.animationKeys(), "\(bubble.role): nothing running")
        }
        XCTAssertTrue(view.showingBubbles.isEmpty)
        view.selection = []
        view.open()
        XCTAssertTrue(mail.isHidden)
        XCTAssertFalse(mail.isShowing)
        XCTAssertNil(mail.layer?.animationKeys(), "not resumed")
        view.selection = ["loadouts"]
        XCTAssertEqual(try XCTUnwrap(bloom(mail)).sizes.first ?? 0, RadialMotion.bloomFrom, accuracy: 0.001, "from the start")
        XCTAssertEqual(fade(mail)?.fromValue as? Float, 0)
    }

    /// A new layout replaces every bubble: none of the old ones is left in the view.
    func testANewLayoutLeavesNoBubbleBehind() {
        let (view, _) = wheel(RadialLayoutTests.tree(6, RadialLayoutTests.short))
        view.settle(selection: ["loadouts", "Mail", "apply"])
        let old = view.subviews.compactMap { $0 as? RadialBubble }
        XCTAssertFalse(old.isEmpty)
        let tree = RadialLayoutTests.tree(10, RadialLayoutTests.long)
        let layout = RadialLayout(tree: tree)
        view.configure(layout: layout, canvas: RadialWheelView.canvas(for: layout), tree: tree, selection: ["loadouts"])
        let now = view.subviews.compactMap { $0 as? RadialBubble }
        XCTAssertTrue(old.allSatisfy { $0.superview == nil }, "the old bubbles are gone")
        XCTAssertEqual(view.subviews.count, now.count + 1, "nothing else in the view but the stems'")
        for bubble in now { XCTAssertTrue(view.bubble(bubble.role) === bubble, "\(bubble.role) is the layout's") }
        XCTAssertEqual(Set(now.filter(\.isShowing).map(\.role)),
                       Set(layout.showing(open: ["loadouts"]).map { .word(.node($0)) } + [.word(.centre), .hint]))
    }

    /// A change of backing scale draws every picture showing again at the new scale.
    func testABackingScaleChangeRedrawsThePictures() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.backingScale = 2
        view.settle(selection: ["loadouts"])
        let mail = try XCTUnwrap(bubble(view, ["loadouts", "Mail"]))
        let before = try XCTUnwrap(picture(mail))
        let renders = view.wordRenders
        view.backingScale = 1
        view.viewDidChangeBackingProperties()
        let after = try XCTUnwrap(picture(mail))
        XCTAssertFalse(after === before)
        XCTAssertEqual(after.width, before.width / 2, accuracy: 1)
        XCTAssertEqual(mail.face.layer?.sublayers?.first { $0.name == nil }?.contentsScale, 1)
        XCTAssertEqual(view.bubble(.word(.centre))?.picture("esc")?.contentsScale, 1)
        XCTAssertEqual(view.bubble(.hint)?.picture("hint")?.contentsScale, 1)
        XCTAssertGreaterThan(view.wordRenders, renders)
        XCTAssertEqual(mail.face.layer?.sublayers?.filter { $0.name == nil }.count, 1, "one picture, not two")
    }

    /// A petal under the pointer grows only as far as its bubble stays off every other bubble
    /// showing, the centre's disc and the hint's included: with 3, 6, 10 and 14 long-named
    /// loadouts, in every state the pointer can light.
    func testALitBubbleNeverCoversAnother() {
        for count in [3, 6, 10, 14] {
            let (view, layout) = wheel(RadialLayoutTests.tree(count, RadialLayoutTests.long, allScreens: true))
            for selection in selections(layout) where !selection.isEmpty {
                view.settle(selection: selection)
                guard let lit = bubble(view, selection) else { continue }
                let frame = view.wheelFrame(of: lit)
                let grown = RadialLayout.grown(frame, by: lit.scale, about: CGPoint(x: frame.minX + lit.pivot.x, y: frame.minY + lit.pivot.y))
                for other in view.showingBubbles where other !== lit {
                    let o = view.wheelFrame(of: other)
                    let covered = o.intersection(grown)
                    if !covered.isNull, covered.width > 0.01, covered.height > 0.01 {
                        XCTFail("\(count) loadouts, \(selection) lit covers \(other.role) by \(covered.size)")
                    }
                }
            }
        }
    }

    // MARK: Stems

    /// Every action showing has a stem from its branch's bubble to its own, starting on the
    /// branch's bubble and ending on the action's; nothing else has one, and a stem goes with its
    /// action. The stem to the petal on the path is lit.
    func testEveryActionShowingHasAStemFromItsBranch() throws {
        for (tree, what) in Self.cases {
            let (view, layout) = wheel(tree)
            for selection in selections(layout) {
                view.settle(selection: selection)
                let showing = Set(layout.showing(open: layout.openBranch(selection)))
                for word in layout.words {
                    guard let path = word.role.path, let node = RadialMenu.node(at: path, in: tree) else { continue }
                    let stem = view.stem(path)
                    guard node.isLeaf, showing.contains(path) else {
                        XCTAssertTrue(stem.map { !$0.isShowing } ?? true, "\(what), \(selection): no stem to \(path)")
                        continue
                    }
                    let shown = try XCTUnwrap(stem, "\(what), \(selection): a stem to \(path)")
                    XCTAssertTrue(shown.isShowing)
                    let branch = try XCTUnwrap(bubble(view, Array(path.dropLast())))
                    let leaf = try XCTUnwrap(bubble(view, path))
                    let (start, end) = (shown.start, shown.end)
                    func onEdge(_ p: CGPoint, _ frame: CGRect) -> Bool {
                        frame.insetBy(dx: -1.5, dy: -1.5).contains(p) && !frame.insetBy(dx: 1.5, dy: 1.5).contains(p)
                    }
                    XCTAssertTrue(onEdge(start, branch.frame), "\(what): \(path)'s stem starts on its branch")
                    XCTAssertTrue(onEdge(end, leaf.frame), "\(what): \(path)'s stem ends on it")
                    XCTAssertEqual(shown.isLit, !selection.isEmpty && selection.starts(with: path), "\(what), \(selection): \(path)")
                }
            }
        }
    }

    private func grow(_ stem: RadialStem?) -> CABasicAnimation? { stem?.core.animation(forKey: "unfurl") as? CABasicAnimation }

    /// A branch opening unfurls its stems out from it, and each leaf pops out at its stem's tip
    /// once the stem gets there, one after another along the branch.
    func testABranchUnfurlsItsStemsThenPopsItsLeaves() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short, allScreens: true))
        view.open()
        view.selection = ["capture"]
        var previous: CFTimeInterval = 0
        for id in ["screen", "all", "draw"] {
            let stem = try XCTUnwrap(view.stem(["capture", id]))
            let unfurl = try XCTUnwrap(grow(stem), id)
            XCTAssertEqual(unfurl.keyPath, "strokeEnd")
            XCTAssertEqual(unfurl.fromValue as? CGFloat, 0)
            XCTAssertEqual(unfurl.toValue as? CGFloat, 1)
            XCTAssertGreaterThanOrEqual(unfurl.duration, 0.15)
            XCTAssertLessThanOrEqual(unfurl.duration, 0.2)
            let leaf = try XCTUnwrap(bloom(bubble(view, ["capture", id])))
            XCTAssertGreaterThanOrEqual(leaf.begin, unfurl.beginTime + unfurl.duration * 0.6, "\(id) pops at the tip")
            XCTAssertGreaterThan(leaf.begin, previous, "\(id) after the one before")
            previous = leaf.begin
        }
        XCTAssertEqual(view.stem(["capture", "screen"])?.core.strokeEnd, 1, "where it ends")
    }

    /// A branch closing draws its stems back fast; with Reduce motion stems only fade, coming and going.
    func testStemsDrawBackFastAndOnlyFadeWithReduceMotion() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.open()
        view.selection = ["park"]
        let stem = try XCTUnwrap(view.stem(["park", "restore"]))
        view.selection = ["capture"]
        XCTAssertFalse(stem.isShowing)
        let back = try XCTUnwrap(grow(stem))
        XCTAssertEqual(back.toValue as? CGFloat, 0)
        XCTAssertLessThanOrEqual(back.duration, 0.12)

        let (calm, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        calm.reducesMotion = { true }
        calm.open()
        calm.selection = ["park"]
        let still = try XCTUnwrap(calm.stem(["park", "park"]))
        XCTAssertNil(grow(still), "no growing")
        XCTAssertEqual(still.core.strokeEnd, 1)
        XCTAssertEqual((still.core.animation(forKey: "opacity") as? CABasicAnimation)?.fromValue as? Float, 0, "it fades in")
        calm.selection = ["capture"]
        XCTAssertNil(grow(still), "no drawing back")
        XCTAssertEqual((still.core.animation(forKey: "opacity") as? CABasicAnimation)?.toValue as? Float, 0, "it fades out")
    }

    /// The stems sit under every bubble, in the wheel's own view, and a closed wheel shows none.
    func testStemsSitUnderTheBubblesAndGoWithTheWheel() throws {
        let (view, _) = wheel(RadialLayoutTests.tree(3, RadialLayoutTests.short))
        view.open()
        view.selection = ["loadouts", "Mail", "apply"]
        let stem = try XCTUnwrap(view.stem(["loadouts", "Mail", "apply"]))
        let host = try XCTUnwrap(view.subviews.first)
        XCTAssertFalse(host is RadialBubble, "the stems' view is below every bubble")
        XCTAssertTrue(stem.core.superlayer === host.layer)
        view.close()
        XCTAssertFalse(stem.isShowing)
        XCTAssertTrue(stem.core.isHidden)
        XCTAssertNil(stem.core.animationKeys())
    }
}
