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
    private let router: CapabilityRouter

    init(externals: ExternalPanels) {
        self.externals = externals
        router = CapabilityRouter(capability: Self.capability, externals: externals)
    }

    /// Discovered apps with a panel declaring the capability, in discovery order.
    var providers: [ExternalApp] { router.providers }

    /// `{app, socket, running}` per provider. `running` is true once the app's process is up
    /// (subscribed or not, like `apps`' own `running` field), not only once MacHUD is subscribed.
    var providersJSON: [[String: Any]] { router.providersJSON }

    /// `sessions open id=<sessionKey>`: forwards `action name=open-session id=` to the target
    /// provider (launching an installed one if none runs). `{"ok": true, "app": "<bundle id>"}`
    /// on success; the provider's own reply is passed through unchanged when it says `ok: false`;
    /// `{"ok": false, "error": "No app shows agent sessions"}` when none is discovered.
    func open(id sessionKey: String, done: @escaping ([String: Any]) -> Void) {
        guard let app = router.target() else { done(["ok": false, "error": "No app shows agent sessions"]); return }
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
