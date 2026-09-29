import AppKit
import SwiftUI

/// The onboarding's state and actions, shared by the overlay, the `onboarding` verb and the
/// snapshots. Voice and brain settings go through the voice host's socket (the settings
/// window's `VoiceSettingsModel`), the live "try it" area follows its `subscribe` stream, and
/// the Apps step drives the catalog's `AppsTabModel`, so there is one writer for each.
@MainActor
final class OnboardingModel: ObservableObject {
    /// How the user left the overlay.
    enum Exit: String {
        /// "Finish" on the last step.
        case finished
        /// "Skip setup".
        case skipped
        /// "Finish later" (Esc, the close button, `onboarding hide`): resumes at this step.
        case later
    }

    @Published private(set) var step: OnboardingStep = .welcome
    @Published private(set) var accessibility = false
    @Published private(set) var microphone: MicrophoneAccess = .notAsked
    /// Why a permission button did nothing, or what to do next.
    @Published private(set) var permissionNote: String?
    @Published private(set) var live = VoiceLiveState()
    @Published private(set) var brain: BrainStatus?
    /// Why `brain status` failed (an older voice host, the host is down).
    @Published private(set) var brainStatusError: String?
    /// The last brain change that failed.
    @Published private(set) var brainNote: String?
    /// The "try it" text area, where dictation pastes while the overlay has focus.
    @Published var tryText = ""

    let voiceSettings: VoiceSettingsModel
    let apps: AppsTabModel
    var tour = OnboardingTour()
    /// Picks the brain's workspace folder (an open panel); nil when cancelled.
    var chooseFolder: (@escaping @MainActor (URL?) -> Void) -> Void = { done in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "The folder the agent works in."
        done(panel.runModal() == .OK ? panel.url : nil)
    }
    var onStepChange: ((OnboardingStep) -> Void)?
    var onExit: ((Exit) -> Void)?

    private let permissions: OnboardingPermissions
    private weak var voice: VoiceServices?
    private var ticks = 0

    init(voice: VoiceServices, apps: AppsTabModel, permissions: OnboardingPermissions) {
        self.voice = voice
        voiceSettings = voice.settingsModel
        self.apps = apps
        self.permissions = permissions
        let previous = voice.connection.onStateChange
        voice.connection.onStateChange = { [weak self] in
            previous?()
            self?.voiceStateChanged()
        }
        let previousConnection = voice.connection.onConnectionChange
        voice.connection.onConnectionChange = { [weak self] in
            previousConnection?()
            self?.voiceStateChanged()
            if self?.voice?.connection.isConnected == true { self?.refreshBrainStatus() }
        }
        refreshPermissions()
        voiceStateChanged()
    }

    // MARK: - Navigation

    func go(to step: OnboardingStep) {
        guard step != self.step else { return }
        self.step = step
        onStepChange?(step)
        refresh()
    }

    /// Enters `step` without reporting a change (showing the overlay where it was left).
    func resume(at step: OnboardingStep) {
        self.step = step
        refresh()
    }

    func next() {
        guard let next = step.next else { finish(); return }
        go(to: next)
    }

    func back() {
        if let previous = step.previous { go(to: previous) }
    }

    func finish() { onExit?(.finished) }
    func skip() { onExit?(.skipped) }
    func later() { onExit?(.later) }

    /// Everything the current step shows, read again.
    func refresh() {
        refreshPermissions()
        voiceStateChanged()
        switch step {
        case .voice: voiceSettings.load()
        case .brain:
            voiceSettings.load()
            refreshBrainStatus()
        default: break
        }
    }

    /// Called about once a second while the overlay is up: permissions change in System
    /// Settings and the brain comes up on its own, neither with a notification.
    func tick() {
        ticks += 1
        refreshPermissions()
        if step == .brain, ticks % 3 == 0 { refreshBrainStatus() }
    }

    // MARK: - Permissions

    func refreshPermissions() {
        if accessibility != permissions.accessibility { accessibility = permissions.accessibility }
        if microphone != permissions.microphone { microphone = permissions.microphone }
    }

    func requestAccessibility() {
        permissionNote = permissions.requestAccessibility()
            ?? "Turn MacHUD on in System Settings › Privacy & Security › Accessibility. This updates by itself."
    }

    func requestMicrophone() {
        permissionNote = permissions.requestMicrophone { [weak self] _ in self?.refreshPermissions() }
    }

    func openAccessibilitySettings() { permissionNote = permissions.openAccessibilitySettings() }
    func openMicrophoneSettings() { permissionNote = permissions.openMicrophoneSettings() }

    var permissionsGranted: Bool { accessibility && microphone == .granted }

    // MARK: - Voice

