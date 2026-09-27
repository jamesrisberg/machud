import XCTest
@testable import MacHUDCore

/// The hotkey settings fields (`hotkeys.loadoutMenu`, `hotkeys.dock`) as text.
final class HotKeyTextTests: XCTestCase {
    func testFormatsModifiersAndKey() {
        XCTAssertEqual(HotKeyText.format(HotKey(key: "space", modifiers: ["control", "option"])), "control+option+space")
        XCTAssertEqual(HotKeyText.format(HotKey(key: "D", modifiers: ["ctrl", "alt"])), "control+option+d")
        XCTAssertEqual(HotKeyText.format(nil), "")
    }

    func testParsesAliasesAndSymbols() {
        XCTAssertEqual(HotKeyText.parse("ctrl+alt+space"), HotKey(key: "space", modifiers: ["control", "option"]))
        XCTAssertEqual(HotKeyText.parse("⌘⇧ f1".replacingOccurrences(of: "⌘⇧", with: "⌘+⇧")), HotKey(key: "f1", modifiers: ["command", "shift"]))
        XCTAssertEqual(HotKeyText.parse("Control-Option-N"), HotKey(key: "n", modifiers: ["control", "option"]))
        XCTAssertNil(HotKeyText.parse(""), "empty means no hotkey")
        XCTAssertNil(HotKeyText.parse("   "))
    }

    func testProblems() {
        XCTAssertNil(HotKeyText.problem("control+option+space"))
        XCTAssertNil(HotKeyText.problem(""))
        XCTAssertNotNil(HotKeyText.problem("space"), "a bare key would fire on every press")
        XCTAssertNotNil(HotKeyText.problem("control+bogus"))
        XCTAssertNotNil(HotKeyText.problem("hyper+space"))
    }

    @MainActor
    func testRoundTripsThroughTheSettingsSchema() {
        let defaults = Config.defaults
        let values = MacHUDSettings.values(config: defaults, enabled: true, orbsHidden: false)
        XCTAssertEqual(values["hotkeys.loadoutMenu"] as? String, "control+option+space")
        XCTAssertEqual(values["hotkeys.dock"] as? String, "control+option+d")
        let parsed = try! MacHUDSettings.schema.validate(["hotkeys.loadoutMenu": "command+shift+space", "hotkeys.dock": ""])
        let updated = MacHUDSettings.applying(parsed, to: defaults)
        XCTAssertEqual(updated.hotkeys?.loadoutMenu, HotKey(key: "space", modifiers: ["command", "shift"]))
        XCTAssertNil(updated.hotkeys?.dock, "empty turns the hotkey off")
    }
}

final class DockHiddenAppsTests: XCTestCase {
    func testDockFalseKeepsAnAppOffTheDock() throws {
        let json = #"{"xyz.machud.stash": {"dock": false}, "xyz.machud.sift": {"placement": {"region": "left"}}}"#
        let config = try JSONDecoder().decode(AppsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.hiddenFromDock, ["xyz.machud.stash"])
        XCTAssertEqual(config.placement(for: "xyz.machud.sift")?.region, "left")
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AppsConfig.self, from: data), config)
    }
}
