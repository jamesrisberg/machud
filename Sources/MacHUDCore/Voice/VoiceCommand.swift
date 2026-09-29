import Foundation

/// What `voice …` on MacHUD's socket asks for, turned into the voice host's own request
/// (the `machud-voice` contract). Pure, so it is unit tested.
enum VoiceCommand: Equatable {
    /// The supervisor's view: process status, pid, socket, helper.
    case status
    /// Sent to the host as is.
    case forward(String, [String: String])
    /// `settings set key=value …`: read the host's settings, change those keys, send the whole
    /// object back (the host's `settings set` replaces the full object).
    case mergeSettings([String: String])

    /// The actions `action name=` takes (the host's `VoiceHostAction`s).
    static let actions = ["click", "ask", "dictate", "stop", "cancel", "approve", "deny", "dismiss", "mute", "unmute",
                          "open-session", "say"]
    static let subVerbs = ["state", "status", "hello", "action", "settings", "brain", "models", "history", "secret"]

    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// `args` as MacHUD's socket delivers them; the CLI records the first bare word under `_`
    /// (`machud voice settings set enabled=false` → `_: settings, settings: 1, set: 1, enabled: false`).
    static func parse(_ args: [String: String]) throws -> VoiceCommand {
        let sub = args["_"].flatMap { subVerbs.contains($0) ? $0 : nil }
            ?? subVerbs.first { args[$0] != nil }
            ?? (args["_"] == nil ? "state" : args["_"]!)
        switch sub {
        case "state", "hello":
            return .forward(sub, [:])
        case "status":
            return .status
        case "action":
            return try action(args)
        case "settings":
            return try settings(args)
        case "brain":
            return try brain(args)
        case "models":
            return try models(args)
        case "history":
            return try history(args)
        case "secret":
            return try secret(args)
        default:
            throw Invalid("voice takes state, status, action, settings, brain, models, history or secret, not \(sub)")
        }
    }

    private static func action(_ args: [String: String]) throws -> VoiceCommand {
        let flagged = actions.first { args[$0] == "1" }
        let inline = args["action"].flatMap { $0 == "1" ? nil : $0 }
        guard let name = args["name"] ?? inline ?? flagged else {
            throw Invalid("voice action needs name= (\(actions.joined(separator: ", ")))")
        }
        guard actions.contains(name) else {
            throw Invalid("voice action \(name) is not one of \(actions.joined(separator: ", "))")
        }
        var out = ["name": name]
        if name == "approve" || name == "deny" {
            guard let id = args["id"], !id.isEmpty else { throw Invalid("voice action \(name) needs id=") }
            out["id"] = id
        }
        if name == "say" {
            guard let text = args["text"], !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Invalid("voice action say needs text=")
            }
            out["text"] = text
        }
        return .forward("action", out)
    }

    private static func settings(_ args: [String: String]) throws -> VoiceCommand {
        let op = args["action"].flatMap { ["get", "set"].contains($0) ? $0 : nil } ?? (args["set"] != nil ? "set" : "get")
        guard op == "set" else { return .forward("settings", ["action": "get"]) }
        if let json = args["settings"], json != "1" {
            guard let data = json.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw Invalid("voice settings set: settings= must be a JSON object")
            }
            return .forward("settings", ["action": "set", "settings": json])
        }
        var pairs = args
        for reserved in ["_", "settings", "set", "get", "action"] { pairs[reserved] = nil }
        guard !pairs.isEmpty else {
            throw Invalid("voice settings set needs settings={…} or key=value (dotted, e.g. voice.speakReplies=true)")
        }
        return .mergeSettings(pairs)
    }

    /// `brain status` (the only one): the host's `brain action=status`.
    private static func brain(_ args: [String: String]) throws -> VoiceCommand {
        let inline = args["action"].flatMap { $0 == "1" ? nil : $0 }
        let op = inline ?? (args["status"] != nil ? "status" : nil) ?? "status"
        guard op == "status" else { throw Invalid("voice brain takes status, not \(op)") }
        return .forward("brain", ["action": "status"])
    }

    /// `history status` (the only one): the host's `history action=status`.
    private static func history(_ args: [String: String]) throws -> VoiceCommand {
        let inline = args["action"].flatMap { $0 == "1" ? nil : $0 }
        let op = inline ?? (args["status"] != nil ? "status" : nil) ?? "status"
        guard op == "status" else { throw Invalid("voice history takes status, not \(op)") }
        return .forward("history", ["action": "status"])
    }

    /// `models status` and `models download id=kokoro|parakeet|<wake id>`: the host's downloadable models.
    private static func models(_ args: [String: String]) throws -> VoiceCommand {
        let inline = args["action"].flatMap { $0 == "1" ? nil : $0 }
        let op = inline ?? ["download", "status"].first { args[$0] != nil } ?? "status"
        switch op {
        case "status":
            return .forward("models", ["action": "status"])
        case "download":
            guard let id = args["id"], !id.isEmpty else { throw Invalid("voice models download needs id= (kokoro, parakeet, or a wake phrase such as hey-jarvis)") }
            return .forward("models", ["action": "download", "id": id])
        default:
            throw Invalid("voice models takes status or download, not \(op)")
        }
    }

    private static func secret(_ args: [String: String]) throws -> VoiceCommand {
        let op = args["action"].flatMap { ["set", "clear"].contains($0) ? $0 : nil } ?? (args["clear"] != nil ? "clear" : "set")
        guard let name = args["name"], !name.isEmpty else { throw Invalid("voice secret \(op) needs name= (grok)") }
        guard op == "set" else { return .forward("secret", ["action": "clear", "name": name]) }
        guard let value = args["value"], !value.isEmpty else { throw Invalid("voice secret set needs value=") }
        return .forward("secret", ["action": "set", "name": name, "value": value])
    }
}

