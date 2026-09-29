import Foundation

/// An MCP server over newline-delimited JSON-RPC (the stdio transport), serving `MacHUDTools`.
///
/// It speaks both eras of the protocol:
/// - legacy (2025-11-25 and earlier): `initialize` negotiates the version, then
///   `notifications/tools/list_changed` goes to the client whenever the tool list changes;
/// - modern (2026-07-28): no handshake; each request names its version in
///   `_meta["io.modelcontextprotocol/protocolVersion"]`, `server/discover` describes the server,
///   and `subscriptions/listen` opens the stream that carries `list_changed` (tagged with the
///   subscription's request id) until the client cancels it.
///
/// Requests are handled concurrently (a tool call can take seconds while MacHUD applies a
/// loadout), so replies may leave in a different order than requests came; `write` is
/// serialized.
public final class MCPServer: @unchecked Sendable {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let subscriptionKey = "io.modelcontextprotocol/subscriptionId"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    public let tools: MacHUDTools
    public let name: String
    public let version: String
    public let instructions: String
    private let write: @Sendable (String) -> Void
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var initializedLegacy = false
    /// Open `subscriptions/listen` requests that asked for tool list changes, by request id.
    private var listeners: [String: Any] = [:]
    private var lastToolList: String?

    public init(tools: MacHUDTools, name: String = "machud", version: String,
                instructions: String = MCPServer.defaultInstructions,
                queue: DispatchQueue = DispatchQueue(label: "machud-mcp.requests", attributes: .concurrent),
                write: @escaping @Sendable (String) -> Void) {
        self.tools = tools
        self.name = name
        self.version = version
        self.instructions = instructions
        self.queue = queue
        self.write = write
    }

    public static let defaultInstructions = """
        MacHUD arranges the user's Mac: saved loadouts put apps and windows in screen regions, a tool \
        dock shows the MacHUD family's HUD apps (Stash, Scratch, Sift, MechaHUD, …), windows can be \
        parked behind edge orbs, and a voice host speaks replies. Call machud_status first to see the \
        displays, loadouts, apps and their action verbs. Applying a loadout, capturing and parking \
        change the user's live desktop: do them when asked.
        """

    // MARK: - Input

    /// Handles one line from the client. Replies go through `write`, possibly later.
    public func receive(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            send(error: -32700, "Parse error", id: NSNull())
            return
        }
        guard let message = object as? [String: Any] else {
            send(error: -32600, "Invalid Request: one JSON-RPC object per line", id: NSNull())
            return
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to a request we never send, or garbage: nothing to answer.
            if id != nil, message["result"] == nil, message["error"] == nil {
                send(error: -32600, "Invalid Request", id: id!)
            }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id, !(id is NSNull) else {
            notification(method, params)
            return
        }
        queue.async { [self] in handle(method, params, id: id) }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "notifications/initialized":
            break
        case "notifications/cancelled":
            // Ending a `subscriptions/listen` stream answers it; other requests finish anyway.
            guard let requestID = params["requestId"] else { return }
            let key = Self.key(requestID)
            lock.lock()
            let listener = listeners.removeValue(forKey: key)
            lock.unlock()
            if let listener {
                send(result: ["resultType": "complete", "_meta": [Self.subscriptionKey: listener]], id: listener)
            }
        default:
            break
        }
    }

    // MARK: - Requests

    private func handle(_ method: String, _ params: [String: Any], id: Any) {
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let requested = meta[Self.versionKey] as? String
        if let requested, !(Self.modernVersions + Self.legacyVersions).contains(requested) {
            send(error: -32022, "Unsupported protocol version", id: id,
                 data: ["supported": Self.modernVersions + Self.legacyVersions, "requested": requested])
            return
        }
        let modern = requested.map(Self.modernVersions.contains) ?? false
        func reply(_ result: [String: Any]) {
            var result = result
            if modern { result["resultType"] = "complete" }
            send(result: result, id: id)
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let chosen = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
            lock.lock(); initializedLegacy = true; lock.unlock()
            send(result: [
                "protocolVersion": chosen,
                "capabilities": capabilities,
                "serverInfo": ["name": name, "title": "MacHUD", "version": version],
                "instructions": instructions,
            ], id: id)
        case "server/discover":
            reply([
                "supportedVersions": Self.modernVersions,
                "capabilities": capabilities,
                "_meta": [Self.serverInfoKey: ["name": name, "title": "MacHUD", "version": version]],
                "instructions": instructions,
            ])
        case "ping":
            reply([:])
        case "tools/list":
            let definitions = tools.definitions
            lock.lock(); lastToolList = JSONLine.string(definitions); lock.unlock()
            reply(["tools": definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                send(error: -32602, "tools/call needs a tool name", id: id); return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                reply(try tools.call(name, arguments: arguments).json)
            } catch {
                send(error: -32602, "\(error)", id: id)
            }
        case "subscriptions/listen":
            let filter = params["notifications"] as? [String: Any] ?? [:]
            guard filter["toolsListChanged"] as? Bool == true else {
                // Nothing else this server notifies about: the stream ends at once.
                reply(["_meta": [Self.subscriptionKey: id]]); return
            }
            lock.lock(); listeners[Self.key(id)] = id; lock.unlock()
        default:
            send(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    private var capabilities: [String: Any] { ["tools": ["listChanged": true]] }

    // MARK: - Tool list changes

    /// Called when the discovered apps may have changed: tells the client when the tool list
    /// it would now get differs from the last one it was sent.
    public func toolsMayHaveChanged() {
        let current = JSONLine.string(tools.definitions)
        lock.lock()
        let changed = lastToolList != nil && lastToolList != current
        if changed { lastToolList = current }
        let legacy = initializedLegacy
        let subscribers = Array(listeners.values)
        lock.unlock()
        guard changed else { return }
        if legacy { sendObject(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]) }
        for subscriber in subscribers {
            sendObject(["jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                        "params": ["_meta": [Self.subscriptionKey: subscriber]]])
        }
    }

    // MARK: - Output

    private static func key(_ id: Any) -> String { JSONLine.string(id) }

    private func send(result: [String: Any], id: Any) {
        sendObject(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, _ message: String, id: Any, data: [String: Any]? = nil) {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        sendObject(["jsonrpc": "2.0", "id": id, "error": error])
    }

    private func sendObject(_ object: [String: Any]) {
        write(JSONLine.string(object))
    }
}
