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

    // MARK: - Where an instance keeps its config

    func testConfigIsTheFileMACHUD_CONFIGNames() {
        XCTAssertEqual(Env.configURL(in: ["MACHUD_CONFIG": "/tmp/t/layouts.json"]),
                       URL(fileURLWithPath: "/tmp/t/layouts.json"))
        XCTAssertEqual(Env.configURL(in: ["MACHUD_CONFIG": "~/t/layouts.json"])?.path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("t/layouts.json"))
    }

    func testASocketAloneKeepsTheConfigBesideTheSocket() {
        XCTAssertEqual(Env.configURL(in: ["MACHUD_SOCKET": "/tmp/machud-try.sock"]),
                       URL(fileURLWithPath: "/tmp/machud-try-config/layouts.json"))
        XCTAssertEqual(Env.configURL(in: ["MACHUD_SOCKET": "/tmp/try"]),
                       URL(fileURLWithPath: "/tmp/try-config/layouts.json"), "no extension to drop")
        XCTAssertEqual(Env.configURL(in: ["MACHUD_SOCKET": "/tmp/a.b.sock"]),
                       URL(fileURLWithPath: "/tmp/a.b-config/layouts.json"), "only the last extension goes")
    }

    func testAConfigWinsOverASocket() {
        XCTAssertEqual(Env.configURL(in: ["MACHUD_SOCKET": "/tmp/try.sock", "MACHUD_CONFIG": "/tmp/own/layouts.json"]),
                       URL(fileURLWithPath: "/tmp/own/layouts.json"))
    }

    func testNeitherNamesNoConfig() {
        XCTAssertNil(Env.configURL(in: [:]), "the real instance uses the home folder's")
        XCTAssertNil(Env.configURL(in: ["MACHUD_NO_HOTKEYS": "1", "OTHER_SOCKET": "/tmp/x.sock"]))
        XCTAssertNil(Env.configURL(in: ["MACHUD_SOCKET": ""]), "an empty socket names no place")
    }

    func testEveryIsolatedInstanceHasAConfigOfItsOwn() {
        for isolated in [["MACHUD_SOCKET": "/tmp/t.sock"], ["MACHUD_CONFIG": "/tmp/t/layouts.json"]] {
            XCTAssertTrue(Env.isIsolated(in: isolated))
            XCTAssertNotNil(Env.configURL(in: isolated), "\(isolated) must not fall through to ~/.config/machud")
        }
    }
}

/// The path of `layouts.json`: the real instance's under the home folder, an isolated one's
/// anywhere but there.
final class ConfigLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    func testTheRealInstanceKeepsItsConfigUnderTheHomeFolder() {
        XCTAssertEqual(LayoutStore.defaultConfigURL(environment: [:], home: home).path,
                       "/Users/someone/.config/machud/layouts.json")
    }

    func testAnInstanceStartedWithOnlyASocketNeverTouchesTheHomeConfig() {
        let url = LayoutStore.defaultConfigURL(environment: ["MACHUD_SOCKET": "/tmp/machud-try.sock"], home: home)
        XCTAssertEqual(url.path, "/tmp/machud-try-config/layouts.json")
        XCTAssertFalse(url.path.hasPrefix(home.path))
    }

    func testAConfigNamedExplicitlyIsUsedAsGiven() {
        let environment = ["MACHUD_SOCKET": "/tmp/try.sock", "MACHUD_CONFIG": "/tmp/own/layouts.json"]
        XCTAssertEqual(LayoutStore.defaultConfigURL(environment: environment, home: home).path, "/tmp/own/layouts.json")
    }
}
