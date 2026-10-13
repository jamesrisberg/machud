import AppKit
import HUDKit
import XCTest
@testable import MacHUDCore

/// The dark veil over the screen under the wheel. Its windows are really ordered in, on a
/// "screen" far off every display, so nothing shows; nothing is watched (no event monitor or key
/// tap: `present` orders the windows in and does no more).
@MainActor
final class RadialScrimTests: XCTestCase {
    private let display = RadialMenu.Display(frame: CGRect(x: -30000, y: -30000, width: 1440, height: 900),
                                             visibleFrame: CGRect(x: -30000, y: -30000, width: 1440, height: 875), primaryHeight: 900)
    private var menus: [RadialMenu] = []

    private func menu() -> RadialMenu {
        let menu = RadialMenu()
        menu.warpPointer = { _ in XCTFail("the pointer is not moved") }
        menu.prepare(tree: RadialLayoutTests.tree(3, RadialLayoutTests.short), at: CGPoint(x: -29000, y: -29000), on: display, movesPointer: false)
        menus.append(menu)
        return menu
    }

    override func tearDown() {
        for menu in menus {
            menu.hide()
            for w in [menu.scrim.window, menu.scrim.band] {
                w?.orderOut(nil)
                w?.close()
            }
        }
        menus = []
        super.tearDown()
    }

    private func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// As the wheel shows, the veil covers its whole screen in two windows of its own that are
    /// never key or main, take no mouse and have no glass (so the window server's blur stays on
    /// the bubbles): the visible frame just under `.floating`, so the windows are dimmed and the
    /// HUD (the tool dock, raised widgets, the siblings' panels) is not; the menu bar and the
    /// system Dock, the rest of the screen, at the wheel's level just under it.
    func testTheScrimCoversTheScreenUnderTheHUDAndTheWheelAndNeverTakesFocus() throws {
        let menu = menu()
        menu.present()
        let scrim = try XCTUnwrap(menu.scrim.window)
        let band = try XCTUnwrap(menu.scrim.band)
        XCTAssertTrue(menu.scrim.isShowing)
        XCTAssertTrue(scrim.isVisible)
        XCTAssertTrue(band.isVisible)
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(scrim.frame, display.visibleFrame, "the windows' part of the screen")
        XCTAssertEqual(band.frame, display.frame, "the whole screen the wheel opens on")
        let wheel = try XCTUnwrap(NSApp.windows.first { $0.contentView?.subviews.contains(menu.wheel) == true })
        XCTAssertFalse(scrim === wheel)
        XCTAssertFalse(band === wheel)

        // Above app windows, under every floating layer of the HUD; the wheel above all of it.
        XCTAssertGreaterThan(scrim.level, .normal)
        XCTAssertLessThan(scrim.level, .floating, "raised widgets and siblings' panels float over it")
        XCTAssertLessThan(scrim.level, ToolDockWindow.make().level, "the tool dock is over it")
        XCTAssertGreaterThan(wheel.level, NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow))),
                             "the wheel is over the menu bar")
        XCTAssertEqual(band.level, wheel.level)
        XCTAssertGreaterThan(band.orderedIndex, wheel.orderedIndex, "the band just under the wheel")

        // The band leaves out the visible frame, which the other window veils: no part twice.
        let hole = display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        XCTAssertEqual((band.contentView as? RadialScrimBand)?.hole, hole)
        let path = RadialScrimBand.path(bounds: CGRect(origin: .zero, size: display.frame.size), hole: hole)
        XCTAssertTrue(path.contains(CGPoint(x: 700, y: 890), using: .evenOdd), "the menu bar")
        XCTAssertFalse(path.contains(CGPoint(x: 700, y: 450), using: .evenOdd), "the visible frame")

        for w in [scrim, band] {
            XCTAssertEqual(w.collectionBehavior, wheel.collectionBehavior, "on every Space the wheel is")
            XCTAssertFalse(w.canBecomeKey)
            XCTAssertFalse(w.canBecomeMain)
            XCTAssertFalse(w.isKeyWindow)
            XCTAssertTrue(w.ignoresMouseEvents)
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            XCTAssertFalse(try views(XCTUnwrap(w.contentView)).contains { $0 is HUDGlassView || $0 is HUDSoftBackdropView })
        }
        let veil = try XCTUnwrap(scrim.contentView?.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        XCTAssertEqual(veil.alphaComponent, RadialScrim.darkness, accuracy: 0.001)
        XCTAssertEqual(veil.usingColorSpace(.sRGB)?.brightnessComponent ?? 1, 0, accuracy: 0.001, "black")
    }

    /// It fades in as the wheel opens and goes, fast, with the wheel however it goes: hidden,
    /// cancelled or committed.
    func testTheScrimFadesInAndGoesWithTheWheel() throws {
        for end in ["hide", "cancel", "commit"] {
            let menu = menu()
            menu.present()
            let scrim = try XCTUnwrap(menu.scrim.window)
            let band = try XCTUnwrap(menu.scrim.band)
            XCTAssertLessThan(scrim.alphaValue, 0.5, "\(end): it fades in")
            XCTAssertLessThan(band.alphaValue, 0.5, "\(end): it fades in")
            wait(RadialScrim.fadeIn + 0.15)
            XCTAssertEqual(scrim.alphaValue, 1, accuracy: 0.01, end)
            XCTAssertEqual(band.alphaValue, 1, accuracy: 0.01, end)
            switch end {
            case "hide": menu.hide()
            case "cancel": menu.cancel()
            default: menu.commit()
            }
            XCTAssertFalse(menu.scrim.isShowing, end)
            wait(RadialScrim.fadeOut + 0.15)
            XCTAssertFalse(scrim.isVisible, "\(end): gone")
            XCTAssertFalse(band.isVisible, "\(end): gone")
        }
    }

    /// Hidden part-way through fading in it goes all the same, and shown again before it has
    /// gone it stays, whole.
    func testTheScrimHiddenMidFadeGoesAndShownAgainStays() throws {
        let menu = menu()
        menu.present()
        let scrim = try XCTUnwrap(menu.scrim.window)
        menu.hide()
        wait(RadialScrim.fadeIn + 0.15)
        XCTAssertFalse(scrim.isVisible, "hidden while it faded in")
        menu.present()
        menu.hide()
        menu.present()
        wait(RadialScrim.fadeOut + RadialScrim.fadeIn + 0.2)
        XCTAssertTrue(scrim.isVisible, "the fade-out it overtook does not take it away")
        XCTAssertEqual(scrim.alphaValue, 1, accuracy: 0.01)
    }
}
