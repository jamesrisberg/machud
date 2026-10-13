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
            menu.scrim.window?.orderOut(nil)
            menu.scrim.window?.close()
        }
        menus = []
        super.tearDown()
    }

    private func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// As the wheel shows, the veil covers its whole screen just under the wheel's window, in a
    /// window of its own that is never key or main, takes no mouse and has no glass (so the
    /// window server's blur stays on the bubbles).
    func testTheScrimCoversTheScreenUnderTheWheelAndNeverTakesFocus() throws {
        let menu = menu()
        menu.present()
        let scrim = try XCTUnwrap(menu.scrim.window)
        XCTAssertTrue(menu.scrim.isShowing)
        XCTAssertTrue(scrim.isVisible)
        XCTAssertTrue(menu.isVisible)
        XCTAssertEqual(scrim.frame, display.frame, "the whole screen the wheel opens on")
        let wheel = try XCTUnwrap(NSApp.windows.first { $0.contentView?.subviews.contains(menu.wheel) == true })
        XCTAssertFalse(scrim === wheel)
        XCTAssertGreaterThan(scrim.orderedIndex, wheel.orderedIndex, "just under the wheel")
        XCTAssertEqual(scrim.level, wheel.level)
        XCTAssertEqual(scrim.collectionBehavior, wheel.collectionBehavior, "on every Space the wheel is")
        XCTAssertFalse(scrim.canBecomeKey)
        XCTAssertFalse(scrim.canBecomeMain)
        XCTAssertFalse(scrim.isKeyWindow)
        XCTAssertTrue(scrim.ignoresMouseEvents)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        XCTAssertFalse(try views(XCTUnwrap(scrim.contentView)).contains { $0 is HUDGlassView || $0 is HUDSoftBackdropView })
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
            XCTAssertLessThan(scrim.alphaValue, 0.5, "\(end): it fades in")
            wait(RadialScrim.fadeIn + 0.15)
            XCTAssertEqual(scrim.alphaValue, 1, accuracy: 0.01, end)
            switch end {
            case "hide": menu.hide()
            case "cancel": menu.cancel()
            default: menu.commit()
            }
            XCTAssertFalse(menu.scrim.isShowing, end)
            wait(RadialScrim.fadeOut + 0.15)
            XCTAssertFalse(scrim.isVisible, "\(end): gone")
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
