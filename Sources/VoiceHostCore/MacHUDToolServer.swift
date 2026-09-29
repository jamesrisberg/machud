import BrainKit
import Foundation

/// Where MacHUD's tool server is and which MacHUD it talks to.
struct MacHUDToolServer: Equatable, Sendable {
    /// The server's MCP name: its tools reach the runtime as `mcp__machud__<tool>`.
    static let name = "machud"
    /// The helper's file name, beside `MacHUDVoice` in `Contents/Helpers`.
    static let executableName = "machud-mcp"

    /// `machud-mcp`'s path.
    var command: String
    /// MacHUD's control socket (`MACHUD_SOCKET` for the server).
    var machudSocket: String

    func toolServer(requireApproval: Bool) -> BrainToolServer {
        BrainToolServer(name: Self.name, command: command, environment: ["MACHUD_SOCKET": machudSocket],
                        requireApproval: requireApproval)
    }

    /// `machud-mcp` beside this executable, when it is there and runnable: in the app bundle both
    /// sit in `Contents/Helpers`; in a SwiftPM build both are products in the same folder.
    static func locate(beside executable: URL, machudSocket: String,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> MacHUDToolServer? {
        let path = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(executableName).path
        return isExecutable(path) ? MacHUDToolServer(command: path, machudSocket: machudSocket) : nil
    }
}
