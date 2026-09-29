import Foundation
import MacHUDMCPCore

// machud-mcp: MacHUD as an MCP tool server over stdio, for the voice host's brain (Codex, Claude
// Code, mclaude) or any MCP client. Talks to MacHUD's control socket: MACHUD_SOCKET, else
// MacHUD's contract socket. stdout carries only protocol messages; diagnostics go to stderr.

/// The enclosing MacHUD's version (`Contents/Helpers/machud-mcp` → `Contents/Info.plist`), or
/// "dev" outside an app bundle.
func enclosingVersion() -> String {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
    let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
}

if CommandLine.arguments.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) {
    print("""
        usage: machud-mcp
        An MCP server (stdio) exposing MacHUD's tools. Reads JSON-RPC lines on stdin, writes them on stdout.
        MACHUD_SOCKET  MacHUD's control socket (default: \(SocketTransport.defaultPath(environment: [:])))
        """)
    exit(0)
}

setvbuf(stdout, nil, _IOLBF, 0)
let output = NSLock()
let socketPath = SocketTransport.defaultPath()
let tools = MacHUDTools(transport: SocketTransport(path: socketPath))
let server = MCPServer(tools: tools, version: enclosingVersion()) { line in
    output.lock()
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
    output.unlock()
}
let watcher = AppWatcher(tools: tools) { server.toolsMayHaveChanged() }
watcher.start()
FileHandle.standardError.write(Data("machud-mcp: serving MacHUD at \(socketPath)\n".utf8))

while let line = readLine(strippingNewline: true) {
    server.receive(line: line)
}
// The client closed stdin: let requests in flight answer, then exit.
watcher.stop()
Thread.sleep(forTimeInterval: 0.2)
exit(0)
