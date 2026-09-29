import Foundation
import HUDKit

/// The result of one tool call, in MCP's `CallToolResult` shape.
public struct ToolResult {
    public var text: String
    public var structured: [String: Any]?
    public var isError: Bool

    public static func ok(_ object: [String: Any]) -> ToolResult {
        ToolResult(text: JSONLine.string(object), structured: object, isError: false)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(text: message, structured: nil, isError: true)
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if let structured { d["structuredContent"] = structured }
        return d
    }
}

/// A tool name the server does not have (a protocol error, not a tool error).
public struct UnknownTool: Error, CustomStringConvertible {
    public let name: String
    public var description: String { "Unknown tool: \(name)" }
}

/// MacHUD's tools for an agent: their definitions (regenerated from the discovered apps) and
/// what each call sends over MacHUD's control socket.
public final class MacHUDTools: @unchecked Sendable {
    let transport: MacHUDTransport
    private let lock = NSLock()
    private var knownApps: [DiscoveredApp]

    public init(transport: MacHUDTransport, apps: [DiscoveredApp] = []) {
        self.transport = transport
        knownApps = apps
    }

    public var apps: [DiscoveredApp] {
        get { lock.lock(); defer { lock.unlock() }; return knownApps }
        set { lock.lock(); knownApps = newValue; lock.unlock() }
    }

    /// Reads the discovered apps from MacHUD. Throws when MacHUD cannot be reached.
    @discardableResult
    public func refreshApps() throws -> [DiscoveredApp] {
        let reply = try transport.request("apps", [:])
        let parsed = DiscoveredApp.parse(appsReply: reply)
        apps = parsed
        return parsed
    }

    // MARK: - Definitions

    static let edges = ["left", "right", "top", "bottom"]

