import HUDKit

/// Brokers HUDKit's `agent-sessions` capability: finds the discovered sibling apps that declare
/// it on a panel and serves `sessions providers` / `sessions open id=`, so a client (the voice
/// host) can ask "who shows agent sessions" instead of naming an app. See
/// `../hudkit/docs/CONTRACT.md` § Agent sessions.
@MainActor
final class SessionsBroker {
    /// The manifest capability a panel lists to offer agent sessions.
    static let capability = HUDAgentSessions.capability

    let externals: ExternalPanels

    init(externals: ExternalPanels) {
        self.externals = externals
    }

    /// Discovered apps with a panel declaring the capability, in discovery order.
    var providers: [ExternalApp] {
        externals.apps.filter { app in app.manifest.panels.contains { $0.capabilities.contains(Self.capability) } }
    }

    /// `{app, socket, running}` per provider. `running` is true once the app's process is up
    /// (subscribed or not, like `apps`' own `running` field), not only once MacHUD is subscribed.
    var providersJSON: [[String: Any]] {
        providers.map { app in
            let health = externals.supervisor.record(app.id)?.health ?? .notRunning
            return ["app": app.id, "socket": app.socketPath,
                    "running": health == .running || health == .socketUnreachable || health == .launching]
        }
    }

    /// The provider `open` sends to: one already subscribed, else one whose process is up
    /// (queued until it answers), else the first discovered one (launched on demand). nil when
    /// no app declares the capability at all.
    private func target() -> ExternalApp? {
        let supervisor = externals.supervisor
        if let running = providers.first(where: { supervisor.record($0.id)?.health == .running }) { return running }
        if let starting = providers.first(where: {
            let health = supervisor.record($0.id)?.health
            return health == .socketUnreachable || health == .launching
        }) { return starting }
        return providers.first
    }

    /// `sessions open id=<sessionKey>`: forwards `action name=open-session id=` to the target
    /// provider (launching an installed one if none runs). `{"ok": true, "app": "<bundle id>"}`
    /// on success; the provider's own reply is passed through unchanged when it says `ok: false`;
    /// `{"ok": false, "error": "No app shows agent sessions"}` when none is discovered.
    func open(id sessionKey: String, done: @escaping ([String: Any]) -> Void) {
        guard let app = target() else { done(["ok": false, "error": "No app shows agent sessions"]); return }
        externals.supervisor.send(app.id, command: "action", args: HUDAgentSessions.openSessionArgs(id: sessionKey)) { result in
            switch result {
            case .success(let reply):
                done((reply["ok"] as? Bool) == false ? reply : ["ok": true, "app": app.id])
            case .failure(let error):
                done(["ok": false, "error": "\(error)"])
            }
        }
    }

    // MARK: - Control

    /// `sessions` (default `providers`), `sessions providers`, `sessions open id=<sessionKey>`.
    func registerControl(_ control: HUDSocketServer) {
        control.register("sessions") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            let action = args["action"] ?? ["providers", "open"].first { args[$0] != nil } ?? "providers"
            switch action {
            case "providers":
                done(["ok": true, "providers": self.providersJSON])
            case "open":
                guard let key = args["id"], !key.isEmpty else {
                    done(["ok": false, "error": "sessions open needs id=<session key>"]); return
                }
                self.open(id: key, done: done)
            default:
                done(["ok": false, "error": "sessions action must be providers or open"])
            }
        }
    }
}
