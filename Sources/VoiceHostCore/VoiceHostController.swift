import BrainKit
import Foundation
import SpeakFreeLib
import VoiceKit

/// The voice host's brain stem: fn gestures, the orb, the wake word and the socket all come
/// in through `perform` or a collaborator's callback; dictation, the brain and speech go out.
/// The only writer of `VoiceHostState`; every change is rendered by `presenter` and passed to
/// `onStateChange`.
///
/// Takes: fn dictates at the cursor (`.begin(.primary)`) and moves the take to the agent on the
/// alternate gesture; the orb, the wake word and the socket's `ask` start an agent take that
/// ends on a click, `stop`, or a `SilenceEndpointer`. An agent take's text becomes a brain
/// turn whose snapshots fill the card and, with `voice.speakReplies`, are spoken as they stream.
@MainActor
public final class VoiceHostController: VoiceHostActing {
    public private(set) var state = VoiceHostState() {
        didSet {
            guard state != oldValue else { return }
            presenter?.render(state)
            onStateChange?(state)
        }
    }
    public private(set) var settings: VoiceHostSettings
    /// Draws the state. Rendered once when set, then on every change.
    public var presenter: VoiceHostPresenting? {
        didSet { presenter?.render(state) }
    }
    /// Every state change, after the presenter (the socket's `state` event).
    public var onStateChange: ((VoiceHostState) -> Void)?

    /// The latest brain request, approval or cancel in flight (tests await it).
    var pendingWork: Task<Void, Never>?

    /// How long a failure shows before the orb rests again.
    static let failureDisplay: TimeInterval = 4
    static let brainOff = "The brain is off"
    static let modelMissing = "Speech model not installed"
    /// Progress lines kept on the card.
    static let progressLimit = 4

    private let dictation: DictationDriving
    private let keys: VoiceKeySource?
    private let brain: BrainDriving?
    private let speaker: ReplySpeaking?
    private let wake: WakeDriving?
    private let brainStateRoot: URL
    private let now: () -> TimeInterval
    private let schedule: VoiceScheduler

    private struct Take {
        /// Nil until the session names the take (its first update or `start`'s outcome).
        var id: UUID?
        var mode: VoiceMode
        /// Hands-free takes only.
        var endpointer: SilenceEndpointer?
    }

    private struct Turn {
        let requestId: String
        /// Characters of the reply already handed to the speaker.
        var spoken = 0
        var lastProgress = ""
        var speaks: Bool
        /// The user closed the card while the turn runs; snapshots do not bring it back.
        var cardDismissed = false
    }

    private struct KeySetup: Equatable {
        var mode: KeyGestureRecognizer.Mode
        var alternateEnabled: Bool
    }

    /// The capturing take.
    private var take: Take?
    /// The most recent take; only its outcome moves the phase.
    private var latestTakeID: UUID?
    private var turn: Turn?
    private var runningKeys: KeySetup?
    private var runningWake: VoiceSettings?
    /// The brain configuration last applied; `.none` until the first apply.
    private var appliedBrain: BrainServiceConfiguration??
    private var appliedVoice: VoiceSettings?
    private var failureToken = UUID()
    private var started = false

    /// - Parameters:
    ///   - keys: nil without an fn event tap (`MACHUD_NO_HOTKEYS`).
    ///   - brain: nil when the brain can never run (`MACHUD_VOICE_NO_BRAIN`).
    ///   - wake: nil without a microphone for it.
    ///   - brainStateRoot: the folder per-workspace brain state directories go under.
    init(settings: VoiceHostSettings, dictation: DictationDriving, keys: VoiceKeySource?,
         brain: BrainDriving?, speaker: ReplySpeaking?, wake: WakeDriving?, brainStateRoot: URL,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping VoiceScheduler = mainQueueScheduler) {
        self.settings = settings
        self.dictation = dictation
        self.keys = keys
        self.brain = brain
        self.speaker = speaker
        self.wake = wake
        self.brainStateRoot = brainStateRoot
        self.now = now
        self.schedule = schedule
    }