    /// Every tool, as `tools/list` returns them. The app enums and descriptions list the apps
    /// MacHUD has discovered, so the list changes when they do.
    public var definitions: [[String: Any]] {
        let apps = self.apps
        let appIDs = apps.map(\.id)
        func appProperty(_ what: String) -> [String: Any] {
            var p: [String: Any] = ["type": "string",
                                    "description": "\(what): the app's bundle id (a name also works)."]
            if !appIDs.isEmpty { p["enum"] = appIDs }
            return p
        }
        let panelProperty: [String: Any] = [
            "type": "string",
            "description": "The panel id within the app (list_app_actions shows them). Default: the app's first panel.",
        ]
        let appList = apps.isEmpty
            ? "No HUD apps are discovered right now (call machud_status)."
            : "Apps: " + apps.map { "\($0.name) (\($0.id))" }.joined(separator: ", ") + "."
        let actionList = apps.filter { !$0.actions.isEmpty }
            .map { "\($0.name) (\($0.id)): \($0.actions.joined(separator: ", "))" }
        let actionsText = actionList.isEmpty ? "No app declares actions right now." : "Declared actions: "
            + actionList.joined(separator: "; ") + "."

        return [
            tool("machud_status",
                 "Read the whole MacHUD desktop: displays and desktops, saved loadouts (which one applies at "
                 + "startup and which was applied last), the tool dock, every installed HUD app with its panels, "
                 + "action verbs and whether it runs, parked windows, and the voice host's state. Start here.",
                 properties: [:], readOnly: true),
            tool("list_loadouts",
                 "List saved loadouts (window arrangements plus HUD setup): name, layout, how many windows, "
                 + "whether it holds a HUD part, its hotkey, and which is the startup and the last applied one.",
                 properties: [:], readOnly: true),
            tool("apply_loadout",
                 "Apply a saved loadout: launch or find each app and move its windows into place, then its HUD "
                 + "part. Visible to the user. Use dry_run first for an unfamiliar loadout; the reply lists each "
                 + "slot's result.",
                 properties: [
                     "name": ["type": "string", "description": "The loadout's name (list_loadouts)."],
                     "clear": ["type": "boolean", "description": "First minimise the other windows on the screens it covers. Default false."],
                     "screen": ["type": "string", "description": "For a one-screen loadout: display name, main, builtin or index. Default: the display under the mouse."],
                     "dry_run": ["type": "boolean", "description": "Only return the placement plan; nothing moves. Default false."],
                 ], required: ["name"], destructive: false),
            tool("capture_loadout",
                 "Save the current arrangement as a loadout named `name` (replacing one of that name): the "
                 + "windows on one display (default: under the mouse) or on all displays, and optionally the HUD "
                 + "(tool dock position and running apps' panels).",
                 properties: [
                     "name": ["type": "string", "description": "The loadout's name."],
                     "all_screens": ["type": "boolean", "description": "Capture every display into one loadout. Default false."],
                     "screen": ["type": "string", "description": "The display to capture when not all_screens: display name, main, builtin or index."],
                     "hud": ["type": "string", "enum": ["none", "include", "only"],
                             "description": "none: windows only (default); include: windows and the HUD; only: just the HUD."],
                 ], required: ["name"], destructive: true),
            tool("show_panel",
                 "Show an app's panel where the user last had it (launching the app if needed). " + appList,
                 properties: ["app": appProperty("The app"), "panel": panelProperty], required: ["app"], idempotent: true),
            tool("hide_panel",
                 "Hide an app's panel, remembering where it was. An app that is not running is left alone. " + appList,
                 properties: ["app": appProperty("The app"), "panel": panelProperty], required: ["app"], idempotent: true),
            tool("toggle_panel",
                 "Show an app's panel if it is hidden, hide it if it shows. " + appList,
                 properties: ["app": appProperty("The app"), "panel": panelProperty], required: ["app"]),
            tool("list_app_actions",
                 "List an app's panels, capabilities and the action verbs its manifest declares (for app_action), "
                 + "and whether it runs. " + appList,
                 properties: ["app": appProperty("The app")], required: ["app"], readOnly: true),
            tool("app_action",
                 "Run one of an app's own action verbs (launching the app if needed). Arguments are verb-specific "
                 + "key/value pairs; the app's error names what a verb needs. " + actionsText,
                 properties: [
                     "app": appProperty("The app"),
                     "verb": ["type": "string", "description": "An action verb the app declares (list_app_actions)."],
                     // One `type` per schema: some clients (Codex) convert tool schemas into a
                     // subset of JSON Schema without type unions. Numbers and booleans still work.
                     "args": ["type": "object", "description": "The verb's arguments as key/value string pairs.",
                              "additionalProperties": ["type": "string"]],
                 ], required: ["app", "verb"]),
            tool("tool_dock",
                 "The MacHUD tool dock (a strip of the HUD apps' buttons): read its state, show or hide it, or move it.",
                 properties: [
                     "action": ["type": "string", "enum": ["state", "show", "hide", "position"],
                                "description": "state (default) reads it; position moves it."],
                     "position": ["type": "string", "enum": HUDDockPosition.allCases.map(\.rawValue),
                                  "description": "For position: bottom, top, left, right (a row or column) or a corner (an L)."],
                     "screen": ["type": "string", "description": "For position: the display name (empty: the main display)."],
                 ], idempotent: true),
            tool("park_window",
                 "Park a window at a screen edge behind an orb (hovering the orb brings it back). Name exactly one "
                 + "of region, window or app.",
                 properties: [
                     "region": ["type": "string", "description": "A region of the active layout (id, name or index): parks what sits in it."],
                     "window": ["type": "integer", "description": "A window number (MacHUD's `windows`)."],
                     "app": ["type": "string", "description": "An app's bundle id or name: parks its first window."],
                     "title": ["type": "string", "description": "With app: a regular expression the window title must match."],
                     "edge": ["type": "string", "enum": Self.edges, "description": "The edge to park at. Default: the nearest."],
                     "peek": ["type": "number", "description": "Points of the window left showing. Default 0."],
                 ]),
            tool("unpark",
                 "Put a parked window back for good (without id: every parked window). machud_status lists parked windows.",
                 properties: ["id": ["type": "string", "description": "The parked entry's id. Omit to unpark all."]]),
            tool("open_session",
                 "Show an agent session in the app that shows agent sessions (MechaHUD), launching it if needed.",
                 properties: ["id": ["type": "string", "description": "The session key, e.g. claude:<sessionId>."]],
                 required: ["id"]),
            tool("feed_add",
                 "Add text to the running apps that keep a text feed (Stash's history), without touching the clipboard.",
                 properties: [
                     "text": ["type": "string", "description": "The text."],
                     "source": ["type": "string", "description": "A short label for where it came from. Default Agent."],
                     "title": ["type": "string", "description": "An optional title."],
                 ], required: ["text"]),
            tool("say",
                 "Speak text aloud with the voice host's reply voice, replacing anything being said.",
                 properties: ["text": ["type": "string", "description": "What to say."]], required: ["text"]),
        ]
    }

    private func tool(_ name: String, _ description: String, properties: [String: Any], required: [String] = [],
                      readOnly: Bool = false, destructive: Bool? = nil, idempotent: Bool? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        var annotations: [String: Any] = ["readOnlyHint": readOnly, "openWorldHint": false]
        if !readOnly { annotations["destructiveHint"] = destructive ?? false }
        if let idempotent { annotations["idempotentHint"] = idempotent }
        if readOnly { annotations["idempotentHint"] = true }
        return ["name": name, "description": description, "inputSchema": schema, "annotations": annotations]
    }

