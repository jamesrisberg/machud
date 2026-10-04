import ApplicationServices
import Foundation

/// A menu item as the new-window search reads it.
protocol NewWindowMenuItem {
    var menuTitle: String { get }
    var menuEnabled: Bool { get }
    /// The items of its submenu; empty when it has none.
    var submenuItems: [Self] { get }
}

/// Whether an app can open another window, read from its menus by title: an enabled "New
/// Window" or "New <something> Window" item ("New Finder Window", Mail's "New Viewer Window"),
/// whatever its shortcut, in a menu or one submenu down (Xcode's File › New › Window, read as
/// "New Window"). ⌘N is not a sign: in Notes, Mail, Calendar, Reminders or Xcode it makes a note,
/// a message, an event, a reminder or a file, so it is never pressed. A private or incognito
/// window counts only when nothing else matches. Titles are matched in English: under another
/// system language no item matches and the app counts as single-window (`NewWindowClass.single`).
enum NewWindowMenu {
    enum Match: Equatable {
        case window
        case privateWindow
    }

    /// How `title` matches, if it does.
    static func match(_ title: String) -> Match? {
        var words = title.trimmingCharacters(in: .whitespaces)
        for ellipsis in ["…", "..."] where words.hasSuffix(ellipsis) { words = String(words.dropLast(ellipsis.count)) }
        let lower = words.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower == "new window" || (lower.hasPrefix("new ") && lower.hasSuffix(" window")) else { return nil }
        let isPrivate = ["private", "incognito", "inprivate"].contains { lower.contains($0) }
        return isPrivate ? .privateWindow : .window
    }

    /// The item to press among `menus` (the menu bar's menus, each its title and items, in order):
    /// the first enabled window item, else the first enabled private one. Each item is tried,
    /// then its submenu's items, alone and after the item's title ("New" › "Window"). A matching
    /// item with a submenu (Terminal's New Window, one entry per profile) gives its first entry.
    /// The Window menu's last part, after its last separator, lists the app's open windows: an
    /// entry there titled "New Finder Window" would bring that window forward (perhaps on another
    /// desktop), not open one, so it is skipped; with no separator all of the menu is skipped.
    static func item<Item: NewWindowMenuItem>(in menus: [(title: String, items: [Item])]) -> Item? {
        var privateOne: Item?
        func consider(_ match: Match, _ pressable: Item?) -> Item? {
            guard let pressable else { return nil }
            if match == .window { return pressable }
            if privateOne == nil { privateOne = pressable }
            return nil
        }
        for (title, all) in menus {
            var menu = all
            if title == "Window" { menu = all.lastIndex { $0.menuTitle.isEmpty }.map { Array(all[..<$0]) } ?? [] }
            for item in menu where !item.menuTitle.isEmpty {
                if let match = match(item.menuTitle) {
                    guard item.menuEnabled else { continue }
                    let submenu = item.submenuItems
                    let pressable = submenu.isEmpty ? item : submenu.first { $0.menuEnabled && !$0.menuTitle.isEmpty }
                    if let found = consider(match, pressable) { return found }
                    continue
                }
                guard item.menuEnabled else { continue }
                for child in item.submenuItems where !child.menuTitle.isEmpty && child.submenuItems.isEmpty {
                    guard let match = match(child.menuTitle) ?? match("\(item.menuTitle) \(child.menuTitle)"),
                          child.menuEnabled else { continue }
                    if let found = consider(match, child) { return found }
                }
            }
        }
        return privateOne
    }

    /// The app's window item, if its menu bar is reachable without activating it.
    static func item(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = app.elementAttribute(kAXMenuBarAttribute),
              let titles = bar.rawAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        let menus = titles.map { (title: $0.stringAttribute(kAXTitleAttribute) ?? "", items: AXMenuItem.items(of: $0)) }
        return item(in: menus)?.element
    }

    /// Ask a running app for another window by pressing its window item, without activating it.
    /// True once the item was pressed.
    static func press(pid: pid_t) -> Bool {
        guard let item = item(pid: pid) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
}

extension NewWindowClass {
    /// How the running app `pid` gets another window: the browser list, else its menus. The one
    /// answer the planner, a failed fetch and the new-window request share.
    static func of(bundleID: String, pid: pid_t) -> NewWindowClass {
        if opensWindowsElsewhere(bundleID) { return .single }
        if browsers.contains(bundleID) { return .browser }
        return NewWindowMenu.item(pid: pid) != nil ? .menu : .single
    }
}

/// A live menu item; each attribute is read when asked for.
private struct AXMenuItem: NewWindowMenuItem {
    let element: AXUIElement

    /// The items of the menu under `element` (a menu bar title, or an item with a submenu).
    static func items(of element: AXUIElement) -> [AXMenuItem] {
        guard let menu = (element.rawAttribute(kAXChildrenAttribute) as? [AXUIElement])?.first,
              let items = menu.rawAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return items.map(AXMenuItem.init)
    }

    var menuTitle: String { element.stringAttribute(kAXTitleAttribute) ?? "" }
    var menuEnabled: Bool { element.rawAttribute(kAXEnabledAttribute) as? Bool != false }
    var submenuItems: [AXMenuItem] { Self.items(of: element) }
}
