import Foundation
import HUDKit

/// A HUD app MacHUD has discovered, as `apps` reports it (its manifest included).
public struct DiscoveredApp: Equatable, Sendable {
    public var id: String
    public var name: String
    public var health: String
    public var running: Bool
    public var panels: [HUDManifest.Panel]

    /// Panel verbs every app handles through `panel` (and MacHUD's `summon`/`dismiss`), not
    /// through `action`.
    public static let panelVerbs: Set<String> = ["show", "hide", "toggle", "frame", "mode"]

    public init(id: String, name: String, health: String = "notRunning", running: Bool = false,
                panels: [HUDManifest.Panel] = []) {
        self.id = id
        self.name = name
        self.health = health
        self.running = running
        self.panels = panels
    }

    /// The `action` verbs a panel's manifest declares, in manifest order.
    public static func actions(of panel: HUDManifest.Panel) -> [String] {
        panel.verbs.filter { !panelVerbs.contains($0) }
    }

    /// Every action verb the app declares, in manifest order without repeats.
    public var actions: [String] {
        var seen = Set<String>()
        return panels.flatMap(Self.actions(of:)).filter { seen.insert($0).inserted }
    }

    /// Parses one row of MacHUD's `apps` reply. Nil without an id.
    public init?(row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        self.id = id
        name = row["name"] as? String ?? id
        health = row["health"] as? String ?? "notRunning"
        running = row["running"] as? Bool ?? false
        if let manifest = row["manifest"],
           let data = try? JSONSerialization.data(withJSONObject: manifest),
           let decoded = try? HUDManifest.decode(data) {
            panels = decoded.panels
        } else {
            panels = []
        }
    }

    public static func parse(appsReply reply: [String: Any]) -> [DiscoveredApp] {
        (reply["apps"] as? [[String: Any]] ?? []).compactMap(DiscoveredApp.init(row:))
    }
}

extension Array where Element == DiscoveredApp {
    /// By bundle id, else by name (case-insensitive), as MacHUD matches apps.
    public func matching(_ key: String) -> DiscoveredApp? {
        first { $0.id == key } ?? first { $0.id.caseInsensitiveCompare(key) == .orderedSame }
            ?? first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }
}