    /// Connects the collaborators and applies the settings.
    func start() {
        guard !started else { return }
        started = true
        dictation.onUpdate = { [weak self] id, update in self?.handle(update, take: id) }
        brain?.onAvailabilityChanged = { [weak self] available in
            guard let self else { return }
            state.brainAvailable = available && brainEnabled
        }
        brain?.onSnapshot = { [weak self] in self?.handle($0) }
        speaker?.onFinished = { [weak self] in
            guard let self, state.phase == .speaking else { return }
            state.phase = .idle
        }
        wake?.onWake = { [weak self] in
            guard let self else { return }
            startTake(.agent, handsFree: true)
            // The listener stays quiet after a wake; with no take to pause it, listen again now.
            if take == nil { restartWake() }
        }
        wake?.onListeningChanged = { [weak self] in self?.state.wakeListening = $0 }
        apply(settings)
    }

    /// Applies new settings: keys, wake word, brain and voice follow at once.
    func apply(_ settings: VoiceHostSettings) {
        self.settings = settings
        if appliedVoice != settings.voice {
            appliedVoice = settings.voice
            speaker?.configure(settings.voice)
        }
        refreshKeys()
        refreshWake()
        refreshBrain()
    }

    func setHiddenForFullScreen(_ hidden: Bool) {
        state.hiddenForFullScreen = hidden
    }

    // MARK: - Actions

    public func perform(_ action: VoiceHostAction) {
        switch action {
        case .orbClicked:
            if isSpeaking { return stopSpeech() }
            if take != nil { return dictation.stop() }
            switch state.phase {
            case .idle, .failed: startTake(.agent, handsFree: true)
            default: break
            }
        case .start(let mode):
            startTake(mode, handsFree: mode == .agent)
        case .stop:
            if take != nil { dictation.stop() } else if isSpeaking { stopSpeech() }
        case .cancel:
            cancel()
        case .approve(let id):
            answer(id, allow: true)
        case .deny(let id):
            answer(id, allow: false)
        case .dismissCard:
            stopSpeech()
            turn?.cardDismissed = true
            state.card = nil
        case .setMuted(let muted):
            state.muted = muted
            if muted {
                stopSpeech()
                turn?.speaks = false
            }
            refreshKeys()
            refreshWake()
        }
    }

    private func cancel() {
        if take != nil || dictation.isCapturing {
            dictation.cancel()
            if take != nil {
                // The session reported nothing (no take was capturing after all).
                take = nil
                settle(.idle)
            }
        } else if turn != nil, let brain {
            stopSpeech()
            pendingWork = Task { try? await brain.cancel() }
        } else if isSpeaking {
            stopSpeech()
        }
    }

    // MARK: - Takes

    private var brainEnabled: Bool { settings.brainEnabled && brain != nil }

    private func startTake(_ mode: VoiceMode, handsFree: Bool) {
        stopSpeech()
        if mode == .agent, !brainEnabled { return fail(Self.brainOff) }
        guard take == nil, !dictation.isCapturing else { return }
        take = Take(id: nil, mode: mode, endpointer: handsFree ? SilenceEndpointer() : nil)
        refreshWake()
        switch dictation.start(mode == .agent ? .caller : .cursor) {
        case .started(let id), .resumed(let id):
            if take != nil, take?.id == nil { take?.id = id }
            latestTakeID = id
        case .refused(let failure), .failed(let failure):
            // `.failed` was reported through `onUpdate` too; only a refusal still holds the take.
            guard take != nil, take?.id == nil else { return }
            take = nil
            refreshWake()
            if let message = Self.message(for: failure) { fail(message) } else { settle(.idle) }
        }
    }

