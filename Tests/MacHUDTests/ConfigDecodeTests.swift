import XCTest
@testable import MacHUDCore

final class ConfigDecodeTests: XCTestCase {
    func testMinimalConfigDecodesWithEmptyLayouts() throws {
        let json = #"{"apps":{"searchPaths":["~/dev/*/build"]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.layouts, [])
        XCTAssertEqual(config.apps?.searchPaths, ["~/dev/*/build"])
    }

    func testEmptyObjectDecodes() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(config.layouts, [])
        XCTAssertNil(config.apps)
    }
}
