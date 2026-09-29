import AppKit
import HUDKit

/// The settings window's "Loadouts" tab: every saved loadout with a thumbnail, and the one
/// selected drawn large per display and desktop, with Apply, Preview, Edit Layout, Rename,
/// Duplicate, Apply at Startup and Delete. Edits go through `LoadoutLibrary` (as the
/// `loadouts` verb's do); apply, preview, capture and the editor through the loadout menu's
/// own entry points.
@MainActor
final class LoadoutsTabModel: ObservableObject {
    static let tabID = "loadouts"

    struct Item: Identifiable, Equatable {
        var loadout: Loadout
        var sketch: LoadoutSketch
        var isStartup: Bool
        var isActive: Bool
        /// Hidden layouts that go with it on delete.
        var ownedLayouts: [String]

        var id: String { loadout.name }
        var name: String { loadout.name }
        var isHUDOnly: Bool { loadout.allSlots.isEmpty && loadout.hud != nil }

        /// "2 screens · 2 desktops · 6 windows", "HUD · 3 apps".
        var summary: String {
            let windows = loadout.allSlots.count
            let apps = loadout.hud?.apps?.count ?? 0
            if isHUDOnly { return "HUD · \(Self.count(apps, "app"))" }
            var parts: [String] = []
            if loadout.screenCount > 1 { parts.append(Self.count(loadout.screenCount, "screen")) }
            if loadout.desktopCount > 1 { parts.append(Self.count(loadout.desktopCount, "desktop")) }
            parts.append(Self.count(windows, "window"))
            if loadout.hud != nil { parts.append("HUD") }
            return parts.joined(separator: " · ")
        }

        static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    }

    /// Where the tab reads from and what its buttons do; the app wires these to the store,
    /// the library and the loadout menu, tests to fakes.
    struct Services {
        var config: () -> Config
        var displays: () -> [LoadoutSketch.Display]
        var activeLoadout: () -> String?
        var perform: (LoadoutEdit) throws -> LoadoutEditResult
        var apply: (String) -> Void = { _ in }
        var preview: (String) -> Void = { _ in }
        var edit: (String) -> Void = { _ in }
        var capture: () -> Void = {}
        var drawNew: () -> Void = {}
    }

    @Published private(set) var items: [Item] = []
    @Published var selection: String?
    /// The desktop the large preview shows (nil: whichever is showing).
    @Published var desktop: Int?
    /// The loadout whose delete is waiting for confirmation.
    @Published var confirmingDelete: String?
    /// The name being typed while renaming the selected loadout.
    @Published var renameDraft: String?
    @Published var lastError: String?
    @Published private(set) var displays: [LoadoutSketch.Display] = []

    var services: Services

    init(services: Services) {
        self.services = services
    }

    var selected: Item? { items.first { $0.id == selection } }

    /// Re-read the loadouts and displays, keeping the selection (by name) when it still exists.
    func reload() {
        let config = services.config()
        displays = services.displays()
        let active = services.activeLoadout()
        let gap = CGFloat(config.gap ?? 0)
        items = (config.loadouts ?? []).map { loadout in
            Item(loadout: loadout,
                 sketch: LoadoutSketch.build(loadout, layouts: config.layouts, displays: displays, gap: gap),
                 isStartup: config.startupLoadout == loadout.name, isActive: active == loadout.name,
                 ownedLayouts: config.ownedLayouts(of: loadout.name))
        }
        if selection == nil || !items.contains(where: { $0.id == selection }) { select(items.first?.id) }
        else if let item = selected, !item.sketch.desktops.contains(desktop) { desktop = item.sketch.desktops.first ?? nil }
        if let pending = confirmingDelete, !items.contains(where: { $0.id == pending }) { confirmingDelete = nil }
    }

    func select(_ name: String?) {
        guard selection != name || renameDraft != nil || confirmingDelete != nil else { return }
        selection = name
        desktop = selected?.sketch.desktops.first ?? nil
        renameDraft = nil
        confirmingDelete = nil
        lastError = nil
    }

    // MARK: Actions

    func apply() { if let name = selection { services.apply(name) } }
    func preview() { if let name = selection { services.preview(name) } }
    func edit() { if let name = selection { services.edit(name) } }
    func capture() { services.capture() }
    func drawNew() { services.drawNew() }

    func beginRename() {
        guard let name = selection else { return }
        confirmingDelete = nil
        renameDraft = name
    }

    func cancelRename() { renameDraft = nil }

    func commitRename() {
        guard let old = selection, let draft = renameDraft else { return }
        if run(.rename(old, to: draft)) { renameDraft = nil }
    }

