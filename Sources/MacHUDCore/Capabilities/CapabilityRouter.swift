import HUDKit

/// Finds the discovered sibling apps whose manifest declares a given capability on some panel,
/// and classifies which are already running. Shared by every capability broker (`SessionsBroker`
/// for `agent-sessions`, `FeedBroker` for `text-feed`) so each one only implements its own
/// fan-out or forwarding behaviour, not provider discovery.
@MainActor
final class CapabilityRouter {
    let capability: String
    let externals: ExternalPanels

    init(capability: String, externals: ExternalPanels) {
        self.capability = capability
        self.externals = externals
    }

    /// Discovered apps with a hover or windowed panel declaring the capability, in discovery
    /// order (a widget type's capabilities do not make its app a provider).
    var providers: [ExternalApp] {
        externals.apps.filter { app in app.manifest.presentedPanels.contains { $0.capabilities.contains(capability) } }
    }

    /// True once the app's process is up (subscribed, connecting, or an on-demand launch is
    /// already in flight), like `apps`' own `running` field — not only once MacHUD is
    /// subscribed. Sending a command to an app in any of these states never triggers a new
    /// launch (`AppSupervisor.send` only launches when no process is live at all).
    func isRunning(_ app: ExternalApp) -> Bool {
        let health = externals.supervisor.record(app.id)?.health ?? .notRunning
        return health == .running || health == .socketUnreachable || health == .launching
    }

    /// `{app, socket, running}` per provider.
    var providersJSON: [[String: Any]] {
        providers.map { app in ["app": app.id, "socket": app.socketPath, "running": isRunning(app)] }
    }

    /// Providers whose process is already up, in discovery order.
    var runningProviders: [ExternalApp] { providers.filter(isRunning) }

    /// One provider to forward a single request to: one already subscribed, else one whose
    /// process is up (queued until it answers), else the first discovered one (launched on
    /// demand). nil when no app declares the capability at all.
    func target() -> ExternalApp? {
        let supervisor = externals.supervisor
        if let running = providers.first(where: { supervisor.record($0.id)?.health == .running }) { return running }
        if let starting = providers.first(where: {
            let health = supervisor.record($0.id)?.health
            return health == .socketUnreachable || health == .launching
        }) { return starting }
        return providers.first
    }
}
