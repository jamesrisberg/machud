import AppKit
import HUDKit
import SwiftUI

/// The onboarding's state and actions, shared by the overlay, the `onboarding` verb and the
/// snapshots. Voice and brain settings go through the voice host's socket (the settings
/// window's `VoiceSettingsModel`), the live "try it" area follows its `subscribe` stream, the
/// Apps step drives the catalog's `AppsTabModel`, the Tool dock section the tool dock itself
/// and the loadout sections the loadout engine, so there is one writer for each.
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

    /// What the overlay shrinks to while the user works on the desktop.
    enum Compact: String {
        /// Arranging windows for the first loadout: the card offers Capture.
        case arrange
        /// Practising the radial menu: the card waits for the apply.
        case practice
    }

    @Published private(set) var step: OnboardingStep = .welcome
    /// Sections the user marked by moving on or skipping; `status(of:)` adds the ones that
    /// are done by themselves (permissions granted, brain ready, a loadout made, the wheel used).
    @Published private(set) var marks: [OnboardingStep: OnboardingSectionStatus] = [:]
    /// Non-nil while the overlay is a small card so the desktop is free to use.
    @Published private(set) var compact: Compact?
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
    /// What the last "Test voice" did, when it did not work.
    @Published private(set) var sayNote: String?
    @Published private(set) var saying = false
    /// The Kokoro voice's download state (`models status`); nil when the host does not say.
    @Published private(set) var kokoro: ModelDownloadStatus?
    @Published private(set) var kokoroNote: String?
    /// The Parakeet speech model's download state (`models status`); nil when the host does not say.
    @Published private(set) var parakeet: ModelDownloadStatus?
    @Published private(set) var parakeetNote: String?
    @Published private(set) var dockEnabled = true
    @Published private(set) var dockPosition: HUDDockPosition = .bottom
    @Published private(set) var dockScreen: String?
    /// The name typed for the first loadout.
    @Published var loadoutName = "My Desk"
    @Published private(set) var firstLoadout: OnboardingLoadoutSummary?
    @Published private(set) var capturing = false
    /// Why the last capture did not work.
    @Published private(set) var loadoutNote: String?
    /// The apply the radial practice saw.
    @Published private(set) var practice: OnboardingApplied?

    let voiceSettings: VoiceSettingsModel
    let apps: AppsTabModel
    var hotkeys = OnboardingHotkeys()
    /// The tool dock, set once the app has made it.
    var toolDock: OnboardingToolDock? { didSet { refreshToolDock() } }
    /// Capture and apply, set once the app has the loadout engine.
    var loadouts: OnboardingLoadouts? {
        didSet {
            loadouts?.onApplied = { [weak self] applied in self?.applied(applied) }
            if let name = firstLoadout?.name { firstLoadout = loadouts?.summary(named: name) ?? firstLoadout }
        }
    }
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
    /// A section was marked, or the first loadout made: the record saves them.
    var onProgress: (() -> Void)?
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
        compact = nil
        guard step != self.step else { return }
        self.step = step
        onStepChange?(step)
        refresh()
    }

    /// Enters `step` without reporting a change (showing the overlay where it was left).
    func resume(at step: OnboardingStep) {
        compact = nil
        self.step = step
        refresh()
    }

    /// The saved progress: marked sections and the first loadout's name.
    func restore(sections: [String: OnboardingSectionStatus], loadout: String?) {
        marks = sections.reduce(into: [:]) { out, pair in
            if let step = OnboardingStep(rawValue: pair.key), step.isSection { out[step] = pair.value }
        }
        // A loadout deleted since reads as not made yet.
        firstLoadout = loadout.flatMap { name in
            guard let loadouts else { return OnboardingLoadoutSummary(name: name, regions: [], aspect: 1.6, screen: "") }
            return loadouts.summary(named: name)
        }
    }

    /// The primary button: settles the section (see `settle`) and goes on; from the welcome
    /// checklist, to the first section that is not done; on the last step, finishes.
    func next() {
        if step == .welcome {
            go(to: OnboardingStep.sections.first { status(of: $0) != .done } ?? .done)
            return
        }
        settle(step)
        guard let next = step.next else { finish(); return }
        go(to: next)
    }

    /// "Skip for now": marks the section skipped (unless it is already done) and goes on.
    func skipSection() {
        if step.isSection, status(of: step) != .done { mark(step, .skipped) }
        guard let next = step.next else { finish(); return }
        go(to: next)
    }

    func back() {
        if let previous = step.previous { go(to: previous) }
    }

    func finish() { onExit?(.finished) }
    func skip() { onExit?(.skipped) }
    func later() { onExit?(.later) }

    // MARK: - Checklist

    /// Where `section` stands: done by itself once its condition holds, else as marked.
    func status(of section: OnboardingStep) -> OnboardingSectionStatus {
        if isDoneByItself(section) { return .done }
        return marks[section] ?? .todo
    }

    var sectionsJSON: [String: String] {
        Dictionary(uniqueKeysWithValues: OnboardingStep.sections.map { ($0.rawValue, status(of: $0).rawValue) })
    }

    private func isDoneByItself(_ section: OnboardingStep) -> Bool {
        switch section {
        case .permissions: return permissionsGranted
        case .brain: return brainReady
        case .loadout: return firstLoadout != nil
        case .radial: return practice != nil
        default: return false
        }
    }

    /// Moving on from a section that is still to do: sections that are about a choice
    /// (apps, tool dock) and voice once it is on count as done; the rest are left skipped,
    /// and still turn done by themselves when their condition comes true later.
    private func settle(_ section: OnboardingStep) {
        guard section.isSection, status(of: section) == .todo else { return }
        switch section {
        case .apps, .toolDock: mark(section, .done)
        case .voice: mark(section, voiceOn ? .done : .skipped)
        default: mark(section, .skipped)
        }
    }

    private func mark(_ section: OnboardingStep, _ status: OnboardingSectionStatus) {
        guard marks[section] != status else { return }
        marks[section] = status
        onProgress?()
    }

    var markedSections: [String: OnboardingSectionStatus] {
        Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, $0.value) })
    }

    /// Everything the current step shows, read again.
    func refresh() {
        refreshPermissions()
        voiceStateChanged()
        refreshToolDock()
        switch step {
        case .voice:
            voiceSettings.load()
            refreshModels()
        case .brain:
            voiceSettings.load()
            refreshBrainStatus()
            refreshModels()
        default: break
        }
    }

    /// Called about once a second while the overlay is up: permissions change in System
    /// Settings, the brain comes up and downloads progress on their own, none with a
    /// notification.
    func tick() {
        ticks += 1
        refreshPermissions()
        refreshToolDock()
        if step == .brain, ticks % 3 == 0 { refreshBrainStatus() }
        if step == .brain, kokoro?.downloading == true || ticks % 3 == 0 { refreshModels() }
        if step == .voice, parakeet?.downloading == true || ticks % 3 == 0 { refreshModels() }
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

    /// The folder the agent works in: the user's choice, else what the host resolved (the
    /// home folder when none is chosen).
    var workspace: String {
        let stored = voiceSettings.string("brain.workspacePath")
        if !stored.isEmpty { return stored }
        if let resolved = brain?.workspace, !resolved.isEmpty { return resolved }
        return NSHomeDirectory()
    }

    /// No folder chosen: the agent works in the home folder.
    var workspaceIsDefault: Bool { voiceSettings.string("brain.workspacePath").isEmpty }

    /// `workspace` with the home folder as `~`.
    var workspaceDisplay: String { (workspace as NSString).abbreviatingWithTildeInPath }

    var brainReady: Bool { brain?.available == true || live.brainAvailable }

    /// Why the brain is not up yet, for the user; nil when it is ready.
    var brainProblem: String? {
        guard !brainReady else { return nil }
        if !voiceHostUp { return "Turn voice on first: the brain runs inside the voice host." }
        if !brainEnabled { return "The brain is off. Choose a runtime to turn it on." }
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

    /// Back to the default: the home folder.
    func useHomeWorkspace() { apply(["brain.workspacePath": ""]) }

    // MARK: - Replies

    var speakReplies: Bool { voiceSettings.bool("voice.speakReplies") }
    var replyVoice: String {
        let voice = voiceSettings.string("voice.replyVoice")
        return voice.isEmpty ? "kokoro" : voice
    }

    func setSpeakReplies(_ on: Bool) { apply(["voice.speakReplies": on]) }
    func setReplyVoice(_ id: String) {
        apply(["voice.replyVoice": id])
        if id == "kokoro" { refreshModels() }
    }

    static let testPhrase = "Hi. This is how I will sound when I answer you."

    /// Speaks a line with the chosen reply voice (`action name=say`), whether or not spoken
    /// replies are on.
    func testVoice() {
        guard let voice, voice.connection.isConnected else {
            sayNote = "Turn voice on first: replies are spoken by the voice host."
            return
        }
        saying = true
        sayNote = nil
        voice.perform(.forward("action", ["name": "say", "text": Self.testPhrase])) { [weak self] reply in
            guard let self else { return }
            self.saying = false
            self.sayNote = reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "say failed"
        }
    }

    /// `models status` for the Kokoro voice and the Parakeet speech model.
    func refreshModels() {
        guard let voice, voice.connection.isConnected else { return }
        voice.perform(.forward("models", ["action": "status"])) { [weak self] reply in
            guard let self else { return }
            let kokoro = ModelDownloadStatus(reply: reply, model: "kokoro")
            if kokoro != self.kokoro { self.kokoro = kokoro }
            if kokoro == nil, self.kokoroNote == nil { self.kokoroNote = reply["error"] as? String }
            let parakeet = ModelDownloadStatus(reply: reply, model: "parakeet")
            if parakeet != self.parakeet { self.parakeet = parakeet }
            if parakeet == nil, self.parakeetNote == nil { self.parakeetNote = reply["error"] as? String }
        }
    }

    /// Starts the Kokoro download (`models action=download id=kokoro`); progress comes from
    /// `refreshModels` on the tick.
    func downloadKokoro() {
        download("kokoro", note: \.kokoroNote, voiceOff: "Turn voice on first: the voice host downloads the voice.")
    }

    /// Starts the Parakeet download (`models action=download id=parakeet`), the speech model
    /// dictation needs; progress comes from `refreshModels` on the tick.
    func downloadParakeet() {
        download("parakeet", note: \.parakeetNote,
                 voiceOff: "Turn voice on first: the voice host downloads the speech model.")
    }

    private func download(_ id: String, note: ReferenceWritableKeyPath<OnboardingModel, String?>, voiceOff: String) {
        guard let voice, voice.connection.isConnected else {
            self[keyPath: note] = voiceOff
            return
        }
        self[keyPath: note] = nil
        voice.perform(.forward("models", ["action": "download", "id": id])) { [weak self] reply in
            guard let self else { return }
            if reply["ok"] as? Bool != true { self[keyPath: note] = reply["error"] as? String ?? "download failed" }
            self.refreshModels()
        }
    }

    // MARK: - Dictation history

    /// Where finished dictations are kept (`history status`), through the Voice tab's model.
    var history: VoiceSettingsModel.HistoryStatus? { voiceSettings.history }

    func setHistoryMode(_ mode: String) { voiceSettings.setHistory(mode: mode) }
    func setShareHistory(_ share: Bool) { voiceSettings.setHistory(shareWithSpeakFree: share) }

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

    // MARK: - Tool dock

    func refreshToolDock() {
        guard let toolDock else { return }
        if dockEnabled != toolDock.isEnabled { dockEnabled = toolDock.isEnabled }
        if dockPosition != toolDock.dockPosition { dockPosition = toolDock.dockPosition }
        if dockScreen != toolDock.screenName { dockScreen = toolDock.screenName }
    }

    func setDock(enabled: Bool) {
        toolDock?.setEnabled(enabled)
        refreshToolDock()
    }

    func moveDock(to position: HUDDockPosition) {
        toolDock?.move(to: position)
        if toolDock?.isEnabled == false { toolDock?.setEnabled(true) }
        refreshToolDock()
    }

    // MARK: - First loadout

    /// Shrinks the overlay to a card so the user can arrange windows.
    func startArranging() {
        loadoutNote = nil
        compact = .arrange
    }

    /// Captures the windows on this display as `loadoutName`.
    func captureLoadout() {
        guard let loadouts else { loadoutNote = "Loadouts are not available."; return }
        capturing = true
        loadoutNote = nil
        loadouts.capture(name: loadoutName) { [weak self] result in
            guard let self else { return }
            self.capturing = false
            switch result {
            case .success(let summary):
                self.firstLoadout = summary
                self.compact = nil
                self.onProgress?()
            case .failure(let problem):
                self.loadoutNote = problem.message
            }
        }
    }

    /// Back to the full overlay without capturing or practising.
    func expand() { compact = nil }

    // MARK: - Radial practice

    /// The loadout the practice asks for: the one just made, else the first there is.
    var practiceTarget: String? { firstLoadout?.name ?? loadouts?.names.first }

    func startPractice() {
        practice = nil
        compact = .practice
    }

    private func applied(_ applied: OnboardingApplied) {
        guard step == .radial || compact == .practice, applied.loadout == practiceTarget else { return }
        practice = applied
        compact = nil
        onProgress?()
    }

    // MARK: - Report

    private var voiceJSON: [String: Any] {
        var voice: [String: Any] = ["status": voiceSettings.status.text, "on": voiceOn, "keyMode": keyMode,
                                    "phase": live.phase, "connected": live.connected,
                                    "speechModel": parakeet.map { $0.json as Any } ?? NSNull()]
        if let history {
            voice["history"] = ["mode": history.mode, "shareWithSpeakFree": history.shareWithSpeakFree,
                                "speakFreeInstalled": history.speakFreeInstalled, "folder": history.folder]
        }
        return voice
    }

    var json: [String: Any] {
        var brainJSON: [String: Any] = ["ready": brainReady, "enabled": brainEnabled, "runtime": selectedRuntime,
                                        "workspace": workspace]
        if let problem = brainProblem { brainJSON["problem"] = problem }
        if let brain { brainJSON["runtimes"] = brain.runtimes.map { r -> [String: Any] in
            ["id": r.id, "installed": r.installed, "path": r.path.map { $0 as Any } ?? NSNull()]
        } }
        if let brainStatusError { brainJSON["statusError"] = brainStatusError }
        brainJSON["workspaceIsDefault"] = workspaceIsDefault
        brainJSON["replies"] = ["speak": speakReplies, "voice": replyVoice,
                                "kokoro": kokoro.map { $0.json as Any } ?? NSNull()]
        var radial: [String: Any] = ["hotkey": hotkeys.radialWheel, "target": practiceTarget.map { $0 as Any } ?? NSNull()]
        if let practice { radial["applied"] = ["loadout": practice.loadout, "placed": practice.placed, "failed": practice.failed] }
        return [
            "step": step.rawValue,
            "compact": compact.map { $0.rawValue as Any } ?? NSNull(),
            "sections": sectionsJSON,
            "permissions": ["accessibility": accessibility, "microphone": microphone.rawValue],
            "voice": voiceJSON,
            "brain": brainJSON,
            "apps": apps.rows.map { ["id": $0.id, "state": $0.status.state.rawValue] },
            "toolDock": ["enabled": dockEnabled, "position": dockPosition.rawValue,
                         "screen": dockScreen.map { $0 as Any } ?? NSNull()],
            "loadout": firstLoadout.map { $0.json as Any } ?? NSNull(),
            "radial": radial,
        ]
    }
}
