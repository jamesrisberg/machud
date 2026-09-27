import XCTest
@testable import MacHUDCore

final class WindowMatchTests: XCTestCase {
    private let region = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testIoU() {
        XCTAssertEqual(WindowMatch.iou(region, region), 1, accuracy: 0.0001)
        XCTAssertEqual(WindowMatch.iou(region, CGRect(x: 200, y: 200, width: 100, height: 100)), 0)
        // Half overlap: intersection 5000, union 15000.
        XCTAssertEqual(WindowMatch.iou(region, CGRect(x: 50, y: 0, width: 100, height: 100)), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(WindowMatch.iou(region, .zero), 0)
        // Touching edges are not an overlap.
        XCTAssertEqual(WindowMatch.iou(region, CGRect(x: 100, y: 0, width: 100, height: 100)), 0)
    }

    func testBestPicksHighestAboveMinimum() {
        let frames = [CGRect(x: 40, y: 0, width: 100, height: 100),
                      CGRect(x: 2, y: 2, width: 98, height: 98),
                      CGRect(x: 0, y: 0, width: 400, height: 400)]
        let hit = WindowMatch.best(frames: frames, in: region, minimum: 0.6)
        XCTAssertEqual(hit?.index, 1)
        XCTAssertNil(WindowMatch.best(frames: [frames[0], frames[2]], in: region, minimum: 0.6))
        XCTAssertEqual(WindowMatch.best(frames: frames, in: region, minimum: 0)?.index, 1)
        XCTAssertNil(WindowMatch.best(frames: [], in: region, minimum: 0))
    }

    func testTitleMatchingIsCaseInsensitiveRegex() {
        XCTAssertTrue(WindowMatch.titleMatches("Inbox — Mail", pattern: "inbox"))
        XCTAssertTrue(WindowMatch.titleMatches("Inbox — Mail", pattern: "^inbox.*mail$"))
        XCTAssertFalse(WindowMatch.titleMatches("Drafts", pattern: "^inbox"))
        // An unparseable pattern degrades to a substring test instead of failing.
        XCTAssertTrue(WindowMatch.titleMatches("a (b) c", pattern: "(b"))
    }

    func testTitlePatternRoundTrip() {
        let title = "Notes — file (1).txt [draft]"
        let pattern = WindowMatch.titlePattern(for: title)
        XCTAssertTrue(WindowMatch.titleMatches(title, pattern: pattern))
        XCTAssertFalse(WindowMatch.titleMatches(title + " copy", pattern: pattern))
    }

    // MARK: Window selection

    private func candidate(_ title: String, main: Bool = false, standard: Bool = true,
                           placeable: Bool = true, minimized: Bool = false) -> WindowMatch.Candidate {
        WindowMatch.Candidate(title: title, isMain: main, isStandard: standard,
                              isPlaceable: placeable, isMinimized: minimized)
    }

    func testChooseMainThenFrontmost() {
        let list = [candidate("Second"), candidate("Main", main: true)]
        XCTAssertEqual(WindowMatch.choose(list, titleMatch: nil), 1)
        XCTAssertEqual(WindowMatch.choose([candidate("Front"), candidate("Back")], titleMatch: nil), 0)
        XCTAssertNil(WindowMatch.choose([], titleMatch: nil))
    }

    func testChooseByTitleRegex() {
        let list = [candidate("Home", main: true), candidate("notes.md"), candidate("other.md")]
        XCTAssertEqual(WindowMatch.choose(list, titleMatch: "NOTES"), 1)
        XCTAssertEqual(WindowMatch.choose(list, titleMatch: "\\.md$"), 1)
        XCTAssertNil(WindowMatch.choose(list, titleMatch: "missing"))
        XCTAssertEqual(WindowMatch.choose(list, titleMatch: ""), 0)
    }

    func testNonStandardWindowsAreUsableButLoseToStandardOnes() {
        let portal = candidate("Portal", standard: false)
        let normal = candidate("Window")
        XCTAssertEqual(WindowMatch.choose([portal, normal], titleMatch: nil), 1)
        // A borderless window on its own must still be placeable (the AXWindow.under bug).
        XCTAssertEqual(WindowMatch.choose([portal], titleMatch: nil), 0)
    }

    func testUnplaceableWindowsAreSkipped() {
        let sheet = candidate("Save", placeable: false)
        XCTAssertEqual(WindowMatch.choose([sheet, candidate("Doc")], titleMatch: nil), 1)
        XCTAssertNil(WindowMatch.choose([sheet], titleMatch: nil))
    }

    func testMinimizedWindowsLoseButAreStillUsable() {
        XCTAssertEqual(WindowMatch.choose([candidate("A", main: true, minimized: true), candidate("B")], titleMatch: nil), 1)
        XCTAssertEqual(WindowMatch.choose([candidate("A", minimized: true)], titleMatch: nil), 0)
        XCTAssertEqual(WindowMatch.choose([candidate("notes", minimized: true), candidate("notes")], titleMatch: "notes"), 1)
    }

    // MARK: Capture

    func testCaptureAppAddsTitleMatchOnlyWhenAmbiguous() {
        let single = WindowMatch.captureOccupant(.init(bundleID: "com.apple.Safari", title: "News", appWindowCount: 1))
        XCTAssertEqual(single, .app(bundleID: "com.apple.Safari", titleMatch: nil))

        let many = WindowMatch.captureOccupant(.init(bundleID: "com.apple.Safari", title: "News", appWindowCount: 3))
        XCTAssertEqual(many, .app(bundleID: "com.apple.Safari", titleMatch: WindowMatch.titlePattern(for: "News")))

        let untitled = WindowMatch.captureOccupant(.init(bundleID: "com.apple.Safari", title: "", appWindowCount: 3))
        XCTAssertEqual(untitled, .app(bundleID: "com.apple.Safari", titleMatch: nil))
    }

    func testCapturePrefersOwnedWindows() {
        var input = WindowMatch.CaptureInput(bundleID: "com.apple.Safari", title: "t", appWindowCount: 2)
        input.panelID = "dock"
        XCTAssertEqual(WindowMatch.captureOccupant(input), .panel(id: "dock"))
        input.browserURL = "https://example.com"
        XCTAssertEqual(WindowMatch.captureOccupant(input), .web(url: "https://example.com", host: .chromeApp))
        input.browserHost = .arc
        XCTAssertEqual(WindowMatch.captureOccupant(input), .web(url: "https://example.com", host: .arc))
        input.builtinWebURL = "https://builtin.test"
        XCTAssertEqual(WindowMatch.captureOccupant(input), .web(url: "https://builtin.test", host: .builtin))
    }

    func testCaptureSkipsUnknownApps() {
        XCTAssertNil(WindowMatch.captureOccupant(.init(bundleID: nil, title: "x")))
        XCTAssertNil(WindowMatch.captureOccupant(.init(bundleID: "", title: "x")))
    }

    // MARK: Geometry

    func testRectTolerance() {
        let a = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertTrue(Geometry.matches(a, a.offsetBy(dx: 2, dy: -2), tolerance: 2))
        XCTAssertFalse(Geometry.matches(a, a.offsetBy(dx: 4, dy: 0), tolerance: 2))
        XCTAssertFalse(Geometry.matches(a, CGRect(x: 10, y: 10, width: 120, height: 50), tolerance: 2))
    }
}