    private func handle(_ intent: KeyGestureRecognizer.Intent) {
        // Any fn press interrupts a reply being spoken.
        stopSpeech()
        switch intent {
        case .begin(.primary): startTake(.dictation, handsFree: false)
        case .begin(.alternate): startTake(.agent, handsFree: false)
        case .retarget(let target): dictation.retarget(target == .alternate ? .caller : .cursor)
        case .end: if take != nil { dictation.stop() }
        case .discard: dictation.cancel()
        }
    }

    private func handle(_ update: DictationUpdate, take id: UUID) {
        let isCurrent = take.map { $0.id == nil || $0.id == id } ?? false
        if isCurrent, take?.id == nil {
            take?.id = id
            latestTakeID = id
        }
        let isLatest = id == latestTakeID
        switch update {
        case .recording(let destination), .retargeted(let destination):
            guard isCurrent else { return }
            let mode = Self.mode(for: destination)
            take?.mode = mode
            state.phase = .listening(mode)
        case .level(let level):
            guard isCurrent else { return }
            state.inputLevel = level
            if take?.endpointer?.observe(level: level, at: now()) == true {
                take?.endpointer = nil
                dictation.stop()
            }
        case .partial(let text):
            guard isCurrent else { return }
            state.partialTranscript = text
        case .transcribing:
            guard isCurrent, let mode = take?.mode else { return }
            take = nil
            var next = state
            next.phase = .transcribing(mode)
            next.inputLevel = 0
            state = next
            refreshWake()
        case .finished(let text, let destination):
            endCapture(ifCurrent: isCurrent)
            if destination == .caller {
                submit(text, isLatest: isLatest)
            } else if isLatest {
                settle(.idle)
            }
        case .failed(let failure):
            endCapture(ifCurrent: isCurrent)
            guard isLatest else { return }
            if let message = Self.message(for: failure) { fail(message) } else { settle(.idle) }
        }
    }

    private func endCapture(ifCurrent isCurrent: Bool) {
        guard isCurrent else { return }
        take = nil
        refreshWake()
    }

    /// The phase after a take, with the take's transient fields cleared.
    private func settle(_ phase: VoicePhase) {
        var next = state
        next.phase = phase
        next.inputLevel = 0
        next.partialTranscript = ""
        state = next
    }

    private func fail(_ message: String) {
        settle(.failed(message))
        let token = UUID()
        failureToken = token
        schedule(Self.failureDisplay) { [weak self] in
            guard let self, failureToken == token, state.phase == .failed(message) else { return }
            state.phase = .idle
        }
    }

    private static func mode(for destination: DictationDestination) -> VoiceMode {
        destination == .caller ? .agent : .dictation
    }

    /// What the orb says about a failed take; nil for an ending that needs no message.
    static func message(for failure: DictationFailure) -> String? {
        switch failure {
        case .cancelled, .tooShort, .notRecording, .busy: return nil
        case .modelMissing, .engineNotReady: return modelMissing
        default: return failure.message
        }
    }

    // MARK: - Brain turns

