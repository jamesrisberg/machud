import AppKit
import HUDKit
import XCTest
@testable import MacHUDCore

final class RadialMenuWindowTests: XCTestCase {
    /// The wheel's labels, strokes and fills are white, so its window is dark in a light system
    /// appearance too; its glass takes the window's appearance, and the family's tint follows it
    /// (white at 20 % in a light one, which would sit under white labels). Building the window
    /// shows nothing.
    @MainActor
    func testTheWheelsWindowIsDarkWhateverTheSystemAppearance() throws {
        let menu = RadialMenu()
        let window = menu.makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertFalse(window.isVisible)
        let glass = try XCTUnwrap(window.contentView?.subviews.first { $0 is HUDGlassView })
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    /// The wheel's view holds the names outside the last ring, with room for a highlighted
    /// tile's push, and the hint below the wheel inside the view's width.
    @MainActor
    func testTheWheelsViewHoldsTheNamesAndTheHint() {
        for count in [3, 6, 9, 12] {
            let g = RadialGeometry(count: count)
            let canvas = RadialMenu.canvas(for: g)
            let reach = g.nameBand.outer + 5
            let bounds = CGRect(origin: .zero, size: canvas.size)
            XCTAssertTrue(bounds.contains(CGRect(x: canvas.center.x - reach, y: canvas.center.y - reach,
                                                 width: reach * 2, height: reach * 2)), "\(count) wedges")
            XCTAssertLessThanOrEqual(canvas.hintTop, canvas.center.y - reach, "the hint sits below the wheel")
            XCTAssertGreaterThan(canvas.hintTop, 30, "with room for two lines")
            XCTAssertLessThanOrEqual(canvas.hintWidth, canvas.size.width - 16)
        }
    }
}
