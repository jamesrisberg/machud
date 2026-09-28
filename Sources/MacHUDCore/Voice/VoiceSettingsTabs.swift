import AppKit
import SwiftUI

/// The Voice and Brain tabs of the settings window. Everything goes through the voice host's
/// socket (`settings get`, `settings set` with the whole object, `secret set|clear`); while the
/// host is down the tabs say why and edit nothing.
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
    weak var services: VoiceServices?

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
            } else {
                self.status = .unavailable(services.connection.isConnected
                    ? reply["error"] as? String ?? "settings get failed" : "The voice host is starting.")
            }
            completion?()
        }
    }

    /// The host came up or went away.
    func hostAvailabilityChanged() {
        guard let services else { return }
        if services.connection.isConnected {
            load()
        } else if status == .ready || !services.supervisor.isRunning {
            status = .unavailable(services.supervisor.isRunning ? "The voice host is starting." : services.supervisor.status.text)
        }
    }

    /// The wake threshold for a sensitivity (its inverse), to two places.
    static func threshold(sensitivity: Double) -> Double { ((1 - sensitivity) * 100).rounded() / 100 }

    func value(_ path: String) -> Any? { VoiceSettingsJSON.value(settings, at: path) }
    func bool(_ path: String) -> Bool { value(path) as? Bool ?? false }
    func string(_ path: String) -> String { value(path).map { "\($0)" } ?? "" }
    func double(_ path: String) -> Double { (value(path) as? NSNumber)?.doubleValue ?? 0 }

    /// Changes one value and sends the whole object.
    func set(_ path: String, _ value: Any) {
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
            }
            Section("Wake word") {
                VoiceToggle(model: model, title: "Listen for the wake word", path: "voice.wakeWordEnabled",
                            help: "Keeps the microphone open while on.")
                VoiceText(model: model, title: "Phrase", path: "voice.wakePhrase")
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
                VoiceToggle(model: model, title: "Brain on", path: "brainEnabled",
                            help: "Off leaves dictation only.")
                VoicePicker(model: model, title: "Runtime", path: "brain.runtime",
                            options: [("codex", "Codex"), ("claude", "Claude"), ("hermes", "Hermes")])
                VoiceText(model: model, title: "Workspace", path: "brain.workspacePath", isPath: true)
                VoiceText(model: model, title: "Assistant name", path: "brain.assistantName")
                VoiceText(model: model, title: "Port", path: "brainPort", isNumber: true)
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
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $draft).labelsHidden().onSubmit { commit(draft) }
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
        panel.canChooseFiles = true
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