    public var names: [String] { definitions.compactMap { $0["name"] as? String } }

    // MARK: - Calls

    /// Runs a tool. Throws `UnknownTool` for a name the server does not have; everything else
    /// (bad arguments, MacHUD unreachable, MacHUD's `ok: false`) is a tool error in the result.
    public func call(_ name: String, arguments: [String: Any]) throws -> ToolResult {
        let args = Arguments(arguments)
        do {
            switch name {
            case "machud_status": return try status()
            case "list_loadouts": return .ok(["loadouts": try loadouts()])
            case "apply_loadout": return try applyLoadout(args)
            case "capture_loadout": return try captureLoadout(args)
            case "show_panel": return try panel(args, show: true)
            case "hide_panel": return try panel(args, show: false)
            case "toggle_panel": return try panel(args, show: nil)
            case "list_app_actions": return try listActions(args)
            case "app_action": return try appAction(args)
            case "tool_dock": return try toolDock(args)
            case "park_window": return try park(args)
            case "unpark":
                var a: [String: String] = [:]
                if let id = try args.string("id") { a["id"] = id }
                return try machud("unpark", a)
            case "open_session": return try machud("sessions", ["action": "open", "id": try args.required("id")])
            case "feed_add":
                var a = ["action": "add", "text": try args.required("text"), "source": try args.string("source") ?? "Agent"]
                if let title = try args.string("title") { a["title"] = title }
                return try machud("feed", a)
            case "say": return try machud("voice", ["_": "action", "name": "say", "text": try args.required("text")])
            default: throw UnknownTool(name: name)
            }
        } catch let error as UnknownTool {
            throw error
        } catch let error as InvalidArgument {
            return .error(error.description)
        } catch let error as MacHUDUnreachable {
            return .error(error.description)
        } catch let error as MacHUDRefused {
            return .error(error.message)
        }
    }

    /// MacHUD answered `ok: false`.
    struct MacHUDRefused: Error { let message: String }

    /// Sends a command and returns the reply, throwing `MacHUDRefused` on `ok: false`.
    private func send(_ command: String, _ args: [String: String]) throws -> [String: Any] {
        let reply = try transport.request(command, args)
        if reply["ok"] as? Bool == false {
            throw MacHUDRefused(message: reply["error"] as? String ?? "MacHUD refused \(command)")
        }
        return reply
    }

    /// A command whose reply (without `ok`) is the tool's result.
    private func machud(_ command: String, _ args: [String: String]) throws -> ToolResult {
        var reply = try send(command, args)
        reply["ok"] = nil
        return .ok(reply)
    }

    private func loadouts() throws -> [[String: Any]] {
        let reply = try send("loadouts", [:])
        let startup = reply["startup"] as? String ?? ""
        let active = (try? send("status", [:]))?["activeLoadout"] as? String
        return (reply["loadouts"] as? [[String: Any]] ?? []).map { loadout in
            let name = loadout["name"] as? String ?? ""
            let slots = (loadout["slots"] as? [Any])?.count ?? 0
            let screens = loadout["screens"] as? [[String: Any]] ?? []
            var d: [String: Any] = [
                "name": name,
                "windows": slots + screens.reduce(0) { $0 + (($1["slots"] as? [Any])?.count ?? 0) },
                "hud": loadout["hud"] != nil && !(loadout["hud"] is NSNull),
                "startup": name == startup,
                "lastApplied": name == active,
            ]
            if let layout = loadout["layout"] as? String, !layout.isEmpty { d["layout"] = layout }
            if !screens.isEmpty { d["screens"] = screens.count }
            if let hotkey = loadout["hotkey"], !(hotkey is NSNull) { d["hotkey"] = hotkey }
            return d
        }
    }

    private func applyLoadout(_ args: Arguments) throws -> ToolResult {
        var a = ["loadout": try args.required("name")]
        if try args.bool("clear") == true { a["clear"] = "1" }
        if let screen = try args.string("screen") { a["screen"] = screen }
        if try args.bool("dry_run") == true { a["plan"] = "1" }
        return try machud("apply", a)
    }

    private func captureLoadout(_ args: Arguments) throws -> ToolResult {
        var a = ["name": try args.required("name")]
        if try args.bool("all_screens") == true { a["screens"] = "all" }
        else if let screen = try args.string("screen") { a["screen"] = screen }
        switch try args.string("hud") ?? "none" {
        case "none": break
        case "include": a["hud"] = "1"
        case "only": a["hud"] = "only"
        case let other: throw InvalidArgument("hud must be none, include or only, not \(other)")
        }
        return try machud("capture", a)
    }

