import XCTest
@testable import MacHUDCore

/// `MACHUD_*` environment overrides.
final class EnvTests: XCTestCase {
    func testValueReadsThePrefixedName() {
        XCTAssertEqual(Env.value("SOCKET", in: ["MACHUD_SOCKET": "/tmp/new.sock"]), "/tmp/new.sock")
        XCTAssertEqual(Env.value("CONFIG", in: ["MACHUD_CONFIG": "/tmp/new.json"]), "/tmp/new.json")
    }

    func testUnsetIsNil() {
        XCTAssertNil(Env.value("SOCKET", in: [:]))
        XCTAssertNil(Env.value("SOCKET", in: ["MACHUD_CONFIG": "x", "OTHER_SOCKET": "y"]))
    }

    func testEmptyValueIsPresent() {
        // Presence, not content, decides: `MACHUD_NO_HOTKEYS=` is set.
        XCTAssertEqual(Env.value("NO_HOTKEYS", in: ["MACHUD_NO_HOTKEYS": ""]), "")
    }
}
