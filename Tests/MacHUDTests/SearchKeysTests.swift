import AppKit
import XCTest
@testable import MacHUDCore

/// Which key does what in the search bar, and what Return runs for each kind of row.
final class SearchKeysTests: XCTestCase {
    private func command(_ keyCode: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) -> SearchCommand? {
        SearchKeys.command(keyCode: keyCode, characters: chars, modifiers: mods)
    }

    func testNavigationKeys() {
        XCTAssertEqual(command(SearchKeys.down), .move(1))
        XCTAssertEqual(command(SearchKeys.up), .move(-1))
        XCTAssertEqual(command(SearchKeys.escape), .close)
    }

    func testReturnCarriesItsModifier() {
        XCTAssertEqual(command(SearchKeys.returnKey), .run(.plain))
        XCTAssertEqual(command(SearchKeys.enter), .run(.plain))
        XCTAssertEqual(command(SearchKeys.returnKey, "", .option), .run(.option))
        XCTAssertEqual(command(SearchKeys.returnKey, "", .shift), .run(.shift))
        XCTAssertEqual(command(SearchKeys.returnKey, "", .command), .run(.command))
        // Caps Lock and the function key do not change what Return does.
        XCTAssertEqual(command(SearchKeys.returnKey, "", [.capsLock, .function]), .run(.plain))
    }

    func testAnInputMethodComposingKeepsTheKeys() {
        // While marked text is being composed (Japanese, Chinese), Return commits it, Esc
        // cancels it and the arrows pick a candidate: the field editor gets them.
        for key in [SearchKeys.returnKey, SearchKeys.escape, SearchKeys.up, SearchKeys.down] {
            XCTAssertNil(SearchKeys.command(keyCode: key, characters: "", modifiers: [], composing: true))
        }
        XCTAssertNil(SearchKeys.command(keyCode: 18, characters: "1", modifiers: .command, composing: true))
    }

    func testCommandDigitsRunTheNthRow() {
        XCTAssertEqual(command(18, "1", .command), .runRow(0))
        XCTAssertEqual(command(25, "9", .command), .runRow(8))
        XCTAssertNil(command(29, "0", .command), "⌘0 is not a row")
        XCTAssertNil(command(18, "1"), "a plain digit is typed into the field")
    }

    func testTypingAndEditingPassThrough() {
        XCTAssertNil(command(0, "a"))
        XCTAssertNil(command(9, "v", .command), "⌘V pastes into the field")
        XCTAssertNil(command(51, "\u{7f}"), "delete edits the field")
    }

    // MARK: What a row runs

    private func row(_ kind: SearchKind, _ id: String) -> SearchResult {
        SearchResult(kind: kind, id: id, title: id, subtitle: "", score: 0)
    }

    func testLoadoutModifiers() {
        let loadout = row(.loadout, "Messaging")
        XCTAssertEqual(SearchKeys.action(for: loadout, .plain), .loadout("Messaging", .apply))
        XCTAssertEqual(SearchKeys.action(for: loadout, .option), .loadout("Messaging", .preview))
        XCTAssertEqual(SearchKeys.action(for: loadout, .shift), .loadout("Messaging", .clearAndApply))
        XCTAssertEqual(SearchKeys.action(for: loadout, .command), .loadout("Messaging", .apply))
    }

    func testFileOpensOrReveals() {
        let file = row(.file, "/Users/u/plan.txt")
        XCTAssertEqual(SearchKeys.action(for: file, .plain), .openFile("/Users/u/plan.txt"))
        XCTAssertEqual(SearchKeys.action(for: file, .command), .reveal("/Users/u/plan.txt"))
    }

    func testAppLaunchesOrReveals() {
        let app = row(.app, "/Applications/Safari.app")
        XCTAssertEqual(SearchKeys.action(for: app, .plain), .launch("/Applications/Safari.app"))
        XCTAssertEqual(SearchKeys.action(for: app, .option), .launch("/Applications/Safari.app"))
        XCTAssertEqual(SearchKeys.action(for: app, .command), .reveal("/Applications/Safari.app"))
    }

    func testSnippetInserts() {
        XCTAssertEqual(SearchKeys.action(for: row(.snippet, "42"), .plain), .insertSnippet("42"))
        XCTAssertEqual(SearchKeys.action(for: row(.snippet, "42"), .shift), .insertSnippet("42"))
    }
}