    var voiceHostUp: Bool { voiceSettings.canEdit }
    var voiceOn: Bool { voiceHostUp && voiceSettings.bool("enabled") }
    var keyMode: String { voiceSettings.string("keyMode").isEmpty ? "hold" : voiceSettings.string("keyMode") }

    func setVoice(on: Bool) {
        if on {
            if !voiceHostUp { voiceSettings.turnOn() } else { voiceSettings.set("enabled", true) }
        } else {
            voiceSettings.set("enabled", false)
        }
    }

    func setKeyMode(_ mode: String) { voiceSettings.set("keyMode", mode) }
    func setAgentGesture(_ on: Bool) { voiceSettings.set("agentGesture", on) }

    private func voiceStateChanged() {
        let state = VoiceLiveState(state: voice?.connection.isConnected == true ? voice?.connection.state : nil)
        if state != live { live = state }
        if state.brainAvailable, brain?.available == false { refreshBrainStatus() }
    }

    // MARK: - Brain

    var selectedRuntime: String { voiceSettings.string("brain.runtime") }
    var brainEnabled: Bool { voiceSettings.bool("brainEnabled") }

    var workspace: String {
        let stored = voiceSettings.string("brain.workspacePath")
        return stored.isEmpty ? brain?.workspace ?? "" : stored
    }

    var brainReady: Bool { brain?.available == true || live.brainAvailable }

    /// Why the brain is not up yet, for the user; nil when it is ready.
    var brainProblem: String? {
        guard !brainReady else { return nil }
        if !voiceHostUp { return "Turn voice on first: the brain runs inside the voice host." }
        if !brainEnabled { return "The brain is off. Choose a runtime to turn it on." }
        if workspace.isEmpty { return "Choose a workspace folder for the agent." }
        return brain?.problem ?? live.brainProblem ?? brainStatusError ?? "The brain is starting."
    }

    /// Whether `id` is installed, as `brain status` detected it; nil when unknown.
    func runtimeInstalled(_ id: String) -> Bool? { brain?.runtime(id)?.installed }
    func runtimePath(_ id: String) -> String? { brain?.runtime(id)?.path }

    func chooseRuntime(_ id: String) {
        apply(["brainEnabled": true, "brain.runtime": id])
    }

    func chooseWorkspace() {
        chooseFolder { [weak self] url in
            guard let url else { return }
            self?.apply(["brain.workspacePath": url.path])
        }
    }

    /// Several settings in one `settings set`, so they never race each other.
    func apply(_ changes: [String: Any]) {
        guard voiceSettings.canEdit, let voice else {
            brainNote = "Turn voice on first: the brain's settings live in the voice host."
            return
        }
        var updated = voiceSettings.settings
        for (path, value) in changes.sorted(by: { $0.key < $1.key }) {
            updated = VoiceSettingsJSON.setting(updated, path, to: value)
        }
        voice.sendSettings(updated) { [weak self] reply in
            guard let self else { return }
            self.brainNote = reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "settings set failed"
            self.voiceSettings.load { self.refreshBrainStatus() }
        }
    }

    /// `brain status` from the voice host.
    func refreshBrainStatus() {
        guard let voice, voice.connection.isConnected else { return }
        voice.perform(.forward("brain", ["action": "status"])) { [weak self] reply in
            guard let self else { return }
            if let status = BrainStatus(reply: reply) {
                if status != self.brain { self.brain = status }
                self.brainStatusError = nil
            } else {
                self.brainStatusError = reply["error"] as? String ?? "brain status failed"
            }
        }
    }

    // MARK: - Apps

    /// The catalog row for MechaHUD, which shows mclaude sessions.
    var mechaHUD: AppsTabModel.Row? { apps.rows.first { $0.entry.matches("mechahud") } }

    // MARK: - Report

    var json: [String: Any] {
        var brainJSON: [String: Any] = ["ready": brainReady, "enabled": brainEnabled, "runtime": selectedRuntime,
                                        "workspace": workspace]
        if let problem = brainProblem { brainJSON["problem"] = problem }
        if let brain { brainJSON["runtimes"] = brain.runtimes.map { r -> [String: Any] in
            ["id": r.id, "installed": r.installed, "path": r.path.map { $0 as Any } ?? NSNull()]
        } }
        if let brainStatusError { brainJSON["statusError"] = brainStatusError }
        return [
            "step": step.rawValue,
            "permissions": ["accessibility": accessibility, "microphone": microphone.rawValue],
            "voice": ["status": voiceSettings.status.text, "on": voiceOn, "keyMode": keyMode,
                      "phase": live.phase, "connected": live.connected],
            "brain": brainJSON,
            "apps": apps.rows.map { ["id": $0.id, "state": $0.status.state.rawValue] },
        ]
    }
}
