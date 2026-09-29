import Foundation
import HUDKit
import VoiceKit

/// The `machud-voice` socket's verbs: `hello`, `state`, `settings get|set settings=<json>`,
/// `action name=<click|ask|dictate|stop|cancel|approve|deny|dismiss|mute|unmute|open-session> [id=]`,
/// `action name=say text=`, `brain status`, `models status|download id=kokoro`,
/// `secret set|clear name=grok [value=]` (values are written, never read back) and `quit`.
/// `subscribe` is `HUDSocketServer`'s own; `publish(_:on:)` feeds it `state` events and
/// `publishModels(_:on:)` its `models` events.
@MainActor
final class VoiceHostCommands {
    static let verbs = ["hello", "state", "settings", "action", "brain", "models", "secret", "quit"]
    /// Model ids `models download` takes.
    static let modelIDs = ["kokoro"]
    /// Secret names the socket accepts, and the `VoiceSecretStoring` key each is stored under.
    static let secretKeys = ["grok": VoiceSecrets.grokAPIKey]

    private let controller: VoiceHostController
    private let store: VoiceHostSettingsStore
    private let secrets: VoiceSecretStoring
    private let version: String
    /// The Kokoro reply voice's files; nil where the host cannot fetch models.
    private let models: VoiceModelProviding?
    /// After a `quit` has been answered.
    var onQuit: () -> Void = {}

    init(controller: VoiceHostController, store: VoiceHostSettingsStore, secrets: VoiceSecretStoring,
         version: String, models: VoiceModelProviding? = nil) {
        self.controller = controller
        self.store = store
        self.secrets = secrets
        self.version = version
        self.models = models
    }

    func install(on server: HUDSocketServer) {
        for verb in Self.verbs {
            server.register(verb) { [weak self] args, done in
                guard let self else { return done(["ok": false, "error": "voice host stopping"]) }
                if verb == "action", Self.actionName(args) == "open-session" {
                    // Answers once MacHUD has opened the session (or said why not).
                    Task { @MainActor in done(await self.openSession()) }
                    return
                }
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

    /// Pushes `{"event":"models","kokoro":{…}}` to subscribers.
    static func publishModels(_ status: VoiceModelStatus, on server: HUDSocketServer) {
        server.publish("models", payload: modelsPayload(status))
    }

    /// `{kokoro: {installed, downloading, progress, bytes, error?}}`.
    static func modelsPayload(_ kokoro: VoiceModelStatus) -> [String: Any] {
        var model: [String: Any] = ["installed": kokoro.installed, "downloading": kokoro.downloading,
                                    "progress": kokoro.progress, "bytes": kokoro.bytes]
        if let error = kokoro.error { model["error"] = error }
        return ["kokoro": model]
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
        case "brain":
            return brain(args)
        case "models":
            return modelsCommand(args)
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

    static func actionName(_ args: [String: String]) -> String? { args["name"] ?? args["_"] }

    private func action(_ args: [String: String]) -> [String: Any] {
        guard let name = Self.actionName(args) else {
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
        case "open-session": action = .openSession
        case "say":
            if let refusal = controller.say(args["text"] ?? "") { return ["ok": false, "error": refusal] }
            return ["ok": true, "state": Self.jsonObject(controller.state)]
        case "approve", "deny":
            guard let id = args["id"], !id.isEmpty else { return ["ok": false, "error": "\(name) needs id="] }
            action = name == "approve" ? .approve(id: id) : .deny(id: id)
        default:
            return ["ok": false, "error": "unknown action \(name)"]
        }
        controller.perform(action)
        return ["ok": true, "state": Self.jsonObject(controller.state)]
    }

    /// `action name=open-session`: `{ok, app}` once MacHUD shows the session, else `{ok: false, error}`.
    func openSession() async -> [String: Any] {
        switch await controller.openSessionNow() {
        case .success(let app): return ["ok": true, "app": app, "state": Self.jsonObject(controller.state)]
        case .failure(let error): return ["ok": false, "error": error.message]
        }
    }

    /// `brain status`: whether the brain can take a turn, why not, the workspace and the
    /// runtimes found on this Mac. Detection runs again each time, so an install shows up.
    private func brain(_ args: [String: String]) -> [String: Any] {
        let sub = args["action"] ?? args["_"] ?? "status"
        guard sub == "status" else { return ["ok": false, "error": "brain takes status, not \(sub)"] }
        controller.refreshRuntimeDetection()
        let state = controller.state
        let chosen = controller.settings.brain.workspacePath.trimmingCharacters(in: .whitespaces)
        var reply: [String: Any] = [
            "ok": true, "available": state.brainAvailable,
            "workspace": controller.resolvedBrain.workspacePath, "workspaceDefault": chosen.isEmpty,
            "runtime": controller.settings.brain.runtime.rawValue,
            "runtimes": controller.runtimeDetections().map(\.json),
        ]
        if let problem = state.brainProblem { reply["problem"] = problem }
        if let key = state.sessionKey { reply["sessionKey"] = key }
        return reply
    }

    /// `models status` and `models download id=kokoro`; both reply with the status.
    private func modelsCommand(_ args: [String: String]) -> [String: Any] {
        guard let models else { return ["ok": false, "error": "models are not available in this voice host"] }
        switch args["action"] ?? args["_"] ?? "status" {
        case "status":
            break
        case "download":
            guard let id = args["id"], Self.modelIDs.contains(id) else {
                return ["ok": false, "error": "models download needs id=, one of \(Self.modelIDs.joined(separator: ", "))"]
            }
            if !models.status.installed, !models.status.downloading { models.download() }
        case let other:
            return ["ok": false, "error": "models takes status or download, not \(other)"]
        }
        return ["ok": true].merging(Self.modelsPayload(models.status)) { $1 }
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
