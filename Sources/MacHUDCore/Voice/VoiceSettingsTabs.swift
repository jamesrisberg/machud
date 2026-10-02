import AppKit
import SwiftUI

/// The Voice and Brain tabs of the settings window. Everything goes through the voice host's
/// socket (`settings get`, `settings set` with the whole object, `secret set|clear`,
/// `brain status`, `action say` for Test Voice, `models status|download` for the Parakeet
/// speech model, the Kokoro voice and the wake models, `history status`, and its `state` and
/// `models` events);
/// while the host is down the tabs say why and edit nothing.
@MainActor
final class VoiceSettingsModel: ObservableObject {
    static let voiceTabID = "voice"
    static let brainTabID = "brain"

    enum Status: Equatable {
        case loading, ready
        /// The host is not answering; the text says why.
        case unavailable(String)

        var text: String {
            switch self {
            case .loading: return "loading"
            case .ready: return "ready"
            case .unavailable(let why): return "unavailable: \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .loading
    /// The host's settings object as it reported it.
    @Published private(set) var settings: [String: Any] = [:]
    @Published var lastError: String?
    /// What happened to the last key saved or removed.
    @Published var secretNote: String?
    /// Why the brain cannot take a turn (the host's `brainProblem`); nil once it can.
    @Published private(set) var brainProblem: String?
    /// The runtimes the host found on this Mac (`brain status`), in its order.
    @Published private(set) var runtimes: [BrainRuntimeInfo] = []
    /// The folder the agent works in, as the host resolved it (`brain status`): the chosen one,
    /// else the home folder.
    @Published private(set) var workspace: String?
    /// No folder is chosen, so `workspace` is the home folder.
    @Published private(set) var workspaceIsDefault = false
    /// The runtime the brain companion runs (the host's `activeRuntime`); nil while none is connected.
    @Published private(set) var activeRuntime: String?
    /// `machud-mcp` ships beside the voice host (`brain status`'s `machudTools.available`).
    @Published private(set) var machudToolsAvailable = true
    /// The Kokoro voice's files (`models status` and `models` events); nil until known.
    @Published private(set) var kokoro: ModelStatus?
    /// The Parakeet speech model dictation needs (`models status` and `models` events); nil until known.
    @Published private(set) var parakeet: ModelStatus?
    /// Where finished dictations are kept (`history status`); nil until known.
    @Published private(set) var history: HistoryStatus?
    /// The wake phrases there are models for (`models status`'s `wake`), in the host's order.
    @Published private(set) var wakePhrases: [WakePhrase] = []
    /// Why the wake word is on and not listening (the host's `wakeProblem`); nil otherwise.
    @Published private(set) var wakeProblem: String?

    /// A wake phrase the host has a model for, and that model's state.
    struct WakePhrase: Equatable, Identifiable {
        /// What `models download id=` takes (`hey-jarvis`).
        var id: String
        var phrase: String
        /// The model's terms in a few words.
        var note: String
        var model: ModelStatus

        init?(_ json: Any?) {
            guard let json = json as? [String: Any], let id = json["id"] as? String,
                  let phrase = json["phrase"] as? String, let model = ModelStatus(json) else { return nil }
            self.id = id
            self.phrase = phrase
            note = json["note"] as? String ?? ""
            self.model = model
        }

        init(id: String, phrase: String, note: String, model: ModelStatus) {
            self.id = id
            self.phrase = phrase
            self.note = note
            self.model = model
        }

        /// Phrases compare as the host does: case, punctuation and spacing aside.
        func matches(_ other: String) -> Bool { Self.normalize(other) == Self.normalize(phrase) }

        static func normalize(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// The voice host's `history status`: the setting as it resolves on this Mac.
    struct HistoryStatus: Equatable {
        var mode: String
        var shareWithSpeakFree: Bool
        var speakFreeInstalled: Bool
        var folder: String
        /// No setting is saved; the default rule applies.
        var isDefault: Bool

        init?(_ reply: [String: Any]) {
            guard reply["ok"] as? Bool == true, let mode = reply["mode"] as? String else { return nil }
            self.mode = mode
            shareWithSpeakFree = reply["shareWithSpeakFree"] as? Bool ?? false
            speakFreeInstalled = reply["speakFreeInstalled"] as? Bool ?? false
            folder = reply["folder"] as? String ?? ""
            isDefault = reply["default"] as? Bool ?? false
        }

        init(mode: String, shareWithSpeakFree: Bool, speakFreeInstalled: Bool, folder: String, isDefault: Bool) {
            self.mode = mode
            self.shareWithSpeakFree = shareWithSpeakFree
            self.speakFreeInstalled = speakFreeInstalled
            self.folder = folder
            self.isDefault = isDefault
        }
    }

    /// The choices `history.mode` takes, in the order they are offered.
    static let historyModes = [("off", "Off"), ("text", "Text only"), ("textAndAudio", "Text and audio")]

    /// A downloadable model as the host reports it.
    struct ModelStatus: Equatable {
        var installed: Bool
        var downloading: Bool
        var progress: Double
        var bytes: Int64
        var error: String?

        init(installed: Bool, downloading: Bool, progress: Double, bytes: Int64, error: String?) {
            self.installed = installed
            self.downloading = downloading
            self.progress = progress
            self.bytes = bytes
            self.error = error
        }

        init?(_ json: Any?) {
            guard let json = json as? [String: Any] else { return nil }
            installed = json["installed"] as? Bool ?? false
            downloading = json["downloading"] as? Bool ?? false
            progress = min(max((json["progress"] as? NSNumber)?.doubleValue ?? 0, 0), 1)
            bytes = (json["bytes"] as? NSNumber)?.int64Value ?? 0
            error = json["error"] as? String
        }

        var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    /// What Test Voice says.
    static let voiceSample = "Hi, this is how my replies will sound."
    weak var services: VoiceServices?

    /// One runtime from `brain status`.
    struct BrainRuntimeInfo: Equatable {
        var id: String
        var name: String
        var installed: Bool
        var path: String?
    }

    /// Runtimes the picker always lists; mclaude joins them once it is found (or chosen).
    static let baseRuntimes = [("codex", "Codex"), ("claude", "Claude"), ("hermes", "Hermes")]

    var canEdit: Bool { status == .ready }
    /// Voice is switched off: the tabs offer to turn it on.
    var isOff: Bool { services?.supervisor.status == .disabled }

    func load(completion: (() -> Void)? = nil) {
        guard let services, services.supervisor.isRunning else {
            status = .unavailable(services?.supervisor.status.text ?? "The voice host is not available.")
            completion?()
            return
        }
        if status != .ready { status = .loading }
        services.perform(.forward("settings", ["action": "get"])) { [weak self] reply in
            guard let self else { return }
            if reply["ok"] as? Bool == true, let settings = reply["settings"] as? [String: Any] {
                self.settings = settings
                self.status = .ready
                self.hostStateChanged(services.connection.state)
                self.loadBrainStatus()
                self.loadModels()
                self.loadHistory()
            } else {
                self.status = .unavailable(services.connection.isConnected
                    ? reply["error"] as? String ?? "settings get failed" : "The voice host is starting.")
            }
            completion?()
        }
    }

    /// The host came up or went away, or the supervisor's status changed. Until the host is
    /// connected the status follows the supervisor, so a host that has started but not yet
    /// answered reads as starting, never as the stopped it was before.
    func hostAvailabilityChanged() {
        guard let services else { return }
        if services.connection.isConnected {
            load()
        } else {
            status = .unavailable(services.supervisor.isRunning ? "The voice host is starting." : services.supervisor.status.text)
            brainProblem = nil
        }
    }

    /// A `state` from the host: keeps the brain's problem current. Called for every state event,
    /// so it publishes only a change.
    func hostStateChanged(_ state: [String: Any]?) {
        let wakeProblem = state?["wakeProblem"] as? String
        if wakeProblem != self.wakeProblem { self.wakeProblem = wakeProblem }
        let activeRuntime = state?["activeRuntime"] as? String
        if activeRuntime != self.activeRuntime { self.activeRuntime = activeRuntime }
        let problem = state?["brainProblem"] as? String
        guard problem != brainProblem else { return }
        brainProblem = problem
        // The runtime found, or the workspace, may be what changed.
        if status == .ready { loadBrainStatus() }
    }

    /// `brain status`: which runtimes are installed.
    func loadBrainStatus(completion: (() -> Void)? = nil) {
        guard let services else { completion?(); return }
        services.perform(.forward("brain", ["action": "status"])) { [weak self] reply in
            defer { completion?() }
            guard let self, reply["ok"] as? Bool == true, let list = reply["runtimes"] as? [[String: Any]] else { return }
            let runtimes = list.compactMap { entry -> BrainRuntimeInfo? in
                guard let id = entry["id"] as? String else { return nil }
                return BrainRuntimeInfo(id: id, name: entry["name"] as? String ?? id,
                                        installed: entry["installed"] as? Bool ?? false, path: entry["path"] as? String)
            }
            if runtimes != self.runtimes { self.runtimes = runtimes }
            let workspace = reply["workspace"] as? String
            if workspace != self.workspace { self.workspace = workspace }
            let isDefault = reply["workspaceDefault"] as? Bool ?? false
            if isDefault != self.workspaceIsDefault { self.workspaceIsDefault = isDefault }
            let toolsAvailable = (reply["machudTools"] as? [String: Any])?["available"] as? Bool ?? true
            if toolsAvailable != self.machudToolsAvailable { self.machudToolsAvailable = toolsAvailable }
        }
    }

    /// `history status`: where finished dictations are kept.
    func loadHistory(completion: (() -> Void)? = nil) {
        guard let services else { completion?(); return }
        services.perform(.forward("history", ["action": "status"])) { [weak self] reply in
            defer { completion?() }
            guard let self, let history = HistoryStatus(reply), history != self.history else { return }
            self.history = history
        }
    }

    /// Saves the history setting whole (the host keeps no half of it): `mode` and sharing, each
    /// defaulting to what is in effect now.
    func setHistory(mode: String? = nil, shareWithSpeakFree: Bool? = nil) {
        let current = history
        let value: [String: Any] = [
            "mode": mode ?? current?.mode ?? "off",
            "shareWithSpeakFree": shareWithSpeakFree ?? current?.shareWithSpeakFree ?? false,
        ]
        set("history", value) { [weak self] in self?.loadHistory() }
    }

    /// `models status`: whether the speech model and Kokoro are installed or downloading.
    func loadModels(completion: (() -> Void)? = nil) {
        guard let services else { completion?(); return }
        services.perform(.forward("models", ["action": "status"])) { [weak self] reply in
            defer { completion?() }
            guard reply["ok"] as? Bool == true else { return }
            self?.modelsChanged(reply)
        }
    }

    /// A `models status` reply or `models` event.
    func modelsChanged(_ reply: [String: Any]) {
        if let kokoro = ModelStatus(reply["kokoro"]), kokoro != self.kokoro { self.kokoro = kokoro }
        if let parakeet = ModelStatus(reply["parakeet"]), parakeet != self.parakeet { self.parakeet = parakeet }
        if let list = reply["wake"] as? [Any] {
            let phrases = list.compactMap(WakePhrase.init)
            if phrases != wakePhrases { wakePhrases = phrases }
        }
    }

    /// The phrase the wake word listens for: the saved one when a model detects it, else the
    /// first there is a model for (what the host switches to when the wake word is turned on).
    var wakePhrase: WakePhrase? {
        let saved = string("voice.wakePhrase")
        return wakePhrases.first { $0.matches(saved) } ?? wakePhrases.first
    }

    func setWakePhrase(_ phrase: String) { set("voice.wakePhrase", phrase) }

    /// Downloads a wake phrase's model (`models download id=`); progress arrives as `models` events.
    func downloadWakeModel(_ id: String) { download(id) }

    /// Downloads the Kokoro voice; progress arrives as `models` events.
    func downloadKokoro() { download("kokoro") }

    /// Downloads the Parakeet speech model dictation needs; progress arrives as `models` events.
    func downloadParakeet() { download("parakeet") }

    private func download(_ id: String) {
        services?.perform(.forward("models", ["action": "download", "id": id])) { [weak self] reply in
            guard let self else { return }
            if reply["ok"] as? Bool == true { self.modelsChanged(reply) } else { self.lastError = reply["error"] as? String ?? "download failed" }
        }
    }

    /// Says a sample with the reply voice as chosen now, whether or not replies are spoken.
    func testVoice() {
        services?.perform(.forward("action", ["name": "say", "text": Self.voiceSample])) { [weak self] reply in
            guard let self else { return }
            self.lastError = reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "could not speak"
        }
    }

    /// While the companion still runs another runtime than the one chosen: which, in words.
    var runtimeSwitchNote: String? {
        let chosen = string("brain.runtime")
        guard let active = activeRuntime, !chosen.isEmpty, active != chosen else { return nil }
        let name = { (id: String) in Self.baseRuntimes.first { $0.0 == id }?.1 ?? id }
        return "The brain is still running \(name(active)); it switches to \(name(chosen)) when it is between turns."
    }

    /// The runtime picker's choices: Codex, Claude and Hermes, plus mclaude when it is installed
    /// or already chosen; a runtime the host did not find says so.
    var runtimeOptions: [(value: String, title: String)] {
        let chosen = string("brain.runtime")
        var options = Self.baseRuntimes
        if runtimes.contains(where: { $0.id == "mclaude" && $0.installed }) || chosen == "mclaude" {
            options.append(("mclaude", "mclaude"))
        }
        return options.map { id, name in
            let found = runtimes.first { $0.id == id }
            return (id, found?.installed == false ? "\(name) (not installed)" : name)
        }
    }

    /// The wake threshold for a sensitivity (its inverse), to two places.
    static func threshold(sensitivity: Double) -> Double { ((1 - sensitivity) * 100).rounded() / 100 }

    func value(_ path: String) -> Any? { VoiceSettingsJSON.value(settings, at: path) }
    func bool(_ path: String) -> Bool { value(path) as? Bool ?? false }
    func string(_ path: String) -> String { value(path).map { "\($0)" } ?? "" }
    func double(_ path: String) -> Double { (value(path) as? NSNumber)?.doubleValue ?? 0 }

    /// Changes one value and sends the whole object.
    func set(_ path: String, _ value: Any, then: (() -> Void)? = nil) {
        guard canEdit, let services else { return }
        let updated = VoiceSettingsJSON.setting(settings, path, to: value)
        services.sendSettings(updated) { [weak self] reply in
            guard let self else { return }
            if reply["ok"] as? Bool == true {
                self.lastError = nil
                if let stored = reply["settings"] as? [String: Any] { self.settings = stored }
            } else {
                self.lastError = reply["error"] as? String ?? "settings set failed"
            }
            then?()
        }
    }

    func saveSecret(_ name: String, value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let services else { return }
        services.perform(.forward("secret", ["action": "set", "name": name, "value": key])) { [weak self] reply in
            self?.secretNote = reply["ok"] as? Bool == true ? "Key saved to the Keychain." : reply["error"] as? String ?? "could not save"
        }
    }

    func clearSecret(_ name: String) {
        services?.perform(.forward("secret", ["action": "clear", "name": name])) { [weak self] reply in
            self?.secretNote = reply["ok"] as? Bool == true ? "Key removed." : reply["error"] as? String ?? "could not remove"
        }
    }

    /// The tabs' Retry: restarts a stopped or failed host, then loads.
    func retry(completion: (() -> Void)? = nil) {
        if let services, services.supervisor.canRestart { services.supervisor.start() }
        load(completion: completion)
    }

    func turnOn() {
        status = .loading
        services?.turnOn { [weak self] error in
            if let error { self?.lastError = error }
            self?.load()
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["status": status.text]
        if canEdit { d["settings"] = settings }
        if let brainProblem { d["brainProblem"] = brainProblem }
        if let workspace { d["workspace"] = workspace }
        if let kokoro { d["kokoro"] = ["installed": kokoro.installed, "downloading": kokoro.downloading] }
        if let parakeet { d["parakeet"] = ["installed": parakeet.installed, "downloading": parakeet.downloading] }
        d["wake"] = wakePhrases.map { ["id": $0.id, "phrase": $0.phrase, "installed": $0.model.installed,
                                       "downloading": $0.model.downloading] }
        if let wakeProblem { d["wakeProblem"] = wakeProblem }
        if let history { d["history"] = ["mode": history.mode, "shareWithSpeakFree": history.shareWithSpeakFree] }
        if let lastError { d["lastError"] = lastError }
        return d
    }
}

// MARK: - Views

struct VoiceTabView: View {
    @ObservedObject var model: VoiceSettingsModel
    @State private var grokKey = ""

    var body: some View {
        VoiceTabFrame(model: model) {
            Section("Voice") {
                VoiceToggle(model: model, title: "Voice on", path: "enabled",
                            help: "The fn key gestures, the orb and the wake word. Off stops the voice host.")
                VoicePicker(model: model, title: "fn key", path: "keyMode",
                            options: [("hold", "Hold to dictate"), ("toggle", "Tap to dictate")])
                VoiceToggle(model: model, title: "Talk to the agent with fn", path: "agentGesture",
                            help: "Hold mode: tap then hold. Tap mode: double-tap.")
                ParakeetRow(model: model)
            }
            Section("Dictation history") {
                DictationHistoryRows(model: model)
            }
            Section("Text feed") {
                VoiceToggle(model: model, title: "Send dictations to the text feed", path: "feedTranscripts",
                            help: "Each dictation's text joins the history of apps that keep a text feed, such as Stash.")
                VoiceToggle(model: model, title: "Send agent replies too", path: "feedAgentReplies")
            }
            Section("Hands-free") {
                HandsFreeRows(model: model)
            }
            Section("Wake word") {
                VoiceToggle(model: model, title: "Listen for the wake word", path: "voice.wakeWordEnabled",
                            help: "Keeps the microphone open while on.")
                if model.bool("voice.wakeWordEnabled"), let problem = model.wakeProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                WakePhraseRows(model: model)
                // The host stores a detection threshold (higher wakes less often); the slider shows
                // its inverse, so moving right wakes more easily.
                LabeledContent("Sensitivity") {
                    VoiceSlider(value: 1 - model.double("voice.wakeThreshold"), range: 0.05...0.95) {
                        model.set("voice.wakeThreshold", VoiceSettingsModel.threshold(sensitivity: $0))
                    }
                }
            }
            Section("Replies") {
                VoicePicker(model: model, title: "Reply voice", path: "voice.replyVoice",
                            options: [("kokoro", "Kokoro (on this Mac)"), ("system", "System voice"), ("grok", "Grok")])
                VoiceToggle(model: model, title: "Speak replies", path: "voice.speakReplies",
                            help: "Off shows replies as text only.")
                VoiceToggle(model: model, title: "Speak replies to typed messages", path: "speakTypedReplies",
                            help: "Messages typed in the conversation get spoken replies too.")
                LabeledContent("Try it") {
                    Button("Test Voice") { model.testVoice() }
                }
                KokoroRow(model: model)
                LabeledContent("Grok API key") {
                    HStack {
                        SecureField("Grok API key", text: $grokKey, prompt: Text("xai-…")).labelsHidden()
                        Button("Save") { model.saveSecret("grok", value: grokKey); grokKey = "" }
                            .disabled(grokKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") { model.clearSecret("grok") }
                    }
                }
                Text(model.secretNote ?? "Stored in the Keychain; it is never shown again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BrainTabView: View {
    @ObservedObject var model: VoiceSettingsModel

    var body: some View {
        VoiceTabFrame(model: model) {
            Section("Brain") {
                BrainProblemRow(problem: model.brainProblem)
                VoiceToggle(model: model, title: "Brain on", path: "brainEnabled",
                            help: "Off leaves dictation only.")
                VoicePicker(model: model, title: "Runtime", path: "brain.runtime", options: model.runtimeOptions)
                if let note = model.runtimeSwitchNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                if model.runtimeOptions.contains(where: { $0.value == "mclaude" }) {
                    Text("mclaude runs a Claude Code session that also appears in MechaHUD, so you can pick up the same conversation there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VoiceText(model: model, title: "Workspace", path: "brain.workspacePath", isPath: true, foldersOnly: true,
                          prompt: "Home folder")
                Text(model.workspaceIsDefault
                     ? "The agent works in your home folder\(model.workspace.map { " (\($0))" } ?? "") until you choose another."
                     : "The folder the agent works in. Clear it to use your home folder.")
                    .font(.caption).foregroundStyle(.secondary)
                VoiceText(model: model, title: "Assistant name", path: "brain.assistantName")
                VoiceText(model: model, title: "Port", path: "brainPort", isNumber: true)
            }
            Section("MacHUD tools") {
                VoiceToggle(model: model, title: "Let the brain use MacHUD", path: "brain.machudTools",
                            help: model.machudToolsAvailable
                                ? "The agent can apply loadouts, show panels, run app actions and more, and is told which apps and loadouts you have."
                                : "The MacHUD tool server is missing from this build, so the agent gets no MacHUD tools.")
                VoiceToggle(model: model, title: "Ask before each MacHUD action", path: "brain.machudToolsRequireApproval",
                            help: "Off, MacHUD actions run without asking. The agent's other actions ask as they always do.")
                    .disabled(!model.bool("brain.machudTools"))
            }
            Section("Runtimes") {
                VoiceText(model: model, title: "node", path: "brain.nodePath", isPath: true)
                VoiceText(model: model, title: "codex", path: "brain.codex.executablePath", isPath: true)
                VoiceText(model: model, title: "claude", path: "brain.claude.executablePath", isPath: true)
                VoiceText(model: model, title: "Hermes URL", path: "brain.hermes.url")
                Text("Empty paths are looked up on PATH and the usual install folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The wake phrase picker, offering only phrases there is a model for, and the chosen
/// phrase's model: installed, downloading with progress, or Download, with its terms.
struct WakePhraseRows: View {
    @ObservedObject var model: VoiceSettingsModel

    var body: some View {
        if let chosen = model.wakePhrase {
            Picker("Phrase", selection: Binding(get: { chosen.id }, set: { id in
                if let phrase = model.wakePhrases.first(where: { $0.id == id }) { model.setWakePhrase(phrase.phrase) }
            })) {
                ForEach(model.wakePhrases) { phrase in
                    Text("\(phrase.phrase)\(phrase.model.installed ? "" : " (not installed)")").tag(phrase.id)
                }
            }
            LabeledContent("\(chosen.phrase) model") {
                if chosen.model.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if chosen.model.downloading {
                    ProgressView(value: chosen.model.progress) { Text("Downloading \(Int(chosen.model.progress * 100))%") }
                        .frame(maxWidth: 200)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Button("Download (\(chosen.model.size))") { model.downloadWakeModel(chosen.id) }
                        if let error = chosen.model.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Text(chosen.note).font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("Phrase") { Text("Unknown").foregroundStyle(.secondary) }
        }
    }
}

/// The Kokoro voice: installed, downloading with progress, or a Download button with its size.
struct KokoroRow: View {
    @ObservedObject var model: VoiceSettingsModel

    var body: some View {
        LabeledContent("Kokoro voice") {
            if let kokoro = model.kokoro {
                if kokoro.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if kokoro.downloading {
                    ProgressView(value: kokoro.progress) { Text("Downloading \(Int(kokoro.progress * 100))%") }
                        .frame(maxWidth: 200)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Button("Download (\(kokoro.size))") { model.downloadKokoro() }
                        if let error = kokoro.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            } else {
                Text("Unknown").foregroundStyle(.secondary)
            }
        }
        Text("Kokoro speaks on this Mac. Until it is downloaded, replies use the system voice.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The Parakeet speech model dictation transcribes with: installed, downloading with
/// progress, or a Download button. SpeakFree uses the same model, so either app's download serves both.
struct ParakeetRow: View {
    @ObservedObject var model: VoiceSettingsModel

    var body: some View {
        LabeledContent("Speech model") {
            if let parakeet = model.parakeet {
                if parakeet.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if parakeet.downloading {
                    ProgressView(value: parakeet.progress) { Text("Downloading \(Int(parakeet.progress * 100))%") }
                        .frame(maxWidth: 200)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Button("Download (\(parakeet.size))") { model.downloadParakeet() }
                        if let error = parakeet.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            } else {
                Text("Unknown").foregroundStyle(.secondary)
            }
        }
        Text("Parakeet turns speech into text on this Mac; dictation needs it. SpeakFree shares the same download.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// When a take started by the orb, the wake word or `ask` is sent (`handsFree`): after a pause,
/// or only on a tap. Pause and sensitivity apply to the automatic end only.
struct HandsFreeRows: View {
    @ObservedObject var model: VoiceSettingsModel

    private var manual: Bool { model.string("handsFree.endOfTurn") == "manual" }

    var body: some View {
        VoicePicker(model: model, title: "End of turn", path: "handsFree.endOfTurn",
                    options: [("auto", "Automatically"), ("manual", "When I tap")])
        LabeledContent("Pause before sending") {
            Stepper(value: Binding(get: { model.double("handsFree.pause") }, set: { model.set("handsFree.pause", $0) }),
                    in: 1...4, step: 0.5) {
                Text(String(format: "%.1f s", model.double("handsFree.pause"))).monospacedDigit()
            }
        }
        .disabled(manual)
        VoicePicker(model: model, title: "Microphone sensitivity", path: "handsFree.sensitivity",
                    options: [("low", "Low"), ("medium", "Medium"), ("high", "High")])
            .disabled(manual)
        Text(manual
             ? "Tap the orb or fn to send. Takes still stop after two minutes."
             : "Sends once you stop talking, waiting a little longer when a sentence sounds unfinished. Higher sensitivity hears softer speech; lower ignores more background noise.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Keep dictation history (off, text only, text and audio), sharing it with SpeakFree when that
/// is installed, and where it is kept.
struct DictationHistoryRows: View {
    @ObservedObject var model: VoiceSettingsModel

    var body: some View {
        Picker("Keep dictation history", selection: Binding(
            get: { model.history?.mode ?? "off" }, set: { model.setHistory(mode: $0) })) {
            ForEach(VoiceSettingsModel.historyModes, id: \.0) { Text($0.1).tag($0.0) }
        }
        if model.history?.speakFreeInstalled == true {
            Toggle("Share history with SpeakFree", isOn: Binding(
                get: { model.history?.shareWithSpeakFree ?? false }, set: { model.setHistory(shareWithSpeakFree: $0) }))
        }
        Text(historyNote).font(.caption).foregroundStyle(.secondary)
    }

    private var historyNote: String {
        guard let history = model.history else { return "Where dictations are kept shows here once voice is on." }
        let folder = (history.folder as NSString).abbreviatingWithTildeInPath
        var note = history.mode == "off" ? "Nothing is kept." : "Kept in \(folder)."
        if history.shareWithSpeakFree { note += " One history with SpeakFree, in its format." }
        if history.isDefault, history.speakFreeInstalled { note += " Following SpeakFree's own setting until you choose." }
        return note
    }
}

/// Whether the brain can take a turn, and why not.
struct BrainProblemRow: View {
    let problem: String?

    var body: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Brain: \(problem)")
        } else {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Brain ready")
        }
    }
}

/// The status line and the form, disabled while the host is down.
struct VoiceTabFrame<Content: View>: View {
    @ObservedObject var model: VoiceSettingsModel
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch model.status {
                case .unavailable(let why):
                    Text(why).foregroundStyle(.secondary).lineLimit(2)
                    if model.isOff { Button("Turn On Voice") { model.turnOn() } }
                    else { Button("Retry") { model.retry() } }
                case .loading:
                    ProgressView().controlSize(.small)
                case .ready:
                    EmptyView()
                }
                Spacer()
                if let error = model.lastError { Text(error).foregroundStyle(.red).lineLimit(2) }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .disabled(!model.canEdit)
        }
    }
}

struct VoiceToggle: View {
    @ObservedObject var model: VoiceSettingsModel
    let title: String
    let path: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: Binding(get: { model.bool(path) }, set: { model.set(path, $0) }))
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct VoicePicker: View {
    @ObservedObject var model: VoiceSettingsModel
    let title: String
    let path: String
    let options: [(value: String, title: String)]

    var body: some View {
        Picker(title, selection: Binding(get: { model.string(path) }, set: { model.set(path, $0) })) {
            ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
        }
    }
}

/// A text (or path, or whole number) field that sends on Return.
struct VoiceText: View {
    @ObservedObject var model: VoiceSettingsModel
    let title: String
    let path: String
    var isPath = false
    var isNumber = false
    /// The Choose… panel picks folders only.
    var foldersOnly = false
    var prompt: String?
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $draft, prompt: prompt.map { Text($0) }).labelsHidden().onSubmit { commit(draft) }
                if isPath { Button("Choose…") { choose() } }
            }
        }
        .onAppear { draft = model.string(path) }
        .onChange(of: model.string(path)) { _, new in draft = new }
    }

    private func commit(_ text: String) {
        if isNumber {
            guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { draft = model.string(path); return }
            model.set(path, n)
        } else {
            model.set(path, text)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = !foldersOnly
        panel.canCreateDirectories = foldersOnly
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = url.path
        commit(url.path)
    }
}

/// A slider that sends when the drag ends, not on every step.
struct VoiceSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range) { editing in
            guard !editing, let draft else { return }
            commit(draft)
            self.draft = nil
        }
    }
}
