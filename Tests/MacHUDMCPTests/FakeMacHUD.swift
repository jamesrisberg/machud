import XCTest
import HUDKit
@testable import MacHUDMCPCore

/// A stand-in MacHUD control socket (HUDKit's socket server on a temp path): answers the
/// commands the tool server sends from `replies`, records every request, and pushes `state`
/// events to subscribers. It never reaches the real MacHUD.
@MainActor
final class FakeMacHUD {
    let dir: URL
    let path: String
    let server: HUDSocketServer
    /// Replies by command (default `{"ok": true}`); a closure sees the args.
    var replies: [String: ([String: String]) -> [String: Any]] = [:]
    private(set) var requests: [(command: String, args: [String: String])] = []

    static let commands = ["apps", "panels", "loadouts", "status", "screens", "tooldock", "park", "unpark", "voice",
                           "sessions", "feed", "summon", "dismiss", "apply", "capture"]

    init() {
        dir = URL(fileURLWithPath: "/tmp/mcp-\(getpid())-\(Int.random(in: 0..<100_000))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("m.sock").path
        server = HUDSocketServer(path: path, label: "machud-mcp.test.fake")
        for command in Self.commands {
            server.register(command) { [unowned self] args, done in
                self.requests.append((command, args))
                done(self.replies[command]?(args) ?? ["ok": true])
            }
        }
        setApps([Self.pad, Self.dashboard])
    }

    func start() { XCTAssertTrue(server.start()) }

    func stop() { server.stop() }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func requests(_ command: String) -> [[String: String]] {
        requests.filter { $0.command == command }.map(\.args)
    }

    /// Pushes a `state` event to every subscriber (what MacHUD does when apps change).
    func pushState() { server.publish("state", payload: ["panels": []]) }

    func setApps(_ apps: [[String: Any]]) {
        replies["apps"] = { _ in ["ok": true, "apps": apps] }
    }

    static let pad: [String: Any] = [
        "id": "xyz.machud.scratch", "name": "Scratch", "health": "running", "running": true,
        "panels": ["xyz.machud.scratch/pad"],
        "manifest": ["id": "xyz.machud.scratch", "name": "Scratch", "socket": "scratch",
                     "panels": [["id": "pad", "title": "Scratch", "kind": "hover", "capabilities": ["acceptsFileDrop"],
                                 "verbs": ["show", "hide", "toggle", "frame", "mode", "append", "new", "clear"]]]],
    ]
    static let dashboard: [String: Any] = [
        "id": "xyz.machud.mechahud", "name": "MechaHUD", "health": "notRunning", "running": false,
        "panels": ["xyz.machud.mechahud/dashboard"],
        "manifest": ["id": "xyz.machud.mechahud", "name": "MechaHUD", "socket": "mechahud",
                     "panels": [["id": "dashboard", "title": "Dashboard", "kind": "windowed",
                                 "capabilities": ["agent-sessions"],
                                 "verbs": ["show", "hide", "frame", "open-session", "approve", "deny"]]]],
    ]
    static let stash: [String: Any] = [
        "id": "xyz.machud.stash", "name": "Stash", "health": "running", "running": true,
        "panels": ["xyz.machud.stash/history"],
        "manifest": ["id": "xyz.machud.stash", "name": "Stash", "socket": "stash",
                     "panels": [["id": "history", "title": "Stash", "kind": "hover", "capabilities": ["text-feed"],
                                 "verbs": ["show", "hide", "paste"]]]],
    ]
}

/// Collects what the MCP server writes, one parsed JSON object per line.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[String: Any]] = []

    func append(_ line: String) {
        XCTAssertFalse(line.contains("\n"), "stdio messages must not contain newlines")
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? ["unparsed": line]
        lock.lock(); lines.append(object); lock.unlock()
    }

    var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return lines }

    func response(id: Int) -> [String: Any]? {
        all.first { ($0["id"] as? Int) == id }
    }

    func notifications(_ method: String) -> [[String: Any]] {
        all.filter { $0["method"] as? String == method }
    }
}

@MainActor
func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return condition()
}
