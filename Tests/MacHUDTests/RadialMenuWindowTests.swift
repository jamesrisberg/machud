import AppKit
import HUDKit
import XCTest
@testable import MacHUDCore

final class RadialMenuWindowTests: XCTestCase {
    /// The wheel's words are white, so its window is dark in a light system appearance too, and
    /// so is the system's material the backdrop shows with Reduce transparency on. The backdrop
    /// is HUDKit's soft backdrop, and nothing else in the window is on the window server's blur,
    /// which would end in a line where the field fades out. Building the window shows nothing.
    @MainActor
    func testTheWheelsWindowIsDarkAndHasOnlyTheSoftBackdrop() throws {
        let menu = RadialMenu()
        let window = menu.makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertFalse(window.isVisible)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let all = try views(XCTUnwrap(window.contentView))
        let backdrop = try XCTUnwrap(all.first { $0 is HUDSoftBackdropView })
        XCTAssertEqual(backdrop.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertFalse(all.contains { $0 is HUDGlassView || $0 is HUDDockStripView }, "nothing on the window server's blur")
        XCTAssertEqual(window.contentView?.subviews.first, backdrop, "the backdrop is under everything")
    }

    /// The wheel's view is the field's canvas: it holds every word, the hint's zone and the
    /// field as it fades out, with or without Reduce transparency.
    @MainActor
    func testTheWheelsViewHoldsTheWordsTheHintAndTheField() {
        for count in [3, 6, 9, 12] {
            let layout = RadialLayout(wedges: RadialLayoutTests.wedges(count, RadialLayoutTests.long))
            for reduced in [false, true] {
                let field = RadialField(layout: layout, reduced: reduced)
                let canvas = field.canvas
                XCTAssertTrue(field.support.contains(layout.bounds), "\(count) wedges")
                XCTAssertEqual(canvas.size, field.support.size)
                XCTAssertEqual(canvas.center, CGPoint(x: -field.support.minX, y: -field.support.minY))
            }
        }
    }

    /// The words are drawn into their pictures once per layout, backing scale and appearance:
    /// the same wheel opened again reuses them, new words or another appearance draw them anew.
    @MainActor
    func testTheWordsAreDrawnOncePerLayoutScaleAndAppearance() throws {
        let wedges = RadialLayoutTests.wedges(8, RadialLayoutTests.short)
        let layout = RadialLayout(wedges: wedges)
        let field = RadialField(layout: layout, reduced: false)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: field.canvas.size))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func open(_ layout: RadialLayout, _ wedges: [RadialMenu.Wedge], appearance: NSAppearance.Name = .darkAqua) {
            view.appearance = NSAppearance(named: appearance)
            view.configure(layout: layout, field: field, wedges: wedges)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        open(layout, wedges)
        XCTAssertEqual(view.wordRenders, 1)
        open(RadialLayout(wedges: wedges), RadialLayoutTests.wedges(8, RadialLayoutTests.short))
        XCTAssertEqual(view.wordRenders, 1, "the same words again")
        let other = RadialLayoutTests.wedges(8, RadialLayoutTests.long)
        open(RadialLayout(wedges: other), other)
        XCTAssertEqual(view.wordRenders, 2, "new words")
        open(RadialLayout(wedges: other), other, appearance: .aqua)
        XCTAssertEqual(view.wordRenders, 3, "another appearance")
    }

    /// The view redraws whenever what it shows changes (the selection, the wedges, the
    /// appearance) and while its springs move, and not once they have settled.
    @MainActor
    func testTheWheelRedrawsOnlyWhileSomethingChanges() {
        let wedges = RadialLayoutTests.wedges(6, RadialLayoutTests.short)
        let layout = RadialLayout(wedges: wedges)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: RadialField(layout: layout, reduced: false).canvas.size))
        // In a window, which keeps the view's requests to redraw; it is never ordered in.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        XCTAssertFalse(window.isVisible)
        view.configure(layout: layout, field: RadialField(layout: layout, reduced: false), wedges: wedges)
        view.resetSprings()
        XCTAssertTrue(view.needsDisplay)

        func settle() {
            for _ in 0..<2000 where view.isMoving { view.tick() }
            XCTAssertFalse(view.isMoving)
            view.displayIfNeeded()
            view.tick()
            XCTAssertFalse(view.needsDisplay, "a settled wheel does not redraw")
        }
        settle()

        view.selection = .wedge(index: 1, ring: .middle)
        XCTAssertTrue(view.needsDisplay, "a selection change redraws at once")
        view.displayIfNeeded()
        view.tick()
        XCTAssertTrue(view.needsDisplay, "and keeps redrawing while the word grows")
        settle()

        let more = RadialLayoutTests.wedges(9, RadialLayoutTests.short)
        let bigger = RadialLayout(wedges: more)
        view.configure(layout: bigger, field: RadialField(layout: bigger, reduced: false), wedges: more)
        XCTAssertTrue(view.needsDisplay, "new wedges redraw")
        view.displayIfNeeded()
        view.selection = .wedge(index: 8, ring: .inner)
        XCTAssertTrue(view.needsDisplay)
        settle()

        view.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(view.needsDisplay, "an appearance change redraws")
    }
}
