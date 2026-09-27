import AppKit
import HUDKit

/// The MacHUD half of a loadout: where the tool dock sits and, per sibling app, each
/// panel's visibility, mode, frame and (for apps with their own dock strip) the settings
/// that place it.
///
/// ```json
/// "hud": {"dock": {"position": "bottomLeft"},
///         "apps": {"xyz.machud.sift": {"panels": {"browser": {"visible": true, "mode": "full",
///                                                          "frame": {"x": 0, "y": 80, "w": 900, "h": 975},
///                                                          "settings": {"dock.edge": "left"}}}}}}
/// ```
struct HUDLoadout: Codable, Equatable {
    struct Dock: Codable, Equatable {
        var position: HUDDockPosition
    }

    struct PanelEntry: Codable, Equatable {
        var visible: Bool?
        var mode: HUDPanelMode?
        var frame: Frame?
        /// App settings to restore first (strings, as `settings set` takes them).
        var settings: [String: String]?
    }

    struct App: Codable, Equatable {
        var panels: [String: PanelEntry]
    }

    /// `{"x", "y", "w", "h"}`, Cocoa screen coordinates.
    struct Frame: Codable, Equatable {
        var x: Double, y: Double, w: Double, h: Double

        init(_ r: CGRect) {
            x = Double(r.minX.rounded()); y = Double(r.minY.rounded())
            w = Double(r.width.rounded()); h = Double(r.height.rounded())
        }

        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    var dock: Dock?
    var apps: [String: App]?

    init(dock: Dock? = nil, apps: [String: App]? = nil) {
        self.dock = dock
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey { case dock, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dock = try c.decodeIfPresent(Dock.self, forKey: .dock)
        apps = try c.decodeIfPresent([String: App].self, forKey: .apps)
    }

    /// Settings keys an app exposes for its own dock strip; captured when present.
    static let dockSettingKeys = ["dock.position", "dock.edge"]
}

/// Captures and applies `HUDLoadout`s against the tool dock and the running siblings.
@MainActor
final class HUDLoadoutEngine {
    let externals: ExternalPanels
    /// The tool dock's position, and how to move it.
    var dockPosition: () -> HUDDockPosition?
    var setDockPosition: (HUDDockPosition) -> Void

    init(externals: ExternalPanels, dockPosition: @escaping () -> HUDDockPosition?,
         setDockPosition: @escaping (HUDDockPosition) -> Void) {
        self.externals = externals
        self.dockPosition = dockPosition
        self.setDockPosition = setDockPosition
    }

    private var supervisor: AppSupervisor { externals.supervisor }

    // MARK: - Capture

    /// The dock position plus every running (reachable) sibling's panels: visibility and
    /// mode from its pushed state, the frame it reports (or its window's frame), and its
    /// `dock.position`/`dock.edge` settings when it has them.
    func capture(completion: @escaping (HUDLoadout) -> Void) {
        var hud = HUDLoadout(dock: dockPosition().map(HUDLoadout.Dock.init(position:)), apps: [:])
        let running = externals.apps.filter { supervisor.record($0.id)?.health == .running }
        var waiting = running.count
        guard waiting > 0 else { completion(hud); return }
        for app in running {
            // A fresh `state` first (frames from apps that report them), then settings.
            supervisor.send(app.id, command: "state", args: [:]) { [weak self] result in
                guard let self else { return }
                if case .success(let reply) = result { self.supervisor.handle(reply, from: app.id) }
                var panels = self.panelEntries(app)
                self.supervisor.send(app.id, command: "settings", args: ["action": "get"]) { result in
                    if case .success(let reply) = result, let all = reply["settings"] as? [String: Any] {
                        var settings: [String: String] = [:]
                        for key in HUDLoadout.dockSettingKeys { if let v = all[key] { settings[key] = "\(v)" } }
                        if !settings.isEmpty, let first = app.manifest.panels.first?.id { panels[first]?.settings = settings }
                    }
                    hud.apps?[app.id] = HUDLoadout.App(panels: panels)
                    waiting -= 1
                    if waiting == 0 { completion(hud) }
                }
            }
        }
    }

    /// Each panel's visibility and mode as the app last reported them, and its frame: the
    /// one it reports, else (when showing) its window's.
    private func panelEntries(_ app: ExternalApp) -> [String: HUDLoadout.PanelEntry] {
        var panels: [String: HUDLoadout.PanelEntry] = [:]
        let record = supervisor.record(app.id)
        for descriptor in app.manifest.panels {
            let state = record?.panels[descriptor.id] ?? HUDPanelState(id: descriptor.id, visible: false)
            var entry = HUDLoadout.PanelEntry(visible: state.visible, mode: state.mode)
            let panel = externals.registry.panel(id: ExternalPanel.id(app: app.id, panel: descriptor.id)) as? ExternalPanel
            if let frame = record?.frames[descriptor.id] ?? (state.visible ? panel?.currentFrame : nil) {
                entry.frame = HUDLoadout.Frame(frame)
            }
            panels[descriptor.id] = entry
        }
        return panels
    }