    /// The app named by `app` (refreshing the list once when it is not known yet).
    private func app(_ args: Arguments) throws -> DiscoveredApp {
        let key = try args.required("app")
        if let app = apps.matching(key) { return app }
        if let app = try refreshApps().matching(key) { return app }
        let known = apps.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        throw InvalidArgument("No app \(key). " + (known.isEmpty ? "MacHUD has discovered no apps." : "Apps: \(known)."))
    }

    private func panelID(_ app: DiscoveredApp, _ args: Arguments) throws -> String {
        guard let first = app.panels.first else { throw InvalidArgument("\(app.name) has no panels") }
        guard let key = try args.string("panel") else { return "\(app.id)/\(first.id)" }
        let short = key.hasPrefix(app.id + "/") ? String(key.dropFirst(app.id.count + 1)) : key
        guard let panel = app.panels.first(where: { $0.id == short })
                ?? app.panels.first(where: { $0.title.caseInsensitiveCompare(short) == .orderedSame }) else {
            throw InvalidArgument("\(app.name) has no panel \(key); its panels: \(app.panels.map(\.id).joined(separator: ", "))")
        }
        return "\(app.id)/\(panel.id)"
    }

    /// `summon`/`dismiss` (the tool dock's own show and hide: remembered frames, hover panels
    /// placed by their button). `show == nil` toggles by the panel's current visibility.
    private func panel(_ args: Arguments, show: Bool?) throws -> ToolResult {
        let app = try app(args)
        let id = try panelID(app, args)
        var summon = show
        if summon == nil {
            let panels = try send("panels", [:])["panels"] as? [[String: Any]] ?? []
            let visible = panels.first { $0["id"] as? String == id }?["visible"] as? Bool ?? false
            summon = !visible
        }
        return try machud(summon! ? "summon" : "dismiss", ["id": id])
    }

    private func listActions(_ args: Arguments) throws -> ToolResult {
        let app = try app(args)
        return .ok(Self.describe(app))
    }

    static func describe(_ app: DiscoveredApp) -> [String: Any] {
        [
            "app": app.id, "name": app.name, "health": app.health, "running": app.running,
            "actions": app.actions,
            "panels": app.panels.map { panel -> [String: Any] in
                ["id": panel.id, "title": panel.title, "kind": panel.kind.rawValue,
                 "capabilities": panel.capabilities, "actions": DiscoveredApp.actions(of: panel)]
            },
        ]
    }

    /// Argument names MacHUD's `apps perform` keeps for itself, and `name` (the verb).
    static let reservedActionKeys: Set<String> = ["action", "_", "perform", "app", "verb", "name"]

    private func appAction(_ args: Arguments) throws -> ToolResult {
        let app = try app(args)
        let verb = try args.required("verb")
        guard app.actions.contains(verb) else {
            let declared = app.actions.isEmpty ? "it declares none" : "it declares \(app.actions.joined(separator: ", "))"
            throw InvalidArgument("\(app.name) has no action \(verb); \(declared)")
        }
        var a = ["action": "perform", "app": app.id, "verb": verb]
        for (key, value) in try args.object("args") {
            guard !Self.reservedActionKeys.contains(key) else {
                throw InvalidArgument("args may not use the key \(key) (MacHUD's own)")
            }
            a[key] = Arguments.stringify(value)
        }
        return try machud("apps", a)
    }

    private func toolDock(_ args: Arguments) throws -> ToolResult {
        let action = try args.string("action") ?? "state"
        switch action {
        case "state", "show", "hide":
            return try machud("tooldock", ["action": action])
        case "position":
            var a = ["action": "position"]
            if let position = try args.string("position") { a["position"] = position }
            if let screen = try args.string("screen") { a["screen"] = screen }
            guard a.count > 1 else { throw InvalidArgument("tool_dock position needs position or screen") }
            return try machud("tooldock", a)
        default:
            throw InvalidArgument("tool_dock action must be state, show, hide or position, not \(action)")
        }
    }

