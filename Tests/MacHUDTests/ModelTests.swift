import XCTest
@testable import MacHUDCore

final class ModelTests: XCTestCase {
    func testOccupantRoundTrip() throws {
        let cases: [Occupant] = [
            .app(bundleID: "com.apple.Safari", titleMatch: nil),
            .app(bundleID: "com.apple.Terminal", titleMatch: "zsh"),
            .web(url: "https://example.com", host: .chromeApp),
            .web(url: "https://example.com", host: .builtin),
            .panel(id: "dock"),
        ]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(Occupant.self, from: data)
            XCTAssertEqual(c, back)
        }
    }

    func testRegionIDsAssigned() {
        let c = Config(gap: 0, trigger: .shift, grid: .default,
                       layouts: [Layout(name: "L", regions: [Region(id: nil, name: nil, x: 0, y: 0, w: 1, h: 1, hit: nil)])],
                       loadouts: nil, hotkeys: nil, browser: nil)
        let out = LayoutStore.withRegionIDs(c)
        XCTAssertNotNil(out.layouts[0].regions[0].id)
    }

    func testFractionRectToCocoa() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let r = FractionRect(x: 0.5, y: 0, w: 0.5, h: 0.5).cocoaRect(in: visible)
        XCTAssertEqual(r, CGRect(x: 500, y: 250, width: 500, height: 250))
    }

    func testHotKeyParsing() {
        XCTAssertNotNil(HotKeyCenter.keyCode(for: "space"))
        XCTAssertNotNil(HotKeyCenter.keyCode(for: "F5"))
        XCTAssertNil(HotKeyCenter.keyCode(for: "nope"))
        XCTAssertEqual(HotKey(key: "space", modifiers: ["control", "option"]).display, "⌃⌥SPACE")
    }
}
