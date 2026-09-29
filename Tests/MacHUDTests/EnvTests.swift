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

    func testIsolatedInstancesDoNotActOnRealWindowsUnasked() {
        XCTAssertTrue(Env.autoApply(in: [:]), "the real instance applies its startup loadout and launches apps")
        XCTAssertFalse(Env.isIsolated(in: [:]))
        for isolated in [["MACHUD_SOCKET": "/tmp/t.sock"], ["MACHUD_CONFIG": "/tmp/t/layouts.json"]] {
            XCTAssertTrue(Env.isIsolated(in: isolated))
            XCTAssertFalse(Env.autoApply(in: isolated))
            XCTAssertTrue(Env.autoApply(in: isolated.merging(["MACHUD_APPLY_STARTUP": "1"]) { a, _ in a }))
            XCTAssertFalse(Env.autoApply(in: isolated.merging(["MACHUD_APPLY_STARTUP": "0"]) { a, _ in a }))
        }
    }

    func testEmptyValueIsPresent() {
        // Presence, not content, decides: `MACHUD_NO_HOTKEYS=` is set.
        XCTAssertEqual(Env.value("NO_HOTKEYS", in: ["MACHUD_NO_HOTKEYS": ""]), "")
    }
}
