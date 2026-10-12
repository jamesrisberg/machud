import AppKit

/// The modifier held with Return (or a ⌘-digit, which counts as ⌘).
enum SearchModifier: Equatable {
    case plain, option, shift, command
}

/// A key the bar handles itself; every other key goes to the text field.
enum SearchCommand: Equatable {
    case move(Int)
    case run(SearchModifier)
    /// ⌘1–⌘9: run that row (0-based).
    case runRow(Int)
    case close
}

/// What running a row does.
enum SearchAction: Equatable {
    enum LoadoutRun: Equatable { case apply, preview, clearAndApply }

    case launch(String)
    case openFile(String)
    case reveal(String)
    case loadout(String, LoadoutRun)
    case insertSnippet(String)
}

/// The bar's keys: ↑/↓ move the selection, Return runs it (its modifier picks how), ⌘1–9 run
/// that row, Esc closes.
enum SearchKeys {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let escape: UInt16 = 53
    static let up: UInt16 = 126
    static let down: UInt16 = 125

    static func command(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> SearchCommand? {
        let mods = modifiers.intersection([.command, .option, .shift, .control])
        switch keyCode {
        case returnKey, enter:
            if mods.contains(.command) { return .run(.command) }
            if mods.contains(.option) { return .run(.option) }
            if mods.contains(.shift) { return .run(.shift) }
            return .run(.plain)
        case escape: return .close
        case up: return .move(-1)
        case down: return .move(1)
        default:
            guard mods == .command, let c = characters, c.count == 1, let n = Int(c), (1...9).contains(n) else { return nil }
            return .runRow(n - 1)
        }
    }

    /// Return on an app launches it (⌘ reveals it in Finder); on a file opens it (⌘ reveals);
    /// on a loadout applies it (⌥ previews, ⇧ clears first); on a snippet inserts it.
    static func action(for result: SearchResult, _ modifier: SearchModifier) -> SearchAction {
        switch result.kind {
        case .app: modifier == .command ? .reveal(result.id) : .launch(result.id)
        case .file: modifier == .command ? .reveal(result.id) : .openFile(result.id)
        case .snippet: .insertSnippet(result.id)
        case .loadout:
            switch modifier {
            case .option: .loadout(result.id, .preview)
            case .shift: .loadout(result.id, .clearAndApply)
            case .plain, .command: .loadout(result.id, .apply)
            }
        }
    }
}
