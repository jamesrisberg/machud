import Foundation

/// A panel the editor's occupant picker offers as a `.panel(id:)` occupant: MacHUD's
/// own panels, then every panel the discovered sibling apps declare (running or not, since
/// applying the loadout launches them).
struct PanelChoice: Equatable {
    var id: String
    var title: String
    /// The sibling app's name; nil for MacHUD's own panels.
    var appName: String?
    /// "running", "not running", ... for sibling apps.
    var status: String?

    var isExternal: Bool { appName != nil }

    /// Button label: `Sift · Browser (not running)`.
    var label: String {
        guard let appName else { return title }
        let name = title.caseInsensitiveCompare(appName) == .orderedSame ? appName : "\(appName) · \(title)"
        guard let status, status != AppSupervisor.Health.running.rawValue else { return name }
        return "\(name) (\(status.replacingOccurrences(of: "notRunning", with: "not running")))"
    }

    /// Own panels first (registry order), then sibling panels by app name.
    @MainActor
    static func all(in registry: PanelRegistry) -> [PanelChoice] {
        var own: [PanelChoice] = []
        var external: [PanelChoice] = []
        for panel in registry.panels {
            if let e = panel as? ExternalPanel {
                external.append(PanelChoice(id: e.id, title: e.title, appName: e.app.name, status: e.health.rawValue))
            } else if !panel.id.hasPrefix("web:") {
                own.append(PanelChoice(id: panel.id, title: panel.title))
            }
        }
        external.sort { ($0.appName ?? "", $0.title) < ($1.appName ?? "", $1.title) }
        return own + external
    }
}
