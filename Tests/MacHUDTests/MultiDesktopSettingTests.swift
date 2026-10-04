import HUDKit
import XCTest
@testable import MacHUDCore

/// `experimental.multiDesktopLoadouts` in MacHUD's settings: the shared settings window and
/// `settings get/set` read and write it like any other key.
@MainActor
final class MultiDesktopSettingTests: XCTestCase {
    private let key = ExperimentalLoadouts.settingKey

    private func set(_ value: String, on config: Config) throws -> Config {
        MacHUDSettings.applying(try MacHUDSettings.schema.validate([key: value]), to: config)
    }

    func testTheSettingIsAnExperimentalSwitchThatStartsOff() throws {
        let field = try XCTUnwrap(MacHUDSettings.schema.settings.first { $0.key == key })
        XCTAssertEqual(field.title, ExperimentalLoadouts.settingTitle)
        XCTAssertEqual(field.type, .bool)
        XCTAssertEqual(field.default, .bool(false))
        XCTAssertEqual(field.group, "Experimental")
        let help = try XCTUnwrap(field.help)
        XCTAssertTrue(help.lowercased().contains("still being worked on"), help)
        for covered in ["span several desktops or displays", "capturing every screen", "walking desktops",
                        "slots bound to a desktop", "spaces.policy", "spaces action=switch"] {
            XCTAssertTrue(help.contains(covered), "the help names \(covered): \(help)")
        }
        XCTAssertFalse(help.contains(". "), "one sentence a user can read: \(help)")
        XCTAssertEqual(MacHUDSettings.values(config: .defaults, enabled: true, orbsHidden: false)[key] as? Bool, false)
    }

    func testSettingsSetTurnsItOnAndOffAndKeepsTheOtherExperimentalKey() throws {
        var config = Config.defaults
        config.experimental = Experimental(spacesPrivateAPI: true)
        let on = try set("true", on: config)
        XCTAssertTrue(on.multiDesktopLoadouts)
        XCTAssertEqual(on.experimental?.spacesPrivateAPI, true)
        XCTAssertEqual(MacHUDSettings.values(config: on, enabled: true, orbsHidden: false)[key] as? Bool, true)
        let off = try set("false", on: on)
        XCTAssertFalse(off.multiDesktopLoadouts)
        XCTAssertEqual(off.experimental?.spacesPrivateAPI, true)
    }

    func testTurningItOffWhenItWasNeverOnChangesNothing() throws {
        XCTAssertEqual(try set("false", on: .defaults), .defaults)
    }
}
