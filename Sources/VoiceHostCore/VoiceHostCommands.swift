import Foundation
import HUDKit
import VoiceKit

/// The `machud-voice` socket's verbs: `hello`, `state` (the state and the orb's `VoiceOrbReport`),
/// `settings get|set settings=<json>`,
/// `action name=<click|ask|dictate|stop|cancel|approve|deny|dismiss|mute|unmute|open-session> [id=]`,
/// `action name=say text=`, `brain status`, `models status|download id=kokoro|parakeet|<wake id>`,
/// `history status`, `secret set|clear name=grok [value=]` (values are written, never read
/// back), `conversation` (the conversation's rows), `send text=` (a typed turn to the agent),
/// `card peek|pin|expand|close`, `takes [limit=]` (the take journal's newest records) and `quit`.
/// `subscribe` is `HUDSocketServer`'s own; `publish(_:on:)` feeds it `state` events and
/// `publishModels(_:on:)` its `models` events.
@MainActor
final class VoiceHostCommands {
    static let verbs = ["hello", "state", "settings", "action", "brain", "models", "history", "secret",
                        "conversation", "send", "card", "takes", "quit"]
    /// How many records `takes` returns without `limit=`.
    static let takesDefaultLimit = 20
    /// `card`'s states and the card mode each sets (`close` also dismisses the card).
    static let cardModes: [String: VoiceCardMode] = ["peek": .peek, "pin": .pinned, "expand": .expanded, "close": .peek]
    /// Model ids `models` reports and `models download` takes, in order.
    static let modelIDs = ["kokoro", "parakeet"]
    /// Secret names the socket accepts, and the `VoiceSecretStoring` key each is stored under.
    static let secretKeys = ["grok": VoiceSecrets.grokAPIKey]

    private let controller: VoiceHostController
    private let store: VoiceHostSettingsStore
    private let secrets: VoiceSecretStoring
    private let version: String
    /// The downloadable models by id (`kokoro`, `parakeet`); empty where the host fetches none.
    private let models: [String: VoiceModelProviding]
    /// Where dictation history goes; nil where the host keeps none to report.
    private let history: DictationHistoryLocator?
    /// After a `quit` has been answered.
    var onQuit: () -> Void = {}

