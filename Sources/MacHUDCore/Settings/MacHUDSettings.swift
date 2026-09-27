import AppKit
import HUDKit

/// MacHUD's own settings, served through `settings get/set/schema` like any sibling's,
/// so the shared settings window renders MacHUD's tab the same way.
@MainActor
final class MacHUDSettings {
    static let schema = HUDSettingsSchema(settings: [
        .init(key: "enabled", title: "Snap while dragging", type: .bool, default: .bool(true), group: "Snapping"),
        .init(key: "trigger", title: "Trigger key", type: .enum, default: .string(Trigger.shift.rawValue),
              options: Trigger.allCases.map { .init(value: $0.rawValue, title: $0.title) }, group: "Snapping",
              help: "Hold while dragging a window to show the regions."),
        .init(key: "gap", title: "Gap between regions (points)", type: .int, default: .int(0), group: "Layout"),
        .init(key: "browser", title: "Browser for web occupants", type: .string, group: "Layout",
              help: "Bundle id, e.g. com.google.Chrome. Empty uses the system default."),
        .init(key: "orbsHidden", title: "Hide parking orbs", type: .bool, default: .bool(false), group: "Parking",
              help: "Hidden by default while the tool dock is on; parked windows then get a tool dock button."),
        .init(key: "toolDock.enabled", title: "Show the tool dock", type: .bool, default: .bool(true), group: "Tool Dock"),
        .init(key: "toolDock.position", title: "Position on screen", type: .enum,
              default: .string(HUDDockPosition.bottom.rawValue),
              options: ToolDock.menuPositions.map { .init(value: $0.rawValue, title: ToolDock.title(of: $0)) },
              group: "Tool Dock", help: "An edge is a single row or column; a corner is an L (hover apps up the side, windowed ones along the edge)."),
        .init(key: "toolDock.autoHide", title: "Automatically hide and show", type: .bool, default: .bool(false),
              group: "Tool Dock"),
        .init(key: "toolDock.iconSize", title: "Icon size (points)", type: .int,
              default: .int(Int(ToolDockConfig.defaultIconSize)), group: "Tool Dock", help: "24 to 96."),
        .init(key: "toolDock.magnify", title: "Magnify icons under the pointer", type: .bool, default: .bool(true),
              group: "Tool Dock"),
        .init(key: "hotkeys.loadoutMenu", title: "Radial menu", type: .string,
              default: .string(HotKeyText.format(Hotkeys.defaults.loadoutMenu)), group: "Hotkeys",
              help: "Hold to show the loadout wheel. Modifiers and a key joined by +, e.g. control+option+space; empty turns it off."),
        .init(key: "hotkeys.dock", title: "Tool dock", type: .string,
              default: .string(HotKeyText.format(Hotkeys.defaults.dock)), group: "Hotkeys",
              help: "Shows or hides the tool dock, e.g. control+option+d; empty turns it off."),
        .init(key: "menuBar.enabled", title: "Hide menu bar items", type: .bool, default: .bool(false), group: "Menu Bar",
              help: "Adds a separator and an expander to the menu bar; ⌘-drag items left of the separator to hide them."),
        .init(key: "menuBar.autoCollapseSeconds", title: "Auto-collapse after (seconds)", type: .int,
              default: .int(Int(MenuBarConfig.defaultAutoCollapse)), group: "Menu Bar", help: "0 never collapses on its own."),
        .init(key: "menuBar.consumeSiblings", title: "Show MacHUD apps' menus here", type: .bool, default: .bool(true),
              group: "Menu Bar", help: "MacHUD's menu gets an Apps section and the apps hide their own menu bar icons while MacHUD runs."),
    ])

    private let store: LayoutStore
    private weak var parking: ParkingController?

    init(store: LayoutStore, parking: ParkingController?) {
        self.store = store
        self.parking = parking
    }

    var values: [String: Any] {
        Self.values(config: store.config, enabled: store.enabled, orbsHidden: parking?.orbsHidden ?? false)
    }

    /// Validates every value first, then applies them all.
    func apply(_ raw: [String: String]) throws {
        let parsed: [String: HUDSettingValue]
        do { parsed = try Self.schema.validate(raw) } catch { throw HUDControlError.invalid("\(error)") }
        for key in ["hotkeys.loadoutMenu", "hotkeys.dock"] {
            if case .string(let text)? = parsed[key], let problem = HotKeyText.problem(text) {
                throw HUDControlError.invalid("\(key): \(problem)")
            }
        }
        if let enabled = parsed["enabled"]?.boolValue { store.enabled = enabled }
        if let orbs = parsed["orbsHidden"]?.boolValue { parking?.setOrbsHidden(orbs) }
        let updated = Self.applying(parsed, to: store.config)
        if updated != store.config { store.save(updated) }
    }