/// The voice host's settings as the JSON object it stores. MacHUD edits it by dotted path and
/// always sends the whole object back, so keys it does not know about survive. Pure.
enum VoiceSettingsJSON {
    static func value(_ settings: [String: Any], at path: String) -> Any? {
        var current: Any? = settings
        for key in path.split(separator: ".") { current = (current as? [String: Any])?[String(key)] }
        return current
    }

    static func setting(_ settings: [String: Any], _ path: String, to value: Any) -> [String: Any] {
        let keys = path.split(separator: ".").map(String.init)
        return set(settings, keys[...], value)
    }

    private static func set(_ object: [String: Any], _ keys: ArraySlice<String>, _ value: Any) -> [String: Any] {
        guard let key = keys.first else { return object }
        var copy = object
        copy[key] = keys.count == 1 ? value : set(object[key] as? [String: Any] ?? [:], keys.dropFirst(), value)
        return copy
    }

    /// `settings` with `history` set to what `history status` says the default rule resolves to
    /// (`mode`, `shareWithSpeakFree`); unchanged when it already has one or the status failed.
    static func seedingHistory(_ settings: [String: Any], from status: [String: Any]) -> [String: Any] {
        guard settings["history"] == nil, status["ok"] as? Bool == true, let mode = status["mode"] as? String
        else { return settings }
        var out = settings
        out["history"] = ["mode": mode, "shareWithSpeakFree": status["shareWithSpeakFree"] as? Bool ?? false]
        return out
    }

    /// `pairs` applied to `base`, each value converted to the type already stored at its path.
    /// Throws for a path `base` does not have (a typo would otherwise be dropped by the host
    /// without a word) or a value that does not fit.
    static func merging(_ base: [String: Any], _ pairs: [String: String]) throws -> [String: Any] {
        var out = base
        for (path, raw) in pairs.sorted(by: { $0.key < $1.key }) {
            guard let current = value(base, at: path) else { throw VoiceCommand.Invalid("no such voice setting \(path)") }
            out = setting(out, path, to: try convert(raw, like: current, path: path))
        }
        return out
    }

    private static func convert(_ raw: String, like current: Any, path: String) throws -> Any {
        switch current {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            switch raw.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: throw VoiceCommand.Invalid("\(path) must be true or false")
            }
        case let number as NSNumber:
            if let i = Int(raw), CFNumberIsFloatType(number) == false { return i }
            guard let d = Double(raw), d.isFinite else { throw VoiceCommand.Invalid("\(path) must be a number") }
            return d
        case is String:
            return raw
        default:
            throw VoiceCommand.Invalid("\(path) is a group; set one of its keys (\(path).<key>=…)")
        }
    }
}
