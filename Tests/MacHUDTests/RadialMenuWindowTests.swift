import AppKit
import HUDKit
import XCTest
@testable import MacHUDCore

final class RadialMenuWindowTests: XCTestCase {
    /// The wheel's words are white on dark glass, so its window is dark in a light system
    /// appearance too, and so is the system's material the glass shows with Reduce transparency
    /// on. The window holds the wheel's view alone: no soft backdrop or tint under it, and
    /// nothing on the window server's blur but the bubbles' glass. Building the window shows
    /// nothing.
    @MainActor
    func testTheWheelsWindowIsDarkAndHoldsOnlyTheWheel() throws {
        let menu = RadialMenu()
        let window = menu.makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertFalse(window.isVisible)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.subviews, [menu.wheel])
        XCTAssertEqual(menu.wheel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        menu.warpPointer = { _ in }
        menu.prepare(tree: RadialLayoutTests.tree(6, RadialLayoutTests.short), at: .zero,
                     on: .init(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
                               primaryHeight: 900), movesPointer: false)
        menu.select(path: ["loadouts", "Mail", "apply"])
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let all = views(content)
        XCTAssertFalse(all.contains { $0 is HUDSoftBackdropView }, "no cloud")
        let glass = all.compactMap { $0 as? HUDGlassView }
        XCTAssertFalse(glass.isEmpty)
        XCTAssertTrue(glass.allSatisfy { $0.superview is RadialBubble }, "the only glass is the bubbles'")
        XCTAssertTrue(glass.allSatisfy { $0.style.material == .windowBlur })
    }

    /// The wheel's view is the layout's canvas: it holds every bubble that can show, the hint's
    /// and the centre's disc included, grown as far as a petal grows.
    @MainActor
    func testTheWheelsViewHoldsEveryBubble() {
        for count in [0, 3, 10, 14] {
            let tree = RadialLayoutTests.tree(count, RadialLayoutTests.long)
            let layout = RadialLayout(tree: tree)
            let canvas = RadialWheelView.canvas(for: layout)
            let view = RadialWheelView(frame: CGRect(origin: .zero, size: canvas.size))
            view.configure(layout: layout, canvas: canvas, tree: tree)
            for branch in layout.branches {
                view.settle(selection: branch)
                for bubble in view.showingBubbles {
                    let grown = RadialLayout.grown(bubble.frame, by: RadialWheelView.grow,
                                                   about: CGPoint(x: bubble.frame.minX + bubble.pivot.x, y: bubble.frame.minY + bubble.pivot.y))
                    XCTAssertTrue(view.bounds.contains(grown), "\(count) loadouts, open \(branch): \(bubble.role)")
                }
            }
        }
    }

    /// The words are drawn into their pictures once per layout and backing scale, as their
    /// bubbles are first needed: the same wheel opened again reuses them, new words draw them anew.
    @MainActor
    func testTheWordsAreDrawnOncePerLayout() {
        let tree = RadialLayoutTests.tree(8, RadialLayoutTests.short)
        let layout = RadialLayout(tree: tree)
        let canvas = RadialWheelView.canvas(for: layout)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: canvas.size))
        view.configure(layout: layout, canvas: canvas, tree: tree)
        view.open()
        let first = view.wordRenders
        XCTAssertGreaterThan(first, 0)
        view.selection = ["loadouts", "Mail"]
        let unfolded = view.wordRenders
        XCTAssertGreaterThan(unfolded, first, "the loadouts and Mail's actions, the first time they show")
        view.close()
        view.configure(layout: RadialLayout(tree: tree), canvas: canvas, tree: RadialLayoutTests.tree(8, RadialLayoutTests.short), selection: [])
        view.open()
        view.selection = ["loadouts", "Mail"]
        XCTAssertEqual(view.wordRenders, unfolded, "the same words again, drawn once")
        let other = RadialLayoutTests.tree(8, RadialLayoutTests.long)
        view.configure(layout: RadialLayout(tree: other), canvas: RadialWheelView.canvas(for: RadialLayout(tree: other)), tree: other)
        XCTAssertGreaterThan(view.wordRenders, unfolded, "new words")
    }
}
