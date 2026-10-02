import AppKit
import HUDKit

/// The status menu's Widgets submenu: reveal, edit, add (types by app) and every placed
/// widget with its own actions. Pure, so it is unit tested; `menuItems` builds the AppKit side.
enum WidgetMenuModel {
    enum Command: Equatable {
        case reveal, edit
        case add(app: String, type: String, size: HUDWidgetSize)
        case remove(String)
        case layer(String, HUDWidgetLayer)
        case settings(String)
    }

    indirect enum Item: Equatable {
        case action(String, Command, on: Bool? = nil, enabled: Bool = true)
        case submenu(String, symbol: String?, [Item])
        case header(String)
        case separator

        var title: String {
            switch self {
            case .action(let t, _, _, _), .submenu(let t, _, _), .header(let t): return t
            case .separator: return "-"
            }
        }
    }

    static func title(_ size: HUDWidgetSize) -> String {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    @MainActor
    static func items(_ layer: WidgetLayer, hotkey: HotKey?) -> [Item] {
        var out: [Item] = [
            .action("Reveal Widgets" + (hotkey.map { "  \($0.display)" } ?? ""), .reveal, on: layer.revealed),
            .action("Edit Widgets…", .edit, on: layer.editing),
        ]
        var add: [Item] = []
        let types = layer.types()
        for (appID, group) in Dictionary(grouping: types, by: { $0.app.id }).sorted(by: { a, b in
            (a.value.first?.app.name ?? "").localizedCaseInsensitiveCompare(b.value.first?.app.name ?? "") == .orderedAscending
        }) {
            add.append(.header(group.first?.app.name ?? appID))
            for t in group {
                let placed = layer.records.contains { $0.app == appID && $0.type == t.id }
                let enabled = t.spec.multiple || !placed
                if t.spec.sizes.count == 1 {
                    add.append(.action(t.title, .add(app: appID, type: t.id, size: t.spec.sizes[0]), enabled: enabled))
                } else {
                    add.append(.submenu(t.title, symbol: t.symbol, t.spec.sizes.map {
                        .action(title($0), .add(app: appID, type: t.id, size: $0), enabled: enabled)
                    }))
                }
            }
        }
        out.append(add.isEmpty ? .action("Add Widget", .edit, enabled: false) : .submenu("Add Widget", symbol: "plus", add))
        let records = layer.records
        if !records.isEmpty { out.append(.separator) }
        let placed = layer.placements()
        let screens = layer.screens()
        for r in records {
            let type = layer.type(app: r.app, type: r.type)
            var label = type?.title ?? "\(r.type) (no longer served)"
            var detail = [title(r.size)]
            if let p = placed[r.instance], screens.count > 1, screens.indices.contains(p.screen) { detail.append(screens[p.screen].name) }
            if type != nil { label += " (\(detail.joined(separator: ", ")))" }
            var sub: [Item] = []
            if let type {
                sub.append(.action("Settings…", .settings(r.instance), enabled: layer.schema(type) != nil))
                sub.append(.action("Float Above Windows", .layer(r.instance, r.layer == .float ? .desktop : .float),
                                   on: r.layer == .float))
            }
            sub.append(.action("Remove", .remove(r.instance)))
            out.append(.submenu(label, symbol: type?.symbol, sub))
        }
        return out
    }

    /// The Widgets submenu as one NSMenuItem.
    @MainActor
    static func menuItem(_ layer: WidgetLayer, hotkey: HotKey?, perform: @escaping (Command) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "Widgets", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        let menu = NSMenu()
        for i in items(layer, hotkey: hotkey) { menu.addItem(build(i, perform)) }
        item.submenu = menu
        return item
    }

    @MainActor
    private static func build(_ item: Item, _ perform: @escaping (Command) -> Void) -> NSMenuItem {
        switch item {
        case .separator:
            return .separator()
        case .header(let title):
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            return mi
        case .action(let title, let command, let on, let enabled):
            return ClosureMenuItem(title: title, state: on, enabled: enabled) { perform(command) }
        case .submenu(let title, let symbol, let items):
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            let sub = NSMenu()
            for i in items { sub.addItem(build(i, perform)) }
            mi.submenu = sub
            return mi
        }
    }
}
