import Foundation
import HUDKit
import VoiceKit

/// The `machud-voice` socket's verbs: `hello`, `state`, `settings get|set settings=<json>`,
/// `action name=<click|ask|dictate|stop|cancel|approve|deny|dismiss|mute|unmute> [id=]`,
/// `secret set|clear name=grok [value=]` (values are written, never read back) and `quit`.
/// `subscribe` is `HUDSocketServer`'s own; `publish(_:on:)` feeds it `state` events.
@MainActor
final class VoiceHostCommands {
    static let verbs = ["hello", "state", "settings", "action", "secret", "quit"]
    /// Secret names the socket accepts, and the `VoiceSecretStoring` key each is stored under.
    static let secretKeys = ["grok": VoiceSecrets.grokAPIKey]

    private let controller: VoiceHostController
    private let store: VoiceHostSettingsStore
    private let secrets: VoiceSecretStoring
    private let version: String
    /// After a `quit` has been answered.
    var onQuit: () -> Void = {}

    init(controller: VoiceHostController, store: VoiceHostSettingsStore, secrets: VoiceSecretStoring,
         version: String) {
        self.controller = controller
        self.store = store
        self.secrets = secrets
        self.version = version
    }

    func install(on server: HUDSocketServer) {
        for verb in Self.verbs {
            server.register(verb) { [weak self] args, done in
                guard let self else { return done(["ok": false, "error": "voice host stopping"]) }
                done(handle(verb, args))
                if verb == "quit" {
                    // Let the reply reach the client first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.onQuit() }
                }
            }
        }
    }

    /// Pushes `{"event":"state","state":{…}}` to subscribers.
    static func publish(_ state: VoiceHostState, on server: HUDSocketServer) {
        server.publish("state", payload: ["state": jsonObject(state)])
    }

    func handle(_ command: String, _ args: [String: String]) -> [String: Any] {
        switch command {
        case "hello":
            return ["ok": true, "name": "MacHUDVoice", "version": version,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        case "state":
            return ["ok": true, "state": Self.jsonObject(controller.state)]
        case "settings":
            return settings(args)
        case "action":
            return action(args)
        case "secret":
            return secret(args)
        case "quit":
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown command \(command)"]
        }
    }

    private func settings(_ args: [String: String]) -> [String: Any] {
        switch args["action"] ?? args["_"] ?? "get" {
        case "get":
            return ["ok": true, "settings": Self.jsonObject(controller.settings)]
        case "set":
            guard let text = args["settings"], let data = text.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
                  let settings = try? JSONDecoder().decode(VoiceHostSettings.self, from: data)
            else { return ["ok": false, "error": "settings= must be a JSON object"] }
            do {
                try store.save(settings)
            } catch {
                return ["ok": false, "error": "could not save \(store.url.path): \(error.localizedDescription)"]
            }
            let stored = store.load()
            controller.apply(stored)
            return ["ok": true, "settings": Self.jsonObject(stored)]
        case let other:
            return ["ok": false, "error": "settings takes get or set, not \(other)"]
        }
    }

    private func action(_ args: [String: String]) -> [String: Any] {
        guard let name = args["name"] ?? args["_"] else {
            return ["ok": false, "error": "action needs name=<verb>"]
        }
        let action: VoiceHostAction
        switch name {
        case "click": action = .orbClicked
        case "ask": action = .start(.agent)
            if let refusal = controller.refusal(for: .agent) { return ["ok": false, "error": refusal] }
        case "dictate": action = .start(.dictation)
            if let refusal = controller.refusal(for: .dictation) { return ["ok": false, "error": refusal] }
        case "stop": action = .stop
        case "cancel": action = .cancel
        case "dismiss": action = .dismissCard
        case "mute": action = .setMuted(true)
        case "unmute": action = .setMuted(false)
        case "approve", "deny":
            guard let id = args["id"], !id.isEmpty else { return ["ok": false, "error": "\(name) needs id="] }
            action = name == "approve" ? .approve(id: id) : .deny(id: id)
        default:
            return ["ok": false, "error": "unknown action \(name)"]
        }
        controller.perform(action)
        return ["ok": true, "state": Self.jsonObject(controller.state)]
    }

    private func secret(_ args: [String: String]) -> [String: Any] {
        guard let name = args["name"], let key = Self.secretKeys[name] else {
            return ["ok": false, "error": "secret needs name=, one of \(Self.secretKeys.keys.sorted().joined(separator: ", "))"]
        }
        let value: String
        switch args["action"] ?? args["_"] {
        case "set":
            guard let given = args["value"] else { return ["ok": false, "error": "secret set needs value="] }
            value = given
        case "clear":
            value = ""
        default:
            return ["ok": false, "error": "secret takes set or clear"]
        }
        do {
            try secrets.set(value, forKey: key)
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
        // The reply voice reads the key when each reply starts, so the next one uses it.
        return ["ok": true]
    }

    /// A Codable value as the JSON object the socket writes.
    static func jsonObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }
}
