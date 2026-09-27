import XCTest
@testable import MacHUDCore

/// A layout captured for one loadout only is marked hidden and stays out of the snap picker.
final class HiddenLayoutTests: XCTestCase {
    func testHiddenRoundTripsAndDefaultsToAbsent() throws {
        let plain = try JSONDecoder().decode(Layout.self, from: Data(#"{"name": "A", "regions": []}"#.utf8))
        XCTAssertNil(plain.hidden)
        var layout = plain
        layout.hidden = true
        let data = try JSONEncoder().encode(layout)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""hidden":true"#))
        XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: data), layout)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("hidden"))
    }
}
