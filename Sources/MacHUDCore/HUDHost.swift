import AppKit
import HUDKit

/// Exposes MacHUD's panels through the MacHUD contract (`hello`, `panel`, `state`,
/// `subscribe`, `settings`, `action`, `quit`) via `HUDControlRouter`. As the umbrella it
/// covers external apps' panels too (ids `<app>/<panel>`), forwarding to their sockets.
@MainActor
final class MacHUDPanelHost: HUDPanelHost {
    private let registry: PanelRegistry
    /// `panel mode parked` for MacHUD's own panels (and for external ones whose window
    /// can be found) goes through the parking controller, so the orb reveals them.
    weak var parking: ParkingController?
    /// MacHUD's own settings (`settings get/set/schema`).
    var ownSettings: MacHUDSettings?

    init(registry: PanelRegistry, parking: ParkingController? = nil) {
        self.registry = registry
        self.parking = parking
        registry.modeProvider = { [weak self] panel in self?.mode(of: panel) ?? .full }
    }

    var panelDescriptors: [HUDManifest.Panel] {
        registry.panels.map { panel in
            if let external = panel as? ExternalPanel {
                var descriptor = external.descriptor
                descriptor.id = external.id
                return descriptor
            }
            var descriptor = HUDManifest.main?.panel(id: panel.id) ?? HUDManifest.Panel(id: panel.id, title: panel.title)
            descriptor.title = panel.title
            descriptor.symbol = panel.symbol
            return descriptor
        }
    }

    var panelStates: [HUDPanelState] {
        registry.panels.map { panel in
            guard let external = panel as? ExternalPanel else {
                return HUDPanelState(id: panel.id, visible: panel.isVisible, mode: mode(of: panel))
            }
            var state = external.state
            state.id = external.id
            state.visible = external.isVisible
            return state
        }
    }

    func showPanel(_ id: String) throws { try panel(id).show() }
    func hidePanel(_ id: String) throws { try panel(id).hide() }
    func togglePanel(_ id: String) throws { try panel(id).toggle() }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        let panel = try panel(id)
        if panel is MenuBarPanel { throw HUDControlError.unsupported("menubar has no frame") }
        if let dock = panel as? ToolDock {
            // The frame picks an edge and a position along it; the dock sizes itself.
            dock.place(inRegion: frame)
            return
        }
        if let external = panel as? ExternalPanel {
            external.show()
            guard external.place(in: frame) else {
                throw HUDControlError.invalid("\(external.appID ?? id) is not reachable and has no window to move")
            }
            return
        }
        if !panel.isVisible { panel.show() }
        guard let window = panel.window else { throw HUDControlError.invalid("panel has no window") }
        window.setFrame(frame, display: true)
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    /// `parked` hands the panel to the parking controller (at `options.edge`, else the
    /// nearest edge), so it gets an orb like any parked slot; `full` and `compact` bring it
    /// back. MacHUD's own panels have no compact form, so `compact` is `full` for them,
    /// except `menubar`, where `compact` collapses the menu bar and `full` expands it.
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        let panel = try panel(id)
        defer { registry.noteChange() }
        if let menuBar = panel as? MenuBarPanel {
            try menuBar.setMode(mode)
            return
        }
        if let external = panel as? ExternalPanel {
            try setExternalMode(external, mode: mode, options: options)
            return
        }
        if panel is ToolDock {
            if mode == .parked { throw HUDControlError.unsupported("tooldock does not park; use tooldock autohide") }
            return
        }
        guard let parking else { throw HUDControlError.unsupported("panel mode") }
        switch mode {
        case .parked:
            if !panel.isVisible { panel.show() }
            guard let window = panel.window else { throw HUDControlError.invalid("panel has no window") }
            let target = ParkingController.Target.own(window)
            if let entry = parking.entry(for: target), options.edge == nil || options.edge == entry.record.edge { return }
            park(target, id: Self.parkingID(panel.id), label: panel.title, rest: window.frame, options: options,
                 parking: parking)
        case .full, .compact:
            if let window = panel.window, let entry = parking.entry(for: .own(window)) {
                parking.unpark(id: entry.record.id)
            }
            if !panel.isVisible { panel.show() }
        }
    }

    private func setExternalMode(_ external: ExternalPanel, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        let target = ParkingController.Target.cooperative(HUDSocketClient(path: external.app.socketPath),
                                                          panelID: external.panelID)
        let parked = parking?.entry(for: target)
        switch mode {
        case .parked:
            // Tracked (orb, hover reveal) when we can tell where the panel rests; otherwise
            // the app parks itself at the edge it chooses.
            if let parking, parked == nil, Accessibility.isTrusted, let rest = external.axWindow()?.cocoaFrame {
                park(target, id: Self.parkingID(external.id), label: external.title, rest: rest, options: options,
                     parking: parking)
            } else if parked == nil {
                external.setMode(.parked, edge: options.edge, peek: options.peek)
            }
        case .full, .compact:
            if let parked { parking?.unpark(id: parked.record.id) }
            if mode == .compact || parked == nil { external.setMode(mode) }
        }
    }

    private func park(_ target: ParkingController.Target, id: String, label: String, rest: CGRect,
                      options: HUDPanelModeOptions, parking: ParkingController) {
        let screen = NSScreen.screens.max {
            $0.frame.intersection(rest).width * $0.frame.intersection(rest).height
                < $1.frame.intersection(rest).width * $1.frame.intersection(rest).height
        }
        let edge = options.edge ?? ParkGeometry.nearestEdge(for: rest, in: screen?.frame ?? rest, allowTop: true)
        parking.park(target, id: id, label: label, rest: rest, edge: edge, peek: options.peek ?? 0, screen: screen)
    }

    /// Parking id of a panel parked through `panel mode` (loadout slots use region ids).
    static func parkingID(_ panelID: String) -> String { "panel:\(panelID)" }

    /// `parked` while the parking controller holds the panel's window.
    func mode(of panel: Panel) -> HUDPanelMode {
        if let external = panel as? ExternalPanel { return external.state.mode }
        if let menuBar = panel as? MenuBarPanel { return menuBar.mode }
        guard let window = panel.window, parking?.entry(for: .own(window)) != nil else { return .full }
        return .parked
    }

    // MARK: - Settings

    func settings() -> [String: Any] { ownSettings?.values ?? [:] }

    func updateSettings(_ values: [String: String]) throws {
        guard let ownSettings else { throw HUDControlError.unsupported("settings set") }
        try ownSettings.apply(values)
    }

    var settingsSchema: HUDSettingsSchema? { ownSettings.map { _ in MacHUDSettings.schema } }

    private func panel(_ id: String) throws -> Panel {
        guard let panel = registry.panel(id: id) else { throw HUDControlError.noSuchPanel(id) }
        return panel
    }
}
