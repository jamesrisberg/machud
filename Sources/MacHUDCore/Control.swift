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
        HUDSocketClient.runCLI(path: ControlServer.socketPath, arguments: readingSecret(arguments, read: readSecretFromStdin),
                               appName: "MacHUD")
    }

    /// `voice secret set` without `value=` takes the value from stdin, so a key never sits in
    /// the shell history or the process list. `read` is called only in that case.
    static func readingSecret(_ arguments: [String], read: () -> String?) -> [String] {
        let words = Array(arguments.prefix(3))
        guard words == ["voice", "secret", "set"], !arguments.contains(where: { $0.hasPrefix("value=") }),
              let value = read()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return arguments }
        return arguments + ["value=\(value)"]
    }

    /// A line from stdin; at a terminal it prompts without echo.
    private static func readSecretFromStdin() -> String? {
        guard isatty(STDIN_FILENO) != 0 else { return readLine(strippingNewline: true) }
        var buffer = [CChar](repeating: 0, count: 1024)
        guard let line = readpassphrase("Secret: ", &buffer, buffer.count, 0) else { return nil }
        return String(cString: line)
    }
}
