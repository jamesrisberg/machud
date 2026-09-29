import Foundation

/// What the brain is told about MacHUD: installed HUD apps and loadouts, read from MacHUD's
/// control socket (`apps`, `loadouts`). Only what changes when something is installed or
/// edited is kept (not which apps run now), so the context, and the brain started with it,
/// stays the same from one start to the next.
struct MacHUDSnapshot: Equatable, Sendable {
    struct App: Equatable, Sendable {
        var id: String
        var name: String
        /// Panel ids as MacHUD names them (`<app id>/<panel id>`).
        var panels: [String]
    }

    var apps: [App] = []
    var loadouts: [String] = []
    /// The loadout applied at launch; nil when none is set.
    var startupLoadout: String?

    /// From the `apps` and `loadouts` replies; either may be missing (MacHUD did not answer it).
    init(apps: [String: Any]?, loadouts: [String: Any]?) {
        let appList = apps?["apps"] as? [[String: Any]] ?? []
        self.apps = appList.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return App(id: id, name: entry["name"] as? String ?? id, panels: entry["panels"] as? [String] ?? [])
        }
        let loadoutList = loadouts?["loadouts"] as? [[String: Any]] ?? []
        self.loadouts = loadoutList.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        let startup = loadouts?["startup"] as? String ?? ""
        startupLoadout = startup.isEmpty ? nil : startup
    }

    init(apps: [App] = [], loadouts: [String] = [], startupLoadout: String? = nil) {
        self.apps = apps
        self.loadouts = loadouts
        self.startupLoadout = startupLoadout
    }
}

/// The host context MacHUD's brain starts with: who the agent is, how to act on MacHUD (its
/// tools, never the screen), and what is installed. Bounded, so a large install cannot swamp
/// the runtime's instructions.
enum MacHUDHostContext {
    /// At most this many apps and loadouts are listed; the rest are counted.
    static let listLimit = 40

    /// `snapshot` nil: MacHUD did not answer, so the lists are left out and the agent is told
    /// to ask `machud_status`.
    static func build(snapshot: MacHUDSnapshot?) -> String {
        var lines = [
            "## MacHUD",
            "",
            "You are the brain of MacHUD, the user's macOS desktop HUD: a notch orb they talk to, "
                + "window layouts (loadouts) that place apps in screen regions, a tool dock, and small "
                + "HUD apps with panels and actions. The user usually speaks to you, so keep replies short.",
            "",
            "Act on MacHUD and its apps only through the `\(MacHUDToolServer.name)` tools. Do not drive "
                + "the screen with computer use, AppleScript or the `machud` command line: the tools are "
                + "the supported way and they report what happened.",
            "",
            "- `machud_status`: screens, desktops, loadouts, the tool dock, installed HUD apps with their "
                + "panels and actions, and the voice state. Call it first when unsure what exists.",
            "- `list_loadouts`, `apply_loadout {name}`, `capture_loadout {name}`: arrange windows.",
            "- `show_panel`, `hide_panel`, `toggle_panel {app, panel?}`: an app's panels.",
            "- `list_app_actions {app}`, `app_action {app, verb, args?}`: whatever an app declares.",
            "- `tool_dock`, `park_window`, `unpark`, `open_session {id}`, `feed_add {text}`, `say {text}`.",
        ]
        guard let snapshot else {
            lines += ["", "MacHUD did not report its apps and loadouts; ask `machud_status`."]
            return lines.joined(separator: "\n")
        }
        lines += ["", "### Installed HUD apps", ""]
        if snapshot.apps.isEmpty {
            lines.append("None.")
        } else {
            for app in snapshot.apps.prefix(listLimit) {
                let panels = app.panels.map { $0.hasPrefix(app.id + "/") ? String($0.dropFirst(app.id.count + 1)) : $0 }
                lines.append("- \(app.name) (`\(app.id)`)" + (panels.isEmpty ? "" : ": panels \(panels.joined(separator: ", "))"))
            }
            if snapshot.apps.count > listLimit { lines.append("- … and \(snapshot.apps.count - listLimit) more") }
        }
        lines += ["", "### Loadouts", ""]
        if snapshot.loadouts.isEmpty {
            lines.append("None saved yet.")
        } else {
            for name in snapshot.loadouts.prefix(listLimit) {
                lines.append("- \(name)" + (name == snapshot.startupLoadout ? " (applied at launch)" : ""))
            }
            if snapshot.loadouts.count > listLimit { lines.append("- … and \(snapshot.loadouts.count - listLimit) more") }
        }
        return lines.joined(separator: "\n")
    }
}
