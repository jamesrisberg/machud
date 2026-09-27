import AppKit
import HUDKit

/// One button in the tool dock.
struct ToolDockItem: Equatable {
    enum Source: Equatable {
        /// A MacHUD sibling app (bundle id).
        case app(String)
        /// Windows parked while the orbs are hidden.
        case parked
    }

    enum Behaviour: Equatable {
        /// Drops out of the dock while the pointer is on the button.
        case hover
        /// Click summons and dismisses.
        case windowed
        /// Several panels: click opens a menu of them.
        case menu
    }

    /// App bundle id, or `parked`.
    var id: String
    var title: String
    var symbol: String
    var source: Source
    var behaviour: Behaviour
    /// Registry ids of the panels behind the button.
    var panelIDs: [String]
    /// The app bundle, for its icon.
    var bundlePath: String?
    /// 0: hover apps, 1: windowed apps.
    var group: Int
    /// The panel that takes files dropped on the button (`acceptsFileDrop`), if any.
    var dropPanelID: String? = nil

    var isHover: Bool { behaviour == .hover }
    var acceptsDrop: Bool { dropPanelID != nil }
    var appID: String? { if case .app(let id) = source { return id }; return nil }
}

/// What the tool dock shows. Pure, so it is unit tested.
enum ToolDockModel {
    static let parkedID = "parked"

    /// One list in `HUDManifest.dockSorted` order: hover apps first, then windowed ones;
    /// within a group by the manifest's `order` (none last), then by name. An app goes by
    /// its first panel in that order. The Parked Windows button (when `hasParked`: the
    /// orbs are hidden and something is parked) ends the hover group.
    static func items(apps: [ExternalApp], hasParked: Bool, hidden: Set<String> = []) -> [ToolDockItem] {
        let byName = apps.filter { !$0.manifest.panels.isEmpty && !hidden.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // dockSorted keeps ties in the order given (by name here); tag each app's lead panel
        // with its index so the result maps back.
        let leads = byName.enumerated().map { i, app -> HUDManifest.Panel in
            var lead = HUDManifest.dockSorted(app.manifest.panels)[0]
            lead.id = String(i)
            return lead
        }
        let sorted = HUDManifest.dockSorted(leads).compactMap { Int($0.id).map { byName[$0] } }
        var out: [ToolDockItem] = sorted.map { app in
            let panels = HUDManifest.dockSorted(app.manifest.panels)
            let lead = panels[0]
            let behaviour: ToolDockItem.Behaviour = panels.count > 1 ? .menu : (lead.kind == .hover ? .hover : .windowed)
            let drop = panels.first { $0.capabilities.contains(HUDDrop.capability) }
            return ToolDockItem(id: app.id, title: app.name, symbol: lead.symbol ?? app.manifest.iconName ?? "app",
                                source: .app(app.id), behaviour: behaviour,
                                panelIDs: panels.map { ExternalPanel.id(app: app.id, panel: $0.id) },
                                bundlePath: app.bundleURL.path, group: lead.kind == .hover ? 0 : 1,
                                dropPanelID: drop.map { ExternalPanel.id(app: app.id, panel: $0.id) })
        }
        if hasParked {
            let parked = ToolDockItem(id: parkedID, title: "Parked Windows", symbol: "rectangle.stack",
                                      source: .parked, behaviour: .hover, panelIDs: [], bundlePath: nil, group: 0)
            out.insert(parked, at: out.firstIndex { $0.group == 1 } ?? out.endIndex)
        }
        return out
    }

    /// Buttons per group, `[hover, windowed]`, for `ToolDockLayout`.
    static func groups(_ items: [ToolDockItem]) -> [Int] {
        [items.filter { $0.group == 0 }.count, items.filter { $0.group == 1 }.count]
    }
}

/// Hover for all the hover buttons at once. Pure, so it is unit tested.
///
/// - Resting on a hover button for `showDelay` (60 ms) shows its panel.
/// - While it shows, the pointer may be anywhere in its region: the dock bar, the panel and
///   the rectangle between them (the caller computes it). Leaving the region for
///   `hideGrace` (120 ms) hides it.
/// - Reaching another hover button while one shows switches at once: the new one shows,
///   then the old one hides, in that order, so the two cross-fade.
/// - A click pins a panel open (hovering elsewhere does not hide it); clicking again
///   unpins and hides it, and the pointer must leave that button before hovering it
///   shows the panel again.
struct ToolDockHover: Equatable {
    static let showDelay: TimeInterval = 0.06
    static let hideGrace: TimeInterval = 0.12
    /// Clock readings are floating point: 10.06 - 10 is a hair under 0.06.
    static let tolerance: TimeInterval = 1e-6

    enum Event: Equatable {
        case show(String)
        case hide(String)
    }

    var showDelay: TimeInterval = Self.showDelay
    var hideGrace: TimeInterval = Self.hideGrace

