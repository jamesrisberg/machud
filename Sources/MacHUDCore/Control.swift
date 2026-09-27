import Foundation
import HUDKit

/// MacHUD's control socket: a `HUDSocketServer` on the /tmp path, so shell scripts (and
/// tests) can drive the app: `MacHUD ctl status`, `MacHUD ctl apply loadout=Work clear=1`.
///
/// Wire format: one JSON object per line. Request: {"command": "...", "args": {...}}.
/// Response: {"ok": true, ...} or {"ok": false, "error": "..."}. See HUDSocketServer.
final class ControlServer: HUDSocketServer {
    /// `/tmp/machud-<uid>.sock`, or `$MACHUD_SOCKET`. Kept at /tmp for the CLI and scripts.
    static var socketPath: String { Env.socketPath ?? defaultSocketPath }
    static var defaultSocketPath: String { "/tmp/machud-\(getuid()).sock" }

    /// The MacHUD contract path (`machud.json` names socket "machud"). Only served by the
    /// default instance, so an isolated `MACHUD_SOCKET` instance never takes it over.
    static var contractSocketPath: String? { Env.socketPath == nil ? HUDSocket.path(for: "machud") : nil }

    init() {
        super.init(path: Self.socketPath, additionalPaths: Self.contractSocketPath.map { [$0] } ?? [],
                   label: "machud.control")
    }
}

/// Client side: `MacHUD ctl <command> [key=value ...]`. Prints the JSON response.
enum ControlClient {
    static func run(arguments: [String]) -> Int32 {
        HUDSocketClient.runCLI(path: ControlServer.socketPath, arguments: arguments, appName: "MacHUD")
    }
}