    // MARK: - Apply

    struct Report: Equatable {
        var dock: String?
        /// Per app: "applied", or why not.
        var apps: [String: String] = [:]

        var json: [String: Any] {
            var d: [String: Any] = ["apps": apps]
            if let dock { d["dock"] = dock }
            return d
        }
    }

    /// Moves the dock, then per app: launch it if needed, then settings, mode, frame,
    /// visibility, in that order over its socket (commands queue until it listens).
    func apply(_ hud: HUDLoadout, completion: @escaping (Report) -> Void) {
        var report = Report()
        if let position = hud.dock?.position {
            setDockPosition(position)
            report.dock = position.rawValue
        }
        let entries = (hud.apps ?? [:]).sorted { $0.key < $1.key }
        var waiting = entries.count
        guard waiting > 0 else { completion(report); return }
        func finish(_ id: String, _ outcome: String) {
            if report.apps[id] == nil || outcome != "applied" { report.apps[id] = outcome }
        }
        for (appID, entry) in entries {
            guard let app = externals.app(matching: appID) else {
                report.apps[appID] = "not installed"
                waiting -= 1
                if waiting == 0 { completion(report) }
                continue
            }
            let commands = Self.commands(for: entry)
            // Launched directly, not through `apps launch`, so no default placement races
            // the frame below.
            if supervisor.livePIDs(app.id).isEmpty { supervisor.launch(app.id) }
            var left = commands.count
            report.apps[app.id] = "applied"
            if left == 0 {
                waiting -= 1
                if waiting == 0 { completion(report) }
                continue
            }
            for (command, args) in commands {
                supervisor.send(app.id, command: command, args: args) { result in
                    switch result {
                    case .success(let reply) where reply["ok"] as? Bool == false:
                        finish(app.id, "\(command) \(args["action"] ?? ""): \(reply["error"] ?? "failed")")
                    case .failure(let error):
                        finish(app.id, "\(command) \(args["action"] ?? ""): \(error)")
                    default:
                        break
                    }
                    left -= 1
                    if left == 0 {
                        waiting -= 1
                        if waiting == 0 { completion(report) }
                    }
                }
            }
        }
    }

    /// The socket commands for one app, in order: settings, then per panel (by id) mode,
    /// frame (not for a parked panel, whose window sits off screen), visibility.
    static func commands(for entry: HUDLoadout.App) -> [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        let panels = entry.panels.sorted { $0.key < $1.key }
        var settings: [String: String] = [:]
        for (_, p) in panels { settings.merge(p.settings ?? [:]) { a, _ in a } }
        if !settings.isEmpty { out.append(("settings", settings.merging(["action": "set"]) { a, _ in a })) }
        for (id, p) in panels {
            if let mode = p.mode { out.append(("panel", ["action": "mode", "id": id, "mode": mode.rawValue])) }
            if p.mode != .parked, let frame = p.frame {
                out.append(("panel", ExternalPanel.frameArgs(panelID: id, frame.rect)))
            }
            if let visible = p.visible, p.mode != .parked || !visible {
                out.append(("panel", ["action": visible ? "show" : "hide", "id": id, "reason": "summon"]))
            }
        }
        return out
    }
}

/// Applies `startupLoadout` once, about `delay` seconds after launch and as soon as every
/// sibling it names that is already running is reachable (or `patience` more seconds
/// have passed). Pure apart from the injected closures, so it is unit tested.
@MainActor
final class StartupLoadout {
    static let delay: TimeInterval = 2
    static let poll: TimeInterval = 0.25
    static let patience: TimeInterval = 8

    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// The loadout to apply now (nil: none configured or it no longer exists).
    var loadout: () -> Loadout?
    /// Whether the app is running (has a process) and whether it is reachable.
    var isRunning: (String) -> Bool
    var isReachable: (String) -> Bool
    var apply: (Loadout) -> Void
    private(set) var applied = false
    private var waited: TimeInterval = 0

    init(schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void,
         loadout: @escaping () -> Loadout?, isRunning: @escaping (String) -> Bool,
         isReachable: @escaping (String) -> Bool, apply: @escaping (Loadout) -> Void) {
        self.schedule = schedule
        self.loadout = loadout
        self.isRunning = isRunning
        self.isReachable = isReachable
        self.apply = apply
    }

    func start() {
        schedule(Self.delay) { [weak self] in self?.check() }
    }

    /// Siblings named by the loadout's `hud` that are up but not listening yet.
    func pending(_ loadout: Loadout) -> [String] {
        (loadout.hud?.apps ?? [:]).keys.sorted().filter { isRunning($0) && !isReachable($0) }
    }

    private func check() {
        guard !applied, let loadout = loadout() else { return }
        if pending(loadout).isEmpty || waited >= Self.patience {
            applied = true
            apply(loadout)
            return
        }
        waited += Self.poll
        schedule(Self.poll) { [weak self] in self?.check() }
    }
}
