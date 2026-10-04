import AppKit
import XCTest
@testable import MacHUDCore

/// The screen under the pointer, one lookup for the whole app (the wheel, capture, apply's
/// default screen, drag snapping, the preview, the layout editor, toasts), driven here with
/// made-up screen frames.
final class ScreenLookupTests: XCTestCase {
    private func on(_ p: CGPoint, _ frames: [CGRect]) -> Int? { ScreenCoords.screenIndex(containing: p, frames: frames) }

    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// A screen holds its left and top edges and not its right and bottom ones, as the pointer
    /// reports them: pinned at the top of a screen (just after using its menu bar) the pointer
    /// is at that screen's top edge.
    func testOneScreenHoldsItsTopEdgeAndCorners() {
        for p in [CGPoint(x: 720, y: 900), CGPoint(x: 0, y: 900), CGPoint(x: 1439, y: 900), CGPoint(x: 0, y: 1),
                  CGPoint(x: 1439, y: 1), CGPoint(x: 720, y: 450)] {
            XCTAssertEqual(on(p, [main]), 0, "\(p)")
        }
    }

    func testTwoScreensSideBySide() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(on(CGPoint(x: 700, y: 900), [main, right]), 0, "the first's top edge")
        XCTAssertEqual(on(CGPoint(x: 1439, y: 900), [main, right]), 0, "the first's top right corner")
        XCTAssertEqual(on(CGPoint(x: 1440, y: 500), [main, right]), 1, "the second's left edge")
        XCTAssertEqual(on(CGPoint(x: 1440, y: 1080), [main, right]), 1, "the second's top left corner")
        XCTAssertEqual(on(CGPoint(x: 3359, y: 1080), [main, right]), 1, "the second's top right corner")
    }

    /// The lower screen's top edge is the upper one's bottom edge: the pointer there is on the
    /// lower screen, whichever order the screens come in.
    func testOneScreenAboveTheOther() {
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        XCTAssertEqual(on(CGPoint(x: 700, y: 900), [main, above]), 0, "the lower one's top edge")
        XCTAssertEqual(on(CGPoint(x: 700, y: 900), [above, main]), 1, "whichever order the screens come in")
        XCTAssertEqual(on(CGPoint(x: 0, y: 900), [main, above]), 0, "the lower one's top left corner")
        XCTAssertEqual(on(CGPoint(x: 700, y: 901), [main, above]), 1)
        XCTAssertEqual(on(CGPoint(x: 700, y: 1800), [main, above]), 1, "the upper one's top edge")
        XCTAssertEqual(on(CGPoint(x: 1439, y: 1800), [main, above]), 1, "the upper one's top right corner")
    }

    /// A point on no screen (only on an edge a screen leaves out, or as a display goes away)
    /// gives the nearest screen; no screens give none.
    func testAPointOnNoScreenGivesTheNearestScreen() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        XCTAssertEqual(on(CGPoint(x: 3360, y: 500), [main, right]), 1, "the right edge of the rightmost screen")
        XCTAssertEqual(on(CGPoint(x: 700, y: 0), [main, right]), 0, "the bottom edge of the lowest screen")
        XCTAssertEqual(on(CGPoint(x: 3500, y: 200), [main, right]), 1)
        XCTAssertEqual(on(CGPoint(x: -20, y: 1700), [main, above]), 1)
        XCTAssertEqual(on(CGPoint(x: 2000, y: 950), [main, right]), 1, "past the taller screen's corner, nearer to it")
        XCTAssertNil(on(.zero, []))
    }
}
