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
/// alternate gesture, with `gesturePending` set until the gesture is decided; the orb, the wake word and the socket's `ask` start an agent take that
/// ends on a click, `stop`, or a `SilenceEndpointer`. An agent take's text becomes a brain
/// turn whose snapshots fill the card and, with `voice.speakReplies`, are spoken as they stream.
///
/// One turn at a time: the companion refuses a second one, so while the brain works an agent
/// take is refused, and a take moved to the agent then (or while the brain is off) is typed at
/// the cursor instead.
///
/// `brainProblem` says why the brain cannot take a turn (settings, the chosen runtime's tool, or
/// the companion's own reason). A problem the user has to fix first refuses an agent take up
/// front with that reason; one that passes on its own (starting, restarting) does not.
///
/// Each finished take's words go to MacHUD's text feed (`feedTranscripts`), and each finished
/// agent reply too with `feedAgentReplies`; the history setting is handed to the dictation.
///
/// The wake word listens only for a phrase whose model is installed (`wakeModels`). While it is
/// on and cannot listen, `wakeProblem` says why, and turning it on shows that under the orb;
/// a model installed later arms it at once (`wakeModelsChanged`).
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

    /// The latest brain request, approval, cancel or session open in flight (tests await it).
    var pendingWork: Task<Void, Never>?
    /// The latest lookup of the app sessions open in (tests await it).
    var providerLookup: Task<Void, Never>?

    /// How long a failure shows before the orb rests again.
    static let failureDisplay: TimeInterval = 3
    static let brainOff = "The brain is off"
    static let brainOffPasted = "The brain is off — pasted instead"
    static let agentBusy = "The agent is still working"
    static let agentBusyPasted = "The agent is still working — pasted instead"
    static let voiceOff = "Voice is off"
    static let voiceMuted = "Voice is muted"
    static let modelMissing = "Speech model not installed"
    static let brainStarting = "The brain is starting."
    static let brainConnecting = "Connecting to the brain…"
    static let noSession = "There is no agent session to open"
    static let takeRecording = "A take is recording"
    static let noSpeech = "Speech is not available"
    static let wakeUnavailable = "The wake word needs the microphone, which this voice host does not use."
    /// Progress lines kept on the card.
    static let progressLimit = 4

    private let dictation: DictationDriving
    private let keys: VoiceKeySource?
    private let brain: BrainDriving?
    private let speaker: ReplySpeaking?
    private let wake: WakeDriving?
    /// The wake phrases there are models for, in the order they are offered.
    let wakeModels: [WakePhraseModel]
    private let brainStateRoot: URL
    private let sessions: SessionOpening?
    private let feed: TextFeeding?
    /// MacHUD's tool server; nil when `machud-mcp` is not beside the voice host.
    let machudTools: MacHUDToolServer?
    /// MacHUD's apps and loadouts, for the host context; nil reads nothing.
    private let machudStatus: MacHUDStatusReading?
    private let detectRuntimes: (BrainSettings) -> [BrainRuntimeDetection]
    private let sessionKeyOf: (AgentSessionSnapshot) -> String?
    /// The brain's workspace while the settings name none.
    private let homeDirectory: URL
    private let now: () -> TimeInterval
    private let schedule: VoiceScheduler

    private struct Take {
        /// Nil until the session names the take (its first update or `start`'s outcome).
        var id: UUID?
        var mode: VoiceMode
        /// Hands-free takes only.
        var endpointer: SilenceEndpointer?
        /// Started by the fn key: a change to the key setup ends it.
        var fromKeys = false
        /// The take was kept at the cursor instead of going to the agent; shown when it ends.
        var pastedNotice: String?
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
        var configuration: KeyGestureRecognizer.Configuration
    }

    /// The fn press whose gesture is undecided (`state.gesturePending`).
    private struct Gesture {
        let id = UUID()
        let pressedAt: TimeInterval
        var keyDown = true
    }

    /// The capturing take.
    private var take: Take? {
        didSet { if take == nil { endGesture() } }
    }
    private var gesture: Gesture?
    /// The most recent take; only its outcome moves the phase.
    private var latestTakeID: UUID?
    private var turn: Turn?
    /// A turn submitted and not yet accepted.
    private var submitting: String?
    /// The brain's latest snapshot, whoever's request it is.
    private var lastSnapshot: AgentSessionSnapshot?
    private var runningKeys: KeySetup?
    private var runningWake: VoiceSettings?
    /// The brain configuration last applied; `.none` until the first apply.
    private var appliedBrain: BrainServiceConfiguration??
    /// The host context for MacHUD's tools, from MacHUD's apps and loadouts; nil until read.
    private var hostContext: String?
    /// Reading MacHUD for the host context (tests await it).
    private(set) var hostContextLoad: Task<Void, Never>?
    private var appliedVoice: VoiceSettings?
    private var failureToken = UUID()
    /// The notice of the take being transcribed.
    private var pendingNotice: String?
    private var started = false
    private var brainHealth: BrainHealth = .stopped
    /// The chosen runtime's problem on this Mac, for the settings last applied.
    private var runtimeProblem: String?
    /// Why the running wake listener stopped by itself; cleared when it starts again.
    private var wakeListenerProblem: String?

    /// - Parameters:
    ///   - keys: nil without an fn event tap (`MACHUD_NO_HOTKEYS`).
    ///   - brain: nil when the brain can never run (`MACHUD_VOICE_NO_BRAIN`).
    ///   - wake: nil without a microphone for it.
    ///   - wakeModels: the wake phrases there are models for, and their files.
    ///   - brainStateRoot: the folder per-workspace brain state directories go under.
    ///   - sessions: MacHUD's session broker; nil leaves `openSession` unavailable.
    ///   - feed: MacHUD's text-feed broker; nil sends nothing.
    ///   - machudTools: MacHUD's tool server, given to the brain while `machudTools` is on.
    ///   - machudStatus: MacHUD's apps and loadouts, described to the brain with the tools.
    ///   - detectRuntimes: which runtimes are installed, for the settings given.
    ///   - sessionKeyOf: a snapshot's session key.
    ///   - homeDirectory: the brain's workspace while `brain.workspacePath` is empty.
    init(settings: VoiceHostSettings, dictation: DictationDriving, keys: VoiceKeySource?,
         brain: BrainDriving?, speaker: ReplySpeaking?, wake: WakeDriving?, wakeModels: [WakePhraseModel] = [],
         brainStateRoot: URL, sessions: SessionOpening? = nil, feed: TextFeeding? = nil,
         machudTools: MacHUDToolServer? = nil, machudStatus: MacHUDStatusReading? = nil,
         detectRuntimes: @escaping (BrainSettings) -> [BrainRuntimeDetection] = { BrainRuntimes.detect($0) },
         sessionKeyOf: @escaping (AgentSessionSnapshot) -> String? = { $0.sessionKey },
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping VoiceScheduler = mainQueueScheduler) {
        self.settings = settings.resolvingWakePhrase(available: wakeModels.map(\.phrase))
        self.dictation = dictation
        self.keys = keys
        self.brain = brain
        self.speaker = speaker
        self.wake = wake
        self.wakeModels = wakeModels
        self.brainStateRoot = brainStateRoot
        self.sessions = sessions
        self.feed = feed
        self.machudTools = machudTools
        self.machudStatus = machudStatus
        self.detectRuntimes = detectRuntimes
        self.sessionKeyOf = sessionKeyOf
        self.homeDirectory = homeDirectory
        self.now = now
        self.schedule = schedule
    }

    /// Connects the collaborators and applies the settings.
    func start() {
        guard !started else { return }
        started = true
        dictation.onUpdate = { [weak self] id, update in self?.handle(update, take: id) }
        brain?.onHealthChanged = { [weak self] health in
            guard let self else { return }
            brainHealth = health
            refreshBrainProblem()
        }
        brain?.onSnapshot = { [weak self] in self?.handle($0) }
        brain?.onStopped = { [weak self] in
            self?.brainLost()
            // Each (re)start describes MacHUD as it is now; a changed description restarts it once more.
            self?.loadHostContext()
        }
        speaker?.onFinished = { [weak self] in
            guard let self, state.phase == .speaking else { return }
            state.phase = .idle
        }
        wake?.onWake = { [weak self] in
            guard let self else { return }
            startTake(.agent, handsFree: true, fromKeys: false)
            // The listener stays quiet after a wake; with no take to pause it, listen again now.
            if take == nil { restartWake() }
        }
        wake?.onListeningChanged = { [weak self] in self?.state.wakeListening = $0 }
        wake?.onProblem = { [weak self] problem in
            guard let self else { return }
            wakeListenerProblem = problem
            refreshWakeProblem()
        }
        apply(settings)
    }

    /// Applies new settings: keys, wake word, brain, voice and history follow at once. A wake
    /// phrase no model detects resolves to the first one that has a model (see
    /// `VoiceHostSettings.resolvingWakePhrase`).
    func apply(_ settings: VoiceHostSettings) {
        let wakeTurnedOn = settings.voice.wakeWordEnabled && !self.settings.voice.wakeWordEnabled
        let settings = resolvingWakePhrase(settings)
        self.settings = settings
        dictation.setHistory(settings.history)
        if appliedVoice != settings.voice {
            appliedVoice = settings.voice
            speaker?.configure(settings.voice)
        }
        refreshKeys()
        refreshWake()
        refreshBrain()
        refreshBrainProblem()
        // Turning the wake word on when it cannot listen says why at once, under the orb.
        if wakeTurnedOn, let problem = state.wakeProblem { showNotice(problem) }
    }

    /// `settings` with a wake phrase there is a model for, while the wake word is on.
    func resolvingWakePhrase(_ settings: VoiceHostSettings) -> VoiceHostSettings {
        settings.resolvingWakePhrase(available: wakeModels.map(\.phrase))
    }

    /// A wake model was installed, removed or changed its download: listen as soon as the
    /// phrase's model is in place, and keep `wakeProblem` current.
    func wakeModelsChanged() {
        refreshWake()
        refreshWakeProblem()
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
            case .idle, .failed: startTake(.agent, handsFree: true, fromKeys: false)
            default: break
            }
        case .start(let mode):
            startTake(mode, handsFree: mode == .agent, fromKeys: false)
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
                cancelTake()
            }
            refreshKeys()
            refreshWake()
        case .openSession:
            openSession()
        }
    }

    /// Why a socket `dictate` or `ask` would not start, or nil.
    func refusal(for mode: VoiceMode) -> String? {
        if !settings.enabled { return Self.voiceOff }
        if state.muted { return Self.voiceMuted }
        return nil
    }

    /// Speaks `text` with the reply voice, whether or not replies are spoken (a preview from
    /// settings or onboarding); replaces anything being said. Nil once it is speaking, else why not.
    func say(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "say needs text=" }
        guard let speaker else { return Self.noSpeech }
        // Never into an open microphone.
        guard take == nil, !dictation.isCapturing else { return Self.takeRecording }
        stopSpeech()
        speaker.append(text)
        speaker.finish()
        switch state.phase {
        case .idle, .failed: state.phase = .speaking
        default: break
        }
        return nil
    }

    private func cancel() {
        if take != nil || dictation.isCapturing {
            cancelTake()
        } else if agentBusy, let brain {
            stopSpeech()
            pendingWork = Task { [weak self] in
                do {
                    try await brain.cancel()
                } catch {
                    // The brain is gone or refused: nothing will report the turn's end.
                    self?.brainLost()
                }
            }
        } else if isSpeaking {
            stopSpeech()
        }
    }

    private func cancelTake() {
        guard take != nil || dictation.isCapturing else { return }
        dictation.cancel()
        if take != nil {
            // The session reported nothing (no take was capturing after all).
            take = nil
            refreshWake()
            settle(.idle)
        }
    }

    /// The brain went away (stopped, restarted, or a cancel failed): no snapshot will end the
    /// turn, so it ends here.
    private func brainLost() {
        lastSnapshot = nil
        if state.activeRuntime != nil { state.activeRuntime = nil }
        submitting = nil
        setSessionKey(nil)
        guard turn != nil else { return }
        turn = nil
        speaker?.stop()
        if take == nil, [.working, .awaitingApproval, .speaking].contains(state.phase) { settle(.idle) }
    }

    // MARK: - Takes

    /// The brain runs only while voice is on; `enabled` off leaves the host idle.
    private var brainEnabled: Bool { settings.enabled && settings.brainEnabled && brain != nil }

    /// A turn is submitted, running or waiting on an approval (ours or another client's).
    private var agentBusy: Bool {
        turn != nil || submitting != nil || lastSnapshot?.isWorking == true
    }

    private func startTake(_ mode: VoiceMode, handsFree: Bool, fromKeys: Bool) {
        stopSpeech()
        // A reply still streaming is never spoken into the open microphone.
        turn?.speaks = false
        if !settings.enabled { return fail(Self.voiceOff) }
        if mode == .agent, !brainEnabled { return fail(Self.brainOff) }
        if mode == .agent, let problem = blockingBrainProblem { return fail(problem) }
        if mode == .agent, agentBusy { return fail(Self.agentBusy) }
        guard take == nil, !dictation.isCapturing else { return }
        take = Take(id: nil, mode: mode, endpointer: handsFree ? SilenceEndpointer() : nil, fromKeys: fromKeys)
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
        // Whatever the recognizer says next decides the gesture; a new press starts another.
        endGesture()
        switch intent {
        case .begin(.primary):
            // Armed before the take reports recording, so the orb never starts toward the waveform.
            beginGesture()
            startTake(.dictation, handsFree: false, fromKeys: true)
            if take == nil { endGesture() }
        case .begin(.alternate): startTake(.agent, handsFree: false, fromKeys: true)
        case .retarget(.alternate):
            // The agent cannot take it: keep the words at the cursor and say why at the end.
            if !brainEnabled {
                take?.pastedNotice = Self.brainOffPasted
            } else if let problem = blockingBrainProblem {
                take?.pastedNotice = Self.pasted(problem)
            } else if agentBusy {
                take?.pastedNotice = Self.agentBusyPasted
            } else {
                dictation.retarget(.caller)
            }
        case .retarget(.primary): dictation.retarget(.cursor)
        case .end: if take != nil { dictation.stop() }
        case .discard: dictation.cancel()
        }
    }

    // MARK: - Gesture window

    /// The recognizer's timing, shared by the key source and the gesture window here.
    static func gestureConfiguration(alternateEnabled: Bool) -> KeyGestureRecognizer.Configuration {
        KeyGestureRecognizer.Configuration(alternateEnabled: alternateEnabled)
    }

    /// An fn press began a take: until the gesture is decided the orb shows its armed look.
    /// Only a press no longer than a tap opens the double-tap window; the recognizer ends the
    /// wait itself on a second press (`retarget`, `end`) or a hold-mode lapse (`discard`), and
    /// the timers here cover the rest (a press held past a tap, a toggle-mode lapse).
    private func beginGesture() {
        guard take == nil, !dictation.isCapturing, let setup = runningKeys, setup.configuration.alternateEnabled
        else { return }
        let gesture = Gesture(pressedAt: now())
        self.gesture = gesture
        state.gesturePending = true
        schedule(setup.configuration.tapMaxDuration) { [weak self] in
            guard let self, self.gesture?.id == gesture.id, self.gesture?.keyDown == true else { return }
            endGesture()
        }
    }

    private func keyReleased() {
        guard var gesture, let setup = runningKeys else { return }
        let configuration = setup.configuration
        guard now() - gesture.pressedAt <= configuration.tapMaxDuration else { return endGesture() }
        gesture.keyDown = false
        self.gesture = gesture
        schedule(configuration.doubleTapWindow) { [weak self] in
            guard let self, self.gesture?.id == gesture.id else { return }
            endGesture()
        }
    }

    private func endGesture() {
        gesture = nil
        if state.gesturePending { state.gesturePending = false }
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
            guard isCurrent, let current = take else { return }
            let mode = current.mode
            // Keep the take's notice for its outcome.
            pendingNotice = current.pastedNotice
            take = nil
            var next = state
            next.phase = .transcribing(mode)
            next.inputLevel = 0
            state = next
            refreshWake()
        case .finished(let text, let destination, let transcript):
            let notice = isCurrent ? take?.pastedNotice : pendingNotice
            pendingNotice = nil
            endCapture(ifCurrent: isCurrent)
            if settings.feedTranscripts { sendToFeed(transcript, source: Self.dictationSource) }
            if destination == .caller {
                submit(text, isLatest: isLatest)
            } else if isLatest {
                if let notice { fail(notice) } else { settle(.idle) }
            }
        case .failed(let failure):
            pendingNotice = nil
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
        // The brain went off, or another turn started, while this take was recording.
        guard brainEnabled, let brain else { return paste(prompt, notice: Self.brainOffPasted) }
        if let problem = blockingBrainProblem { return paste(prompt, notice: Self.pasted(problem)) }
        guard !agentBusy else { return paste(prompt, notice: Self.agentBusyPasted) }
        stopSpeech()
        let requestId = UUID().uuidString
        submitting = requestId
        pendingWork = Task { [weak self] in
            do {
                try await brain.submit(prompt, requestId: requestId)
                self?.accepted(prompt, requestId: requestId, isLatest: isLatest)
            } catch {
                guard let self, submitting == requestId else { return }
                submitting = nil
                // A brain that is not up says why better than the client's error does.
                fail(state.brainAvailable ? error.localizedDescription : state.brainProblem ?? error.localizedDescription)
            }
        }
    }

    /// The brain took the turn: the card and the turn are ours from here.
    private func accepted(_ prompt: String, requestId: String, isLatest: Bool) {
        guard submitting == requestId else { return }
        submitting = nil
        turn = Turn(requestId: requestId, speaks: settings.voice.speakReplies && !state.muted && take == nil)
        var next = state
        next.card = VoiceCard(prompt: prompt)
        if isLatest, take == nil {
            next.phase = .working
            next.inputLevel = 0
            next.partialTranscript = ""
        }
        state = next
        // A snapshot for this request may have arrived before the reply did.
        if let lastSnapshot, lastSnapshot.requestId == requestId { handle(lastSnapshot) }
    }

    private func paste(_ text: String, notice: String) {
        dictation.insert(text)
        fail(notice)
    }

    private func handle(_ snapshot: AgentSessionSnapshot) {
        lastSnapshot = snapshot
        let runtime = snapshot.runtime ?? AgentRuntime.codex.rawValue
        if state.activeRuntime != runtime { state.activeRuntime = runtime }
        setSessionKey(sessionKeyOf(snapshot))
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
        if turn.speaks, take == nil, let speaker, snapshot.output.count > turn.spoken {
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
            if settings.feedAgentReplies {
                sendToFeed(snapshot.output, source: Self.agentSource, title: next.card?.prompt)
            }
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

    // MARK: - Text feed

    static let dictationSource = "Dictation"
    static let agentSource = "Agent"

    /// Hands `text` to MacHUD's text feed; empty text is not sent.
    private func sendToFeed(_ text: String, source: String, title: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let feed else { return }
        feed.add(text: text, source: source, title: title)
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
            ? KeySetup(mode: settings.keyMode == .toggle ? .toggle : .hold,
                       configuration: Self.gestureConfiguration(alternateEnabled: settings.agentGesture))
            : nil
        guard wanted != runningKeys else { return }
        // The new key source cannot end a take the old one began.
        if take?.fromKeys == true { cancelTake() }
        if runningKeys != nil { keys.stop() }
        runningKeys = wanted
        guard let wanted else { return }
        keys.start(mode: wanted.mode, configuration: wanted.configuration,
                   isSessionActive: { [weak self] in self?.dictation.isCapturing ?? false },
                   onIntent: { [weak self] in self?.handle($0) },
                   onRelease: { [weak self] in self?.keyReleased() })
    }

    /// The wake word is wanted while voice is on and not muted.
    private var wakeWanted: Bool { settings.enabled && !state.muted && settings.voice.wakeWordEnabled }

    /// The model for the chosen phrase, when there is one.
    private var wakeModel: WakePhraseModel? {
        wakeModels.first { $0.matches(phrase: settings.voice.wakePhrase) }
    }

    /// The wake word listens while it is wanted, its phrase's model is installed and no take is
    /// recording.
    private func refreshWake() {
        defer { refreshWakeProblem() }
        guard let wake else { return }
        let wanted = wakeWanted && take == nil && wakeModel?.store.status.installed == true ? settings.voice : nil
        guard wanted != runningWake else { return }
        if runningWake != nil { wake.stop() }
        runningWake = wanted
        wakeListenerProblem = nil
        if let wanted { wake.start(wanted) }
    }

    /// Why the wake word is on and not listening; nil while it is off, muted or able to listen.
    private func refreshWakeProblem() {
        let problem: String?
        if !wakeWanted {
            problem = nil
        } else if wake == nil {
            problem = Self.wakeUnavailable
        } else if let model = wakeModel {
            let status = model.store.status
            if status.installed {
                problem = wakeListenerProblem
            } else if status.downloading {
                problem = "The \(model.phrase) model is downloading."
            } else if let error = status.error {
                problem = "The \(model.phrase) model did not download: \(error)"
            } else {
                problem = "Download the \(model.phrase) model to use the wake word."
            }
        } else {
            problem = "There is no wake model for “\(settings.voice.wakePhrase)” yet."
        }
        if problem != state.wakeProblem { state.wakeProblem = problem }
    }

    private func restartWake() {
        if runningWake != nil { wake?.stop() }
        runningWake = nil
        refreshWake()
    }

    /// The brain settings with the workspace resolved: the home folder while none is chosen.
    var resolvedBrain: BrainSettings {
        var brain = settings.brain
        if brain.workspacePath.trimmingCharacters(in: .whitespaces).isEmpty {
            brain.workspacePath = homeDirectory.path
        }
        return brain
    }

    /// MacHUD's tools go to the brain: the setting is on and `machud-mcp` was found.
    private var givesMacHUDTools: Bool { settings.machudTools && machudTools != nil }

    private func refreshBrain() {
        let resolved = resolvedBrain
        runtimeProblem = brainEnabled
            ? BrainRuntimes.problem(runtime: resolved.runtime.rawValue, brain: resolved,
                                    detections: detectRuntimes(resolved))
            : nil
        var wanted: BrainServiceConfiguration?
        if brainEnabled {
            var configuration = resolved.serviceConfiguration(
                stateDirectory: BrainServiceConfiguration.stateDirectory(
                    forWorkspace: resolved.workspacePath, under: brainStateRoot).path,
                port: settings.brainPort)
            if givesMacHUDTools, let machudTools {
                // The first start waits for MacHUD's description, so it does not start twice.
                guard let hostContext else { return loadHostContext() }
                configuration.toolServers = [machudTools.toolServer(requireApproval: settings.machudToolsRequireApproval)]
                configuration.hostContext = hostContext
            }
            wanted = configuration
        }
        guard let brain, appliedBrain != .some(wanted) else { return }
        appliedBrain = .some(wanted)
        brain.configure(wanted)
        // Turned off: the companion's turn ends with its process. (A restart reports through
        // `onStopped`.)
        if wanted == nil { brainLost() }
    }

    /// Reads MacHUD's apps and loadouts and rebuilds the host context; the brain follows if it
    /// changed. Nothing is read while MacHUD's tools are not given; a read already running is
    /// left to finish.
    private func loadHostContext() {
        guard brainEnabled, givesMacHUDTools, hostContextLoad == nil else { return }
        let status = machudStatus
        hostContextLoad = Task { [weak self] in
            let snapshot = await status?.snapshot()
            guard let self else { return }
            hostContextLoad = nil
            let context = MacHUDHostContext.build(snapshot: snapshot)
            guard context != hostContext else { return }
            hostContext = context
            refreshBrain()
        }
    }

    /// The tool servers the connected companion reports (whether its runtime gives them to the
    /// agent, or why not); nil while none is connected.
    var brainToolServers: AgentToolServerStatus? { lastSnapshot?.toolServers }

    // MARK: - Brain problem

    /// What `brain status` reports about each runtime, for the current settings.
    func runtimeDetections() -> [BrainRuntimeDetection] { detectRuntimes(resolvedBrain) }

    /// Re-reads the chosen runtime's tool (after an install) and updates the problem.
    func refreshRuntimeDetection() {
        refreshBrain()
        refreshBrainProblem()
    }

    /// A problem the user has to fix before a turn can go to the brain.
    private var blockingBrainProblem: String? {
        guard brainEnabled else { return nil }
        switch brainHealth {
        case .unavailable(let reason): return reason
        case .failed: return Self.problem(for: brainHealth)
        default: return runtimeProblem
        }
    }

    private func refreshBrainProblem() {
        let problem: String?
        if brain == nil {
            problem = Self.brainOff
        } else if !settings.enabled {
            problem = Self.voiceOff
        } else if !settings.brainEnabled {
            problem = Self.brainOff
        } else {
            problem = blockingBrainProblem ?? Self.problem(for: brainHealth)
        }
        var next = state
        next.brainProblem = problem
        next.brainAvailable = problem == nil
        state = next
    }

    /// The companion's own state in words; nil when it is ready.
    static func problem(for health: BrainHealth) -> String? {
        switch health {
        case .ready: return nil
        case .stopped, .starting: return brainStarting
        case .connecting: return brainConnecting
        case .unavailable(let reason): return reason
        case .restarting(let reason): return "The brain is restarting: \(reason)"
        case .failed(let reason): return "The brain stopped after repeated failures: \(reason)"
        }
    }

    static func pasted(_ problem: String) -> String {
        let reason = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
        return "\(reason) — pasted instead"
    }

    // MARK: - Sessions

    private func setSessionKey(_ key: String?) {
        guard key != state.sessionKey else { return }
        state.sessionKey = key
        guard key != nil, state.sessionProvider == nil, let sessions else { return }
        providerLookup = Task { [weak self] in
            let name = await sessions.providerName()
            guard let self, let name, state.sessionKey != nil else { return }
            state.sessionProvider = name
        }
    }

    private func openSession() {
        pendingWork = Task { [weak self] in
            _ = await self?.openSessionNow()
        }
    }

    /// Asks MacHUD to show the current session; a failure shows under the orb. Returns the
    /// provider's name, or why it could not open.
    func openSessionNow() async -> Result<String, SessionOpenError> {
        guard let key = state.sessionKey, let sessions else {
            let error = SessionOpenError(message: Self.noSession)
            showNotice(error.message)
            return .failure(error)
        }
        let result = await sessions.open(id: key)
        switch result {
        case .success(let app): state.sessionProvider = app
        case .failure(let error): showNotice(error.message)
        }
        return result
    }

    /// A message under the orb that leaves a take or a turn alone: while one runs, the phase
    /// belongs to it, so the message goes on the card's progress lines instead.
    private func showNotice(_ message: String) {
        if take == nil, !agentBusy, !isSpeaking {
            fail(message)
        } else if state.card != nil {
            state.card?.progress = Array(((state.card?.progress ?? []) + [message]).suffix(Self.progressLimit))
        }
    }
}