    static func values(config: Config, enabled: Bool, orbsHidden: Bool) -> [String: Any] {
        ["enabled": enabled, "trigger": (config.trigger ?? .shift).rawValue, "gap": Int(config.gap ?? 0),
         "browser": config.browser ?? "", "orbsHidden": orbsHidden,
         "hotkeys.loadoutMenu": HotKeyText.format((config.hotkeys ?? .defaults).loadoutMenu),
         "hotkeys.dock": HotKeyText.format((config.hotkeys ?? .defaults).dock),
         "menuBar.enabled": (config.menuBar ?? MenuBarConfig()).isEnabled,
         "menuBar.autoCollapseSeconds": Int((config.menuBar ?? MenuBarConfig()).autoCollapse),
         "menuBar.consumeSiblings": (config.menuBar ?? MenuBarConfig()).consumesSiblings,
         "toolDock.enabled": (config.toolDock ?? ToolDockConfig()).isEnabled,
         "toolDock.position": (config.toolDock ?? ToolDockConfig()).dockPosition.rawValue,
         "toolDock.autoHide": (config.toolDock ?? ToolDockConfig()).isAutoHide,
         "toolDock.iconSize": Int((config.toolDock ?? ToolDockConfig()).icon),
         "toolDock.magnify": (config.toolDock ?? ToolDockConfig()).isMagnified]
    }

    /// The config-file settings among `values` (enabled and orbs live elsewhere).
    static func applying(_ values: [String: HUDSettingValue], to config: Config) -> Config {
        var c = config
        if case .string(let raw)? = values["trigger"], let t = Trigger(rawValue: raw) { c.trigger = t }
        if case .int(let gap)? = values["gap"] { c.gap = Double(max(0, gap)) }
        if case .string(let browser)? = values["browser"] {
            let trimmed = browser.trimmingCharacters(in: .whitespaces)
            c.browser = trimmed.isEmpty ? nil : trimmed
        }
        if case .string(let text)? = values["hotkeys.loadoutMenu"] {
            c.hotkeys = c.hotkeys ?? .defaults
            c.hotkeys?.loadoutMenu = HotKeyText.parse(text)
        }
        if case .string(let text)? = values["hotkeys.dock"] {
            c.hotkeys = c.hotkeys ?? .defaults
            c.hotkeys?.dock = HotKeyText.parse(text)
        }
        if case .bool(let on)? = values["menuBar.enabled"] {
            c.menuBar = c.menuBar ?? MenuBarConfig()
            c.menuBar?.enabled = on
        }
        if case .int(let seconds)? = values["menuBar.autoCollapseSeconds"] {
            c.menuBar = c.menuBar ?? MenuBarConfig()
            c.menuBar?.autoCollapseSeconds = Double(max(0, seconds))
        }
        if case .bool(let on)? = values["menuBar.consumeSiblings"] {
            c.menuBar = c.menuBar ?? MenuBarConfig()
            c.menuBar?.consumeSiblings = on
        }
        var dock = c.toolDock ?? ToolDockConfig()
        if case .bool(let on)? = values["toolDock.enabled"] { dock.enabled = on }
        if case .string(let raw)? = values["toolDock.position"], let p = HUDDockPosition(rawValue: raw) { dock.position = p }
        if case .bool(let on)? = values["toolDock.autoHide"] { dock.autoHide = on }
        if case .int(let size)? = values["toolDock.iconSize"] {
            let r = ToolDockConfig.iconSizeRange
            dock.iconSize = min(max(Double(size), r.lowerBound), r.upperBound)
        }
        if case .bool(let on)? = values["toolDock.magnify"] { dock.magnify = on }
        if dock != (c.toolDock ?? ToolDockConfig()) { c.toolDock = dock }
        return c
    }
}

/// A hotkey as settings text: modifier names and the key joined by `+`
/// (`control+option+space`). Empty means no hotkey.
enum HotKeyText {
    static let modifiers: [String: String] = ["command": "command", "cmd": "command", "option": "option", "alt": "option",
                                              "control": "control", "ctrl": "control", "shift": "shift",
                                              "⌘": "command", "⌥": "option", "⌃": "control", "⇧": "shift"]

    static func format(_ hotkey: HotKey?) -> String {
        guard let hotkey else { return "" }
        return (hotkey.modifiers.map { modifiers[$0.lowercased()] ?? $0.lowercased() } + [hotkey.key.lowercased()]).joined(separator: "+")
    }

    static func parts(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { "+- ".contains($0) }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// nil when `text` is empty (no hotkey).
    static func parse(_ text: String) -> HotKey? {
        let words = parts(text)
        guard let key = words.last else { return nil }
        return HotKey(key: key, modifiers: words.dropLast().compactMap { modifiers[$0] })
    }

    /// Why `text` is not a hotkey, or nil when it is (or is empty).
    static func problem(_ text: String) -> String? {
        let words = parts(text)
        guard let key = words.last else { return nil }
        guard HotKeyCenter.keyCode(for: key) != nil else { return "unknown key \"\(key)\"" }
        if let bad = words.dropLast().first(where: { modifiers[$0] == nil }) { return "unknown modifier \"\(bad)\"" }
        guard !words.dropLast().isEmpty else { return "needs at least one modifier (command, option, control, shift)" }
        return nil
    }
}
