import Foundation
import HUDKit

/// MacHUD's `agent-sessions` broker over its control socket: `sessions open id=` and
/// `sessions providers`, sent the way the `machud` CLI sends them. The voice host never names
/// the app that shows sessions; MacHUD finds it from the apps' manifests.
struct MacHUDSessions: SessionOpening {
    /// MacHUD's control socket: `$MACHUD_SOCKET`, else `/tmp/machud-<uid>.sock`.
    let socketPath: String
    /// Long enough for MacHUD to launch an installed provider that is not running.
    var timeout: TimeInterval = 20

    static let unreachable = "MacHUD is not answering"

    func open(id: String) async -> Result<String, SessionOpenError> {
        let reply = await request(["_": "open", "open": "1", "id": id])
        guard let reply else { return .failure(SessionOpenError(message: Self.unreachable)) }
        guard reply["ok"] as? Bool == true else {
            return .failure(SessionOpenError(message: reply["error"] as? String ?? "Could not open the session"))
        }
        return .success(reply["app"] as? String ?? "")
    }

    func providerName() async -> String? {
        guard let reply = await request(["_": "providers", "providers": "1"]), reply["ok"] as? Bool == true,
              let providers = reply["providers"] as? [[String: Any]] else { return nil }
        let running = providers.first { $0["running"] as? Bool == true }
        return (running ?? providers.first)?["app"] as? String
    }

    /// One `sessions` request off the main thread; nil when MacHUD does not answer.
    private func request(_ args: [String: String]) async -> [String: Any]? {
        let path = socketPath
        let timeout = self.timeout
        let reply = await Task.detached(priority: .userInitiated) { () -> UncheckedReply in
            UncheckedReply(value: try? HUDSocketClient(path: path, timeout: timeout).request("sessions", args: args))
        }.value
        return reply.value
    }
}

/// A socket reply crossing from the request's thread back to the caller.
private struct UncheckedReply: @unchecked Sendable {
    let value: [String: Any]?
}