    func duplicate() {
        guard let name = selection else { return }
        run(.duplicate(name, as: nil))
    }

    /// Makes the selected loadout the startup one, or clears it when it already is.
    func toggleStartup() {
        guard let item = selected else { return }
        run(.startup(item.isStartup ? nil : item.name))
    }

    func requestDelete() {
        renameDraft = nil
        confirmingDelete = selection
    }

    func cancelDelete() { confirmingDelete = nil }

    func confirmDelete() {
        guard let name = confirmingDelete else { return }
        let index = items.firstIndex { $0.id == name } ?? 0
        confirmingDelete = nil
        guard run(.delete(name)) else { return }
        // Select the neighbour, as a list does after a delete.
        let names = items.map(\.id)
        select(names.isEmpty ? nil : names[min(index, names.count - 1)])
    }

    /// Performs an edit, reloads and follows the loadout's new name; false (with `lastError`)
    /// when the library refused it.
    @discardableResult
    private func run(_ edit: LoadoutEdit) -> Bool {
        do {
            let result = try services.perform(edit)
            lastError = nil
            reload()
            switch edit {
            case .rename, .duplicate: if let name = result.loadout { select(name) }
            case .delete, .startup: break
            }
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["selected": selection ?? "", "desktop": desktop ?? 0,
                                "loadouts": items.map { item -> [String: Any] in
                                    ["name": item.name, "summary": item.summary, "startup": item.isStartup,
                                     "active": item.isActive, "screens": item.loadout.screenCount,
                                     "desktops": item.loadout.desktopCount, "regions": item.sketch.regions.count,
                                     "ownedLayouts": item.ownedLayouts, "problems": item.sketch.problems]
                                }]
        if let lastError { d["lastError"] = lastError }
        if let confirmingDelete { d["confirmingDelete"] = confirmingDelete }
        return d
    }
}

// MARK: - Occupant presentation

/// Names, icons and colours for what sits in a region. Icons are looked up once per occupant.
@MainActor
enum OccupantStyle {
    private static var icons: [String: NSImage] = [:]

    /// The app's name (`Safari`), the page's host, or a sibling panel's app name.
    static func title(_ occupant: Occupant) -> String {
        switch occupant {
        case .app(let bundleID, let titleMatch):
            let name = appName(bundleID) ?? bundleID
            return titleMatch.map { "\(name) · \($0)" } ?? name
        case .web(let url, _):
            return URL(string: url)?.host ?? url
        case .panel(let id):
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let name = appName(parts[0]) { return name }
            if parts.count == 2 { return parts[0].split(separator: ".").last.map { $0.capitalized } ?? id }
            return id.capitalized
        }
    }

    /// "Web page", "Panel", or nil for a plain app window.
    static func kind(_ occupant: Occupant) -> String? {
        switch occupant {
        case .app: return nil
        case .web: return "Web page"
        case .panel(let id): return id.contains("/") ? "\(id.split(separator: "/").last ?? "") panel" : "MacHUD panel"
        }
    }

    /// An installed app's icon, else a generic one.
    static func appIcon(_ bundleID: String) -> NSImage { icon(.panel(id: bundleID + "/")) }

    static func icon(_ occupant: Occupant) -> NSImage {
        let key: String
        let bundleID: String?
        switch occupant {
        case .app(let id, _): key = "app:\(id)"; bundleID = id
        case .web: key = "web"; bundleID = nil
        case .panel(let id):
            bundleID = id.contains("/") ? String(id.split(separator: "/")[0]) : nil
            key = bundleID.map { "app:\($0)" } ?? "panel:\(id)"
        }
        if let cached = icons[key] { return cached }
        var image: NSImage?
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        if image == nil {
            let symbol: String
            switch occupant {
            case .app: symbol = "app.dashed"
            case .web: symbol = "globe"
            case .panel: symbol = "rectangle.on.rectangle"
            }
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        let result = image ?? NSImage()
        icons[key] = result
        return result
    }

    /// A stable colour per app (not `hashValue`, which changes between launches).
    static func color(_ occupant: Occupant) -> NSColor {
        let key: String
        switch occupant {
        case .app(let id, _): key = id
        case .web(let url, _): key = URL(string: url)?.host ?? url
        case .panel(let id): key = id
        }
        var hash: UInt32 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return palette[Int(hash % UInt32(palette.count))]
    }

    static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink,
                                     .systemGreen, .systemIndigo, .systemMint, .systemYellow, .systemCyan]

    static func appName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }
}
