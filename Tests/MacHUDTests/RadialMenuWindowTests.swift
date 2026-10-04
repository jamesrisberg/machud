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
}
