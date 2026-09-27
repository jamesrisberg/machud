import AppKit
import HUDKit

extension LoadoutEngine {
    /// A `panel` occupant that belongs to another MacHUD-aware app: launch it if needed,
    /// then place over its socket (`panel show` + `panel frame`) if it cooperates, else move
    /// its window by Accessibility.
    func resolveExternal(_ job: SlotJob, _ panel: ExternalPanel) -> Resolution {
        // Accessibility is only consulted when the socket route is out.
        let window = panel.isCooperative ? nil : panel.axWindow()
        let launchedAt = panel.supervisorRecord?.launchedAt
        let graceOver = launchedAt.map { Date().timeIntervalSince($0) > 3 } ?? true
        let route = ExternalPlacement.route(
            installed: FileManager.default.fileExists(atPath: panel.app.bundleURL.path),
            health: panel.health, cooperative: panel.isCooperative,
            hasAXWindow: window != nil, socketGraceOver: graceOver)
        switch route {
        case .socket:
            if !job.askedForWindow { job.askedForWindow = true; panel.show() }
            return .ready(.external(panel))
        case .ax:
            // A reachable app that just does not take `panel frame` still shows its panel.
            if panel.health == .running, !job.askedForWindow { job.askedForWindow = true; panel.show() }
            return window.map { .ready(.ax($0)) } ?? .waiting
        case .launch:
            if !job.launched { job.launched = true; panel.launchApp() }
            return .waiting
        case .wait:
            if panel.health == .running, !job.askedForWindow { job.askedForWindow = true; panel.show() }
            return .waiting
        case .failed(let reason):
            return .failed("\(panel.app.id) \(reason)")
        }
    }
}

extension ExternalPanel {
    var supervisorRecord: AppSupervisor.Record? { supervisor.record(app.id) }
}

extension PanelRegistry {
    /// The parking target for a panel id that names a HUDKit app's panel which is
    /// listening and takes `panel frame`/`panel mode`: that app parks itself. nil for
    /// MacHUD's own panels and for apps that are not reachable (they are placed first,
    /// launching if needed, and parked afterwards).
    func cooperativeParkingTarget(_ id: String) -> ParkingController.Target? {
        guard let external = panel(id: id) as? ExternalPanel, external.isCooperative else { return nil }
        return .cooperative(HUDSocketClient(path: external.app.socketPath), panelID: external.panelID)
    }
}
