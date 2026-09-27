import XCTest
@testable import MacHUDCore

final class ArrangementTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let grid = GridSize(cols: 96, rows: 54)

    func testFractionInvertsRegionRect() {
        let f = FractionRect(x: 0.25, y: 0.5, w: 0.5, h: 0.25)
        let gap: CGFloat = 8
        let inset = visible.insetBy(dx: gap / 2, dy: gap / 2)
        let rect = f.cocoaRect(in: inset).insetBy(dx: gap / 2, dy: gap / 2)
        let back = Arrangement.fraction(of: rect, visible: visible, gap: gap)
        XCTAssertEqual(back.x, f.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, f.y, accuracy: 1e-9)
        XCTAssertEqual(back.w, f.w, accuracy: 1e-9)
        XCTAssertEqual(back.h, f.h, accuracy: 1e-9)
    }

    func testSnapLandsOnGridAndKeepsMinimumCell() {
        let s = Arrangement.snap(FractionRect(x: 0.333, y: 0.001, w: 0.002, h: 0.5), grid: grid)
        XCTAssertEqual(s.x * 96, (s.x * 96).rounded(), accuracy: 1e-9)
        XCTAssertEqual(s.w, 1.0 / 96, accuracy: 1e-9)
        XCTAssertEqual(s.y, 0)
        let edge = Arrangement.snap(FractionRect(x: 0.99, y: 0.99, w: 0.2, h: 0.2), grid: grid)
        XCTAssertLessThanOrEqual(edge.x + edge.w, 1 + 1e-9)
        XCTAssertLessThanOrEqual(edge.y + edge.h, 1 + 1e-9)
    }

    func testStackedWindowsEachGetARegion() {
        let a = Arrangement.Input(frame: CGRect(x: 100, y: 100, width: 800, height: 600), name: "Safari")
        let b = Arrangement.Input(frame: CGRect(x: 150, y: 120, width: 800, height: 600), name: "Safari")
        let placed = Arrangement.regions(for: [a, b], visible: visible, gap: 0, grid: grid, existing: [])
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed.map { $0.region.name }, ["Safari", "Safari 2"])
        XCTAssertNotEqual(placed[0].region.id, placed[1].region.id)
    }

    func testExistingRegionIsReusedWhenItStillMatches() {
        let existing = Region(id: "keep", name: "Feed", x: 0, y: 0, w: 0.25, h: 1,
                              hit: FractionRect(x: 0, y: 0.4, w: 0.1, h: 0.2))
        let input = Arrangement.Input(frame: CGRect(x: 0, y: 0, width: 470, height: 1080), name: "Arc")
        let placed = Arrangement.regions(for: [input], visible: visible, gap: 0, grid: grid, existing: [existing])
        XCTAssertEqual(placed[0].region.id, "keep")
        XCTAssertEqual(placed[0].region.name, "Feed")
        XCTAssertNotNil(placed[0].region.hit)
        // Takes the window's exact frame, not the grid's.
        XCTAssertEqual(placed[0].region.w, 470.0 / 1920, accuracy: 1e-6)
    }

    /// Regression (placement report 3): windows overlapping by less than half a grid cell
    /// used to be snapped into neighbours, so apply laid them side by side.
    func testSlightlyOverlappingWindowsStayOverlapping() {
        let a = Arrangement.Input(frame: CGRect(x: 0, y: 0, width: 1000, height: 1080), name: "Messages")
        let b = Arrangement.Input(frame: CGRect(x: 990, y: 0, width: 930, height: 1080), name: "Signal")
        let placed = Arrangement.regions(for: [a, b], visible: visible, gap: 0, grid: grid, existing: [])
        let ra = placed[0].region.frame, rb = placed[1].region.frame
        XCTAssertTrue(ZOrder.overlaps(ra, rb), "\(ra) \(rb)")
        XCTAssertTrue(Geometry.matches(ra.cocoaRect(in: visible), a.frame, tolerance: 0.01))
        XCTAssertTrue(Geometry.matches(rb.cocoaRect(in: visible), b.frame, tolerance: 0.01))
    }

    func testCapturedFrameRoundTripsToWithinAPoint() {
        let frame = CGRect(x: 137, y: 211, width: 777, height: 431)
        let f = Arrangement.exact(Arrangement.fraction(of: frame, visible: visible, gap: 0))
        let back = f.cocoaRect(in: visible)
        XCTAssertTrue(Geometry.matches(back, frame, tolerance: 1), "\(back)")
    }

    func testExistingRegionNotReusedWhenMoved() {
        let existing = Region(id: "old", name: "Feed", x: 0.75, y: 0, w: 0.25, h: 1, hit: nil)
        let input = Arrangement.Input(frame: CGRect(x: 0, y: 0, width: 480, height: 1080), name: "Arc")
        let placed = Arrangement.regions(for: [input], visible: visible, gap: 0, grid: grid, existing: [existing])
        XCTAssertNotEqual(placed[0].region.id, "old")
        XCTAssertEqual(placed[0].region.name, "Arc")
    }
}

final class CaptureMergeTests: XCTestCase {
    /// A window as a capture pass sees it: its window-server number and app.
    private struct Win: Equatable {
        var number: Int
        var app: String
    }

    private let desktop1 = [Win(number: 10, app: "Ghostty"), Win(number: 11, app: "Music"),
                            Win(number: 12, app: "Arc")]
    private let desktop2 = [Win(number: 11, app: "Music"), Win(number: 20, app: "Xcode")]
    private let desktop3 = [Win(number: 11, app: "Music"), Win(number: 12, app: "Arc")]

    func testWindowOnEveryDesktopIsCapturedOnTheFirstOne() {
        let passes = Arrangement.firstSeen([desktop1, desktop2, desktop3]) { $0.number }
        XCTAssertEqual(passes[0], desktop1)
        XCTAssertEqual(passes[1], [Win(number: 20, app: "Xcode")])
        XCTAssertTrue(passes[2].isEmpty)
    }

    func testNothingIsDroppedWhenThePassesAreDisjoint() {
        let passes = Arrangement.firstSeen([desktop1, [Win(number: 20, app: "Xcode")]]) { $0.number }
        XCTAssertEqual(passes.map(\.count), [3, 1])
    }

    func testEmptyInput() {
        XCTAssertTrue(Arrangement.firstSeen([[Win]]()) { $0.number }.isEmpty)
    }

    func testLayoutNames() {
        XCTAssertEqual(Arrangement.layoutName("Work", screen: nil, desktop: nil), "Work")
        XCTAssertEqual(Arrangement.layoutName("Work", screen: "DELL S2722QC", desktop: nil),
                       "Work · DELL S2722QC")
        XCTAssertEqual(Arrangement.layoutName("Work", screen: "Built-in Retina Display", desktop: 2),
                       "Work · Built-in Retina Display · Desktop 2")
        XCTAssertEqual(Arrangement.layoutName("Work", screen: "", desktop: 3), "Work · Desktop 3")
    }
}