    init(controller: VoiceHostController, store: VoiceHostSettingsStore, secrets: VoiceSecretStoring,
         version: String, models: [String: VoiceModelProviding] = [:], history: DictationHistoryLocator? = nil) {
        self.controller = controller
        self.store = store
        self.secrets = secrets
        self.version = version
        self.models = models
        self.history = history
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

    /// Pushes `{"event":"models","kokoro":{…},"parakeet":{…},"wake":[…]}` to subscribers.
    static func publishModels(_ models: [String: VoiceModelProviding], wake: [WakePhraseModel],
                              on server: HUDSocketServer) {
        server.publish("models", payload: modelsPayload(models.mapValues(\.status), wake: wake))
    }

    /// `{<id>: {installed, downloading, progress, bytes, id?, error?}}` for each model, and
    /// `wake`: the wake phrases there are models for, each with its model's state and licence.
    static func modelsPayload(_ statuses: [String: VoiceModelStatus], wake: [WakePhraseModel] = []) -> [String: Any] {
        var payload: [String: Any] = statuses.mapValues { status in
            var model: [String: Any] = ["installed": status.installed, "downloading": status.downloading,
                                        "progress": status.progress, "bytes": status.bytes]
            if let id = status.id { model["id"] = id }
            if let error = status.error { model["error"] = error }
            return model
        }
        payload["wake"] = wake.map(\.json)
        return payload
    }

    func handle(_ command: String, _ args: [String: String]) -> [String: Any] {
        switch command {
        case "hello":
            return ["ok": true, "name": "MacHUDVoice", "version": version,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        case "state":
            return ["ok": true, "state": Self.jsonObject(controller.state), "orb": Self.jsonObject(orbReport())]
        case "settings":
            return settings(args)
        case "action":
            return action(args)
        case "brain":
            return brain(args)
        case "models":
            return modelsCommand(args)
        case "history":
            return historyCommand(args)
        case "secret":
            return secret(args)
        case "conversation":
            return ["ok": true, "threadId": controller.conversation.threadID ?? NSNull(),
                    "rows": Self.jsonObject(controller.conversation.rows)]
        case "send":
            if let refusal = controller.send(typed: args["text"] ?? "") {
                return ["ok": false, "error": args["text"] == nil ? "send needs text=" : refusal]
            }
            return ["ok": true, "state": Self.jsonObject(controller.state)]
        case "card":
            return card(args)
        case "takes":
            return takes(args)
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
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let decoded = try? JSONDecoder().decode(VoiceHostSettings.self, from: data)
            else { return ["ok": false, "error": "settings= must be a JSON object"] }
            if let invalid = VoiceHostSettings.invalidChoice(in: object) { return ["ok": false, "error": invalid] }
            // Turning the wake word on with a phrase no model detects saves one that has a model.
            let settings = controller.resolvingWakePhrase(decoded)
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

    /// `state`'s `orb`: whether the orb is meant to be shown, the window that hid it, and its
    /// window now (none from a headless host).
    private func orbReport() -> VoiceOrbReport {
        let hidden = controller.state.hiddenForFullScreen
        return VoiceOrbReport(intended: hidden ? .hiddenForFullScreen : .shown,
                              hiddenBy: hidden ? controller.fullScreenEvidence : nil,
                              window: controller.presenter?.orbWindowReport())
    }

    static func actionName(_ args: [String: String]) -> String? { args["name"] ?? args["_"] }

    private func action(_ args: [String: String]) -> [String: Any] {
        guard let name = Self.actionName(args) else {
            return ["ok": false, "error": "action needs name=<verb>"]
        }
        let action: VoiceHostAction
        switch name {
        case "click": action = .orbClicked
        case "ask", "dictate":
            let mode: VoiceMode = name == "ask" ? .agent : .dictation
            action = .start(mode)
            if let refusal = controller.socketRefusal(for: mode, action: name) { return ["ok": false, "error": refusal] }
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
        // A take this starts was started by the socket, named by its action.
        controller.perform(action, trigger: .socket(action: name))
        return ["ok": true, "state": Self.jsonObject(controller.state)]
    }

    /// `takes [limit=]`: `{ok, takes[]}`, the journal's newest `limit` records (default 20),
    /// oldest first.
    private func takes(_ args: [String: String]) -> [String: Any] {
        guard let journal = controller.takeJournal else {
            return ["ok": false, "error": "takes are not kept in this voice host"]
        }
        var limit = Self.takesDefaultLimit
        if let given = args["limit"] {
            guard let number = Int(given), number >= 1 else {
                return ["ok": false, "error": "takes limit= must be a whole number of at least 1"]
            }
            limit = number
        }
        return ["ok": true, "takes": Self.jsonObject(journal.recent(limit: limit))]
    }

    /// `card peek|pin|expand|close`: sets the card's mode; `close` dismisses the card as its close
    /// button does.
    private func card(_ args: [String: String]) -> [String: Any] {
        let name = args["action"] ?? args["_"] ?? ""
        guard let mode = Self.cardModes[name] else {
            return ["ok": false, "error": "card takes peek, pin, expand or close"]
        }
        controller.perform(name == "close" ? .dismissCard : .setCardMode(mode))
        return ["ok": true, "state": Self.jsonObject(controller.state)]
    }

    /// `action name=open-session`: `{ok, app}` once MacHUD shows the session, else `{ok: false, error}`.
    func openSession() async -> [String: Any] {
        switch await controller.openSessionNow() {
        case .success(let app): return ["ok": true, "app": app, "state": Self.jsonObject(controller.state)]
        case .failure(let error): return ["ok": false, "error": error.message]
        }
    }

    /// `brain status`: whether the brain can take a turn, why not, the workspace, the runtime
    /// chosen and the one the companion runs (`activeRuntime`, while connected), the runtimes
    /// BrainKit finds on this Mac (built-ins and runtime plugins) and MacHUD's tools. Detection
    /// runs again each time, so an install shows up.
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
            "runtimes": BrainRuntimes.status(controller.runtimeDetections(), brain: controller.resolvedBrain),
        ]
        if let problem = state.brainProblem { reply["problem"] = problem }
        if let key = state.sessionKey { reply["sessionKey"] = key }
        if let active = state.activeRuntime { reply["activeRuntime"] = active }
        var tools: [String: Any] = [
            "enabled": controller.settings.machudTools,
            "requireApproval": controller.settings.machudToolsRequireApproval,
            "available": controller.machudTools != nil,
        ]
        if let server = controller.machudTools { tools["path"] = server.command }
        if let running = controller.brainToolServers {
            tools["active"] = running.active && running.names.contains(MacHUDToolServer.name)
            if let note = running.note { tools["note"] = note }
        }
        reply["machudTools"] = tools
        return reply
    }

    /// `models status` and `models download id=<kokoro|parakeet|wake id>`; both reply with
    /// every model's status. A wake model is named by its id (`hey-jarvis`) or its manifest id.
    private func modelsCommand(_ args: [String: String]) -> [String: Any] {
        let wake = controller.wakeModels
        guard !models.isEmpty || !wake.isEmpty else {
            return ["ok": false, "error": "models are not available in this voice host"]
        }
        switch args["action"] ?? args["_"] ?? "status" {
        case "status":
            break
        case "download":
            let ids = Self.modelIDs.filter { models[$0] != nil } + wake.map(\.id)
            let id = args["id"] ?? ""
            guard let model = models[id] ?? wake.first(where: { $0.id == id || $0.manifestID == id })?.store else {
                return ["ok": false, "error": "models download needs id=, one of \(ids.joined(separator: ", "))"]
            }
            if !model.status.installed, !model.status.downloading { model.download() }
        case let other:
            return ["ok": false, "error": "models takes status or download, not \(other)"]
        }
        return ["ok": true].merging(Self.modelsPayload(models.mapValues(\.status), wake: wake)) { $1 }
    }

    /// `history status`: where finished dictations are kept, as the setting resolves on this
    /// Mac now (SpeakFree installed or not, its own choice while no setting is saved).
    private func historyCommand(_ args: [String: String]) -> [String: Any] {
        let sub = args["action"] ?? args["_"] ?? "status"
        guard sub == "status" else { return ["ok": false, "error": "history takes status, not \(sub)"] }
        guard let history else { return ["ok": false, "error": "history is not available in this voice host"] }
        return ["ok": true].merging(history.plan(for: controller.settings.history).json) { $1 }
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