    private func park(_ args: Arguments) throws -> ToolResult {
        var a: [String: String] = [:]
        let region = try args.string("region"), window = try args.int("window"), app = try args.string("app")
        guard [region != nil, window != nil, app != nil].filter({ $0 }).count == 1 else {
            throw InvalidArgument("park_window needs exactly one of region, window or app")
        }
        if let region { a["id"] = region }
        if let window { a["window"] = String(window) }
        if let app {
            a["app"] = app
            if let title = try args.string("title") { a["title"] = title }
        }
        if let edge = try args.string("edge") {
            guard Self.edges.contains(edge) else { throw InvalidArgument("edge must be left, right, top or bottom") }
            a["edge"] = edge
        }
        if let peek = try args.number("peek") { a["peek"] = Arguments.stringify(peek) }
        return try machud("park", a)
    }

    // MARK: - Status

    /// Everything an agent needs to orient itself, from several read-only MacHUD commands. A
    /// part MacHUD cannot give is reported under `unavailable` rather than failing the whole.
    private func status() throws -> ToolResult {
        var out: [String: Any] = [:]
        var unavailable: [String: String] = [:]
        func part(_ key: String, _ body: () throws -> Any) {
            do { out[key] = try body() } catch let e as MacHUDRefused { unavailable[key] = e.message }
            catch { unavailable[key] = "\(error)" }
        }
        // The first call tells whether MacHUD is there at all.
        let appsReply = try transport.request("apps", [:])
        let apps = DiscoveredApp.parse(appsReply: appsReply)
        self.apps = apps
        let panelStates = ((try? send("panels", [:]))?["panels"] as? [[String: Any]] ?? [])
            .reduce(into: [String: Bool]()) { d, p in
                if let id = p["id"] as? String { d[id] = p["visible"] as? Bool ?? false }
            }
        out["apps"] = apps.map { app -> [String: Any] in
            var d = Self.describe(app)
            d["panels"] = app.panels.map { panel -> [String: Any] in
                ["id": panel.id, "title": panel.title, "kind": panel.kind.rawValue,
                 "visible": panelStates["\(app.id)/\(panel.id)"] ?? false,
                 "capabilities": panel.capabilities, "actions": DiscoveredApp.actions(of: panel)]
            }
            return d
        }
        part("screens") {
            (try send("screens", [:])["screens"] as? [[String: Any]] ?? []).map { s in
                s.filter { ["index", "name", "main", "builtin", "w", "h", "spaces", "currentSpace"].contains($0.key) }
            }
        }
        part("loadouts") { try loadouts() }
        part("toolDock") {
            try send("tooldock", ["action": "state"]).filter {
                ["enabled", "position", "visible", "autoHide", "screenName"].contains($0.key)
            }
        }
        part("parked") {
            let reply = try send("park", ["list": "1"])
            return reply["parked"] ?? []
        }
        part("voice") {
            var voice = try send("voice", ["_": "status"]).filter { ["status", "connected", "muted", "error"].contains($0.key) }
            if voice["status"] as? String == "running",
               let state = (try? send("voice", ["_": "state"]))?["state"] as? [String: Any] {
                for key in ["phase", "brainAvailable", "brainProblem", "sessionKey", "sessionProvider", "wakeListening"] {
                    if let value = state[key] { voice[key] = value }
                }
            }
            return voice
        }
        if !unavailable.isEmpty { out["unavailable"] = unavailable }
        return .ok(out)
    }
}

/// A tool argument was missing or had the wrong type.
struct InvalidArgument: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Typed reads of a tool call's `arguments`, lenient where a model is likely to be (a number
/// given as a string, a boolean as "true").
struct Arguments {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    private func present(_ key: String) -> Any? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let value = present(key) else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if value is NSNumber { return Self.stringify(value) }
        throw InvalidArgument("\(key) must be a string")
    }

    func required(_ key: String) throws -> String {
        guard let value = try string(key) else { throw InvalidArgument("\(key) is required") }
        return value
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = present(key) else { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: break
            }
        }
        throw InvalidArgument("\(key) must be true or false")
    }

    func number(_ key: String) throws -> Double? {
        guard let value = present(key) else { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        throw InvalidArgument("\(key) must be a number")
    }

    func int(_ key: String) throws -> Int? {
        guard let d = try number(key) else { return nil }
        guard d == d.rounded() else { throw InvalidArgument("\(key) must be a whole number") }
        return Int(d)
    }

    func object(_ key: String) throws -> [String: Any] {
        guard let value = present(key) else { return [:] }
        guard let d = value as? [String: Any] else { throw InvalidArgument("\(key) must be an object") }
        return d
    }

    /// A JSON value as MacHUD's `key=value` string: booleans as true/false, whole numbers
    /// without a decimal point, anything else as compact JSON.
    static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let d as Double:
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        default: return JSONLine.string(value)
        }
    }
}

/// One-line JSON, as MCP's stdio transport requires (no embedded newlines).
public enum JSONLine {
    public static func string(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}