    private func submit(_ text: String, isLatest: Bool) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            if isLatest { settle(.idle) }
            return
        }
        guard brainEnabled, let brain else { return fail(Self.brainOff) }
        stopSpeech()
        let requestId = UUID().uuidString
        turn = Turn(requestId: requestId, speaks: settings.voice.speakReplies && !state.muted)
        var next = state
        next.card = VoiceCard(prompt: prompt)
        if isLatest {
            next.phase = .working
            next.inputLevel = 0
            next.partialTranscript = ""
        }
        state = next
        pendingWork = Task { [weak self] in
            do {
                try await brain.submit(prompt, requestId: requestId)
            } catch {
                guard let self, turn?.requestId == requestId else { return }
                turn = nil
                fail(error.localizedDescription)
            }
        }
    }

    private func handle(_ snapshot: AgentSessionSnapshot) {
        guard var turn, snapshot.requestId == turn.requestId else { return }
        var next = state
        if !turn.cardDismissed {
            var card = next.card ?? VoiceCard()
            card.reply = snapshot.output
            let progress = snapshot.progress.trimmingCharacters(in: .whitespacesAndNewlines)
            if !progress.isEmpty, progress != turn.lastProgress {
                turn.lastProgress = progress
                card.progress = Array((card.progress + [progress]).suffix(Self.progressLimit))
            }
            card.approval = snapshot.approvals.first.map {
                VoiceApproval(id: $0.id, summary: $0.reason, detail: $0.command ?? $0.cwd ?? "")
            }
            next.card = card
        }
        if turn.speaks, let speaker, snapshot.output.count > turn.spoken {
            speaker.append(String(snapshot.output.dropFirst(turn.spoken)))
            turn.spoken = snapshot.output.count
        }
        switch snapshot.status {
        case "approval":
            next.phase = .awaitingApproval
            self.turn = turn
        case "idle" where snapshot.turnId != nil:
            if turn.speaks { speaker?.finish() }
            self.turn = nil
            next.phase = turn.speaks && isSpeaking ? .speaking : .idle
        case "interrupted":
            speaker?.stop()
            self.turn = nil
            next.phase = .idle
        case "failed":
            speaker?.stop()
            self.turn = nil
            state = next
            return fail(snapshot.error ?? "The brain stopped")
        default:
            next.phase = .working
            self.turn = turn
        }
        // A take recording meanwhile keeps its phase; the card still updates.
        if take != nil { next.phase = state.phase }
        state = next
    }

    private func answer(_ id: String, allow: Bool) {
        guard let brain else { return }
        var next = state
        if next.card?.approval?.id == id { next.card?.approval = nil }
        if next.phase == .awaitingApproval { next.phase = .working }
        state = next
        pendingWork = Task { [weak self] in
            do {
                try await brain.approve(id: id, allow: allow)
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Speech

    private var isSpeaking: Bool { speaker?.isSpeaking == true || state.phase == .speaking }

    private func stopSpeech() {
        guard isSpeaking else { return }
        speaker?.stop()
        turn?.speaks = false
        if state.phase == .speaking { state.phase = .idle }
    }

    // MARK: - Collaborators

    private func refreshKeys() {
        guard let keys else { return }
        let wanted = settings.enabled && !state.muted
            ? KeySetup(mode: settings.keyMode == .toggle ? .toggle : .hold, alternateEnabled: settings.agentGesture)
            : nil
        guard wanted != runningKeys else { return }
        if runningKeys != nil { keys.stop() }
        runningKeys = wanted
        guard let wanted else { return }
        keys.start(mode: wanted.mode, alternateEnabled: wanted.alternateEnabled,
                   isSessionActive: { [weak self] in self?.dictation.isCapturing ?? false },
                   onIntent: { [weak self] in self?.handle($0) })
    }

    /// The wake word listens while voice is on, not muted and no take is recording.
    private func refreshWake() {
        guard let wake else { return }
        let wanted = settings.enabled && !state.muted && settings.voice.wakeWordEnabled && take == nil
            ? settings.voice : nil
        guard wanted != runningWake else { return }
        if runningWake != nil { wake.stop() }
        runningWake = wanted
        if let wanted { wake.start(wanted) }
    }

    private func restartWake() {
        if runningWake != nil { wake?.stop() }
        runningWake = nil
        refreshWake()
    }

    private func refreshBrain() {
        let wanted: BrainServiceConfiguration? = brainEnabled
            ? settings.brain.serviceConfiguration(
                stateDirectory: BrainServiceConfiguration.stateDirectory(
                    forWorkspace: settings.brain.workspacePath, under: brainStateRoot).path,
                port: settings.brainPort)
            : nil
        if !brainEnabled { state.brainAvailable = false }
        guard let brain, appliedBrain != .some(wanted) else { return }
        appliedBrain = .some(wanted)
        brain.configure(wanted)
    }
}