    /// Shown by hovering (not pinned).
    private(set) var active: String?
    private(set) var pinned: Set<String> = []
    /// The button under the pointer that is about to show, and since when.
    private(set) var armed: String?
    private var armedSince: TimeInterval = 0
    /// When the pointer left the active panel's region.
    private(set) var leavingSince: TimeInterval?
    /// Clicked shut: ignored until the pointer leaves its button.
    private(set) var suppressed: String?

    func isShown(_ id: String) -> Bool { active == id || pinned.contains(id) }
    func isPinned(_ id: String) -> Bool { pinned.contains(id) }
    var shown: [String] { (pinned.union(active.map { [$0] } ?? [])).sorted() }

    /// One tick. `buttons`: every hover button's hit area; `region`: where the pointer may
    /// be while `active` stays (ignored when nothing is active).
    mutating func update(mouse: CGPoint, buttons: [String: CGRect], region: [CGRect], now: TimeInterval) -> [Event] {
        let on = buttons.keys.sorted().first { buttons[$0]!.contains(mouse) }
        if let s = suppressed, on != s { suppressed = nil }
        if let a = active {
            if let b = on, b != a, b != suppressed, !pinned.contains(b) {
                active = b
                leavingSince = nil
                armed = nil
                return [.show(b), .hide(a)]
            }
            if on == a || region.contains(where: { $0.contains(mouse) }) {
                leavingSince = nil
                return []
            }
            let since = leavingSince ?? now
            leavingSince = since
            guard now - since >= hideGrace - Self.tolerance else { return [] }
            active = nil
            leavingSince = nil
            return [.hide(a)]
        }
        guard let b = on, b != suppressed, !pinned.contains(b) else {
            armed = nil
            return []
        }
        if armed != b {
            armed = b
            armedSince = now
        }
        guard now - armedSince >= showDelay - Self.tolerance else { return [] }
        armed = nil
        active = b
        leavingSince = nil
        return [.show(b)]
    }

    /// A click on a hover button: pins it (showing it if needed), or unpins and hides it.
    mutating func click(_ id: String) -> [Event] {
        if pinned.contains(id) {
            pinned.remove(id)
            suppressed = id
            return [.hide(id)]
        }
        pinned.insert(id)
        armed = nil
        if active == id {
            active = nil
            leavingSince = nil
            return []
        }
        return [.show(id)]
    }

    /// Shows `id` from outside (summon, a drag resting on the button). `pin` keeps it open
    /// like a click; otherwise it behaves as if hovered, taking over from the active one.
    mutating func open(_ id: String, pin: Bool) -> [Event] {
        if pin { return pinned.contains(id) ? [] : click(id) }
        guard !isShown(id) else { return [] }
        let old = active
        active = id
        leavingSince = nil
        armed = nil
        return [.show(id)] + (old.map { [.hide($0)] } ?? [])
    }

    /// Hides `id` whatever its state.
    mutating func close(_ id: String) -> [Event] {
        let was = isShown(id)
        pinned.remove(id)
        if active == id { active = nil; leavingSince = nil }
        return was ? [.hide(id)] : []
    }

    /// Forget buttons that went away; hides any showing.
    mutating func retain(_ ids: Set<String>) -> [Event] {
        var out: [Event] = []
        for id in shown where !ids.contains(id) { out += close(id) }
        if let a = armed, !ids.contains(a) { armed = nil }
        return out
    }
}

/// What the tool dock persists outside layouts.json: the frame each panel had when it was
/// last dismissed, so summoning puts it back there.
struct ToolDockState: Codable, Equatable {
    var frames: [String: CGRect] = [:]

    init(frames: [String: CGRect] = [:]) { self.frames = frames }

    private enum CodingKeys: String, CodingKey { case frames }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frames = try c.decodeIfPresent([String: CGRect].self, forKey: .frames) ?? [:]
    }

    mutating func remember(_ frame: CGRect, for panelID: String) {
        guard frame.width >= 1, frame.height >= 1 else { return }
        frames[panelID] = frame
    }

    /// The remembered frame, if it is still on one of `screens`.
    func frame(for panelID: String, screens: [CGRect]) -> CGRect? {
        guard let f = frames[panelID], screens.contains(where: { $0.intersects(f) }) else { return nil }
        return f
    }
}

/// Reads and writes `ToolDockState` beside parking's state (not in the watched config
/// directory itself).
struct ToolDockStore {
    let url: URL

    static var defaultURL: URL {
        LayoutStore.configDirectory.appendingPathComponent("state/tooldock.json")
    }

    func load() -> ToolDockState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ToolDockState.self, from: data) else { return ToolDockState() }
        return state
    }

    func save(_ state: ToolDockState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("MacHUD: failed to save %@: %@", url.path, "\(error)")
        }
    }
}
