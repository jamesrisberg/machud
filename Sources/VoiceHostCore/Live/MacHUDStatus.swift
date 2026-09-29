import Foundation
import HUDKit

/// MacHUD's installed apps and loadouts over its control socket (`apps`, `loadouts`), for the
/// brain's host context.
struct MacHUDStatus: MacHUDStatusReading {
    /// MacHUD's control socket: `$MACHUD_SOCKET`, else `/tmp/machud-<uid>.sock`.
    let socketPath: String
    var timeout: TimeInterval = 3

    func snapshot() async -> MacHUDSnapshot? {
        let path = socketPath
        let timeout = self.timeout
        let replies = await Task.detached(priority: .utility) { () -> UncheckedReplies in
            func request(_ command: String) -> [String: Any]? {
                guard let reply = try? HUDSocketClient(path: path, timeout: timeout).request(command, args: [:]),
                      reply["ok"] as? Bool != false else { return nil }
                return reply
            }
            return UncheckedReplies(apps: request("apps"), loadouts: request("loadouts"))
        }.value
        guard replies.apps != nil || replies.loadouts != nil else { return nil }
        return MacHUDSnapshot(apps: replies.apps, loadouts: replies.loadouts)
    }
}

/// Socket replies crossing from the request's thread back to the caller.
private struct UncheckedReplies: @unchecked Sendable {
    let apps: [String: Any]?
    let loadouts: [String: Any]?
}
