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
/// ends on a click, `stop`, or a `SilenceEndpointer` built from `handsFree`; why each such take
/// ended is kept in `lastTakeEnd`. An agent take's text becomes a brain
/// turn whose snapshots fill the card and, with `voice.speakReplies`, are spoken as they stream.
///
/// Every take carries what started it (`VoiceTakeTrigger`). Its start, its end and what became of
/// it are logged (`log`), and its record, never its words, goes to `takeJournal` once its outcome
/// is known; so does a take refused before it recorded, a wake detection that started none
/// included.
///
/// One turn at a time: the companion refuses a second one, so while the brain works an agent
/// take is refused, and a take moved to the agent then (or while the brain is off) is typed at
/// the cursor instead, unless the wake word started it: that one is dropped, typed nowhere. A
/// typed turn (`send(typed:)`) goes to the same session and is refused the same way, with the
/// reason returned to the sender rather than shown under the orb.
///
/// Every turn, spoken or typed, and every snapshot also go to `conversation`, which the
/// presenter draws when the card is pinned or expanded (`state.cardMode`) and which is kept in
/// `conversationStore` across restarts.
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
/// a model installed later arms it at once (`wakeModelsChanged`). A listener that stops by
/// itself is started again after `wakeRestartDelays` until it listens.
///
/// With `wakeConfirm` a detection starts nothing until `wakeConfirmer` has transcribed what woke
/// the listener and the phrase is in the words: the take then starts as any wake's does; a wake
/// whose phrase is not there leaves no trace but its journal line and log line.
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
    /// Draws the state and the conversation. Rendered once when set, then on every change.
    public var presenter: VoiceHostPresenting? {
        didSet {
            presenter?.render(state)
            presenter?.renderConversation(conversation.rows)
        }
    }
    /// Every state change, after the presenter (the socket's `state` event).
    public var onStateChange: ((VoiceHostState) -> Void)?
    /// Where the take and wake-listener lines go (`TakeLog`, the unified log).
    var log: (String) -> Void = TakeLog.notice

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
    static let wakeDroppedBrainOff = "Heard you, but the brain is off"
    static let wakeDroppedBusy = "Heard you, but the agent is still working"
    static let voiceOff = "Voice is off"
    static let voiceMuted = "Voice is muted"
    static let wakeOff = "The wake word is off"
    static let otherWakePhrase = "Not the wake phrase listened for"
    static let staleWake = "From a wake listener stopped or replaced since"
    static let wakeBeingConfirmed = "Another wake is being confirmed"
    static let wakeNotConfirmed = "The wake phrase was not confirmed"
    static let wakeConfirmNoModel = "Download the speech model to confirm the wake phrase."
    static let wakeConfirmLoading = "The speech model was still loading, so the wake phrase could not be confirmed."
    static let wakeConfirmFailed = "The speech model could not check the wake phrase."
    static let wakeConfirmSlow = "Checking the wake phrase took longer than 1.5 s."
    static let wakeConfirmBusy =
        "The speech model was still transcribing the last take, so the wake phrase could not be confirmed."
    static let wakeConfirmUnavailable = "This voice host has no speech model to confirm the wake phrase with."
    static let wakeModelMissing = "The wake phrase's model is not installed"
    static let hostQuit = "The voice host quit"
    static let modelMissing = "Speech model not installed"
    static let brainStarting = "The brain is starting."
    static let brainConnecting = "Connecting to the brain…"
    static let noSession = "There is no agent session to open"
    static let takeRecording = "A take is recording"
    static let noSpeech = "Speech is not available"
    static let nothingHeard = "Didn't hear anything"
    static let wakeUnavailable = "The wake word needs the microphone, which this voice host does not use."
    static let nothingToSend = "There is nothing to send"
    /// How long a pinned card stays after the pointer leaves it.
    static let pinGrace: TimeInterval = 0.5
    /// How long after a change the conversation is saved (a finished turn is saved at once).
    static let conversationSaveDelay: TimeInterval = 1
    /// Progress lines kept on the card.
    static let progressLimit = 4
    /// How long a wake listener that stopped by itself waits before each restart: the first,
    /// the second, then every one after.
    static let wakeRestartDelays: [TimeInterval] = [2, 10, 60]
    /// After a wake that starts no take the listener drops this many seconds of what it hears, so
    /// the rest of the sound that woke it cannot wake it again.
    static let wakeQuietPeriod: TimeInterval = 1
    /// How long confirming a wake's phrase may take before the wake counts as not confirmed.
    static let wakeConfirmTimeout: TimeInterval = 1.5

    private let dictation: DictationDriving
    private let keys: VoiceKeySource?
    private let brain: BrainDriving?
    private let speaker: ReplySpeaking?
    private let wake: WakeDriving?
    /// The wake phrases there are models for, in the order they are offered.
    let wakeModels: [WakePhraseModel]
    /// Transcribes what woke the listener, to confirm the phrase; nil confirms none.
    private let wakeConfirmer: WakeConfirming?
    private let brainStateRoot: URL
    /// Where the conversation is kept between launches; nil keeps it only in memory.
    private let conversationStore: ConversationStoring?
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
    private let wallClock: () -> Date
    private let schedule: VoiceScheduler
    /// Where each take's record goes; nil keeps none (`takes` then says so).
    let takeJournal: TakeJournaling?

    private struct Take {
        /// Nil until the session names the take (its first update or `start`'s outcome).
        var id: UUID?
        var mode: VoiceMode
        /// Started by the orb, the wake word or the socket's `ask`: ends on a tap or the endpointer.
        var handsFree = false
        /// Hands-free takes only, until it ends the take.
        var endpointer: SilenceEndpointer?
        var startedAt: TimeInterval = 0
        /// When it started, for the journal and the conversation.
        var date: Date
        /// What started it; an fn gesture that moves the take marks it retargeted.
        var trigger: VoiceTakeTrigger
        /// How it ended, once it has; the first reason given is the one kept.
        var end: VoiceTakeEnd?
        /// The take was kept at the cursor instead of going to the agent; shown when it ends.
        var pastedNotice: String?

        /// Started by the fn key: a change to the key setup ends it.
        var fromKeys: Bool {
            if case .key = trigger { return true }
            return false
        }

        /// Started by the wake word: when the brain cannot take it, it is dropped, not typed.
        var fromWake: Bool {
            if case .wake = trigger { return true }
            return false
        }
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
    /// Takes that stopped recording and are being transcribed, by id, until their outcome.
    private var transcribing: [UUID: Take] = [:]
    private var gesture: Gesture?
    /// The most recent take; only its outcome moves the phase.
    private var latestTakeID: UUID?
    private var turn: Turn?
    /// A turn submitted and not yet accepted.
    private var submitting: String?
    /// A spoken turn's record, written once the brain answers its submission (`requestId`).
    private var submission: (requestId: String, record: VoiceTakeRecord)?
    /// `prepareToQuit` journaled what was in flight; nothing more is written.
    private var quitting = false
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
    /// What the orb says when the cancelled take's dictation reports its end (`nothingHeard`).
    private var cancelNotice: String?
    private var started = false
    private var brainHealth: BrainHealth = .stopped
    /// The chosen runtime's problem on this Mac, for the settings last applied.
    private var runtimeProblem: String?
    /// Why the wake listener stopped by itself. Kept until it listens again, across a restart
    /// with the same voice settings (a take ended, voice unmuted); new voice settings clear it.
    private var wakeListenerProblem: String?
    /// The backoff's step: restarts since the listener last stayed up for the longest delay.
    private var wakeRestarts = 0
    /// The pending restart; an earlier one that fires finds it changed and does nothing.
    private var wakeRestartToken: UUID?
    /// When the listener began listening (uptime), until it fails or is started or stopped.
    private var wakeListeningSince: TimeInterval?
    /// The failures since the listener last listened: the reason last logged and how many
    /// restarts they have taken. A failure is logged when the run begins or its reason changes.
    private var wakeFailureRun: (reason: String, attempts: Int)?
    /// The listener failed in a way starting it again cannot fix (`WakeFailure.retryable` false):
    /// it waits for a change to its model or to the voice settings.
    private var wakeWaitsForChange = false
    /// Counts the listener's starts and stops: a wake re-arms the listener only if it is still
    /// the run the wake came from.
    private var wakeRun = 0
    /// The listener was re-armed after a wake; its listening again continues the same run.
    private var wakeRearming = false

    /// A wake whose phrase is being confirmed: its trigger, the phrase to find, when it came and
    /// the listener run it came from. Never its audio.
    private struct WakeConfirmation {
        let id = UUID()
        let trigger: VoiceTakeTrigger
        let phrase: String
        let startedAt: TimeInterval
        let run: Int
    }

    private var wakeConfirmation: WakeConfirmation? {
        didSet { if wakeConfirmation == nil { wakeAudioWaiting = nil } }
    }
    /// The audio of the wake being confirmed while it waits for a take's transcription to end;
    /// let go once it goes to the speech model or the wake is decided.
    private var wakeAudioWaiting: [Float]?
    /// Why the latest wake's phrase could not be confirmed; `wakeProblem` while nothing else is,
    /// until a wake's words are had, confirmation is turned off or the voice settings change.
    private var wakeConfirmProblem: String?
    /// The conversation with the agent, every turn and snapshot reduced to rows.
    private(set) var conversation: ConversationLog
    private var conversationSaveScheduled = false
    /// The pointer is over the card.
    private var cardHovered = false
    /// The latest pending unpin; an earlier one that fires finds it changed and does nothing.
    private var unpinToken = UUID()

    /// - Parameters:
    ///   - keys: nil without an fn event tap (`MACHUD_NO_HOTKEYS`).
    ///   - brain: nil when the brain can never run (`MACHUD_VOICE_NO_BRAIN`).
    ///   - wake: nil without a microphone for it.
    ///   - wakeModels: the wake phrases there are models for, and their files.
    ///   - wakeConfirmer: transcribes what woke the listener, to confirm the phrase.
    ///   - brainStateRoot: the folder per-workspace brain state directories go under.
    ///   - conversationStore: where the conversation is kept; nil keeps it in memory only.
    ///   - sessions: MacHUD's session broker; nil leaves `openSession` unavailable.
    ///   - feed: MacHUD's text-feed broker; nil sends nothing.
    ///   - machudTools: MacHUD's tool server, given to the brain while `machudTools` is on.
    ///   - machudStatus: MacHUD's apps and loadouts, described to the brain with the tools.
    ///   - detectRuntimes: which runtimes are installed, for the settings given.
    ///   - sessionKeyOf: a snapshot's session key.
    ///   - homeDirectory: the brain's workspace while `brain.workspacePath` is empty.
    init(settings: VoiceHostSettings, dictation: DictationDriving, keys: VoiceKeySource?,
         brain: BrainDriving?, speaker: ReplySpeaking?, wake: WakeDriving?, wakeModels: [WakePhraseModel] = [],
         wakeConfirmer: WakeConfirming? = nil, brainStateRoot: URL, conversationStore: ConversationStoring? = nil,
         sessions: SessionOpening? = nil, feed: TextFeeding? = nil,
         machudTools: MacHUDToolServer? = nil, machudStatus: MacHUDStatusReading? = nil,
         detectRuntimes: @escaping (BrainSettings) -> [BrainRuntimeDetection] = { BrainRuntimes.detect($0) },
         sessionKeyOf: @escaping (AgentSessionSnapshot) -> String? = { $0.sessionKey },
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> Date = Date.init,
         schedule: @escaping VoiceScheduler = mainQueueScheduler,
         takeJournal: TakeJournaling? = nil) {
        self.settings = settings.resolvingWakePhrase(available: wakeModels.map(\.phrase))
        self.dictation = dictation
        self.keys = keys
        self.brain = brain
        self.speaker = speaker
        self.wake = wake
        self.wakeModels = wakeModels
        self.wakeConfirmer = wakeConfirmer
        self.brainStateRoot = brainStateRoot
        self.conversationStore = conversationStore
        conversation = ConversationLog(record: conversationStore?.load())
        // The last exchange is there to peek at by hovering the orb, as before the restart.
        state.card = conversation.latestCard
        self.sessions = sessions
        self.feed = feed
        self.machudTools = machudTools
        self.machudStatus = machudStatus
        self.detectRuntimes = detectRuntimes
        self.sessionKeyOf = sessionKeyOf
        self.homeDirectory = homeDirectory
        self.now = now
        self.wallClock = wallClock
        self.schedule = schedule
        self.takeJournal = takeJournal
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
            // A restart describes MacHUD as it is now; a changed description restarts it once more.
            self?.loadHostContext()
        }
        speaker?.onFinished = { [weak self] in
            guard let self else { return }
            revealWholeReply()
            guard state.phase == .speaking else { return }
            state.phase = .idle
        }
        speaker?.onChunkStarted = { [weak self] chunk in self?.chunkStarted(chunk) }
        wake?.onWake = { [weak self] in self?.wakeDetected($0, current: $1) }
        wake?.onListeningChanged = { [weak self] in self?.wakeListeningChanged($0) }
        wake?.onProblem = { [weak self] in self?.wakeListenerFailed($0) }
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
            // The wake listener starts afresh with them: what stopped it before is forgotten.
            wakeListenerProblem = nil
            wakeConfirmProblem = nil
            wakeRestarts = 0
        }
        if !settings.wakeConfirm { wakeConfirmProblem = nil }
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
        // A model that would not load may load now.
        if wakeWaitsForChange, let wake, let settings = runningWake, take == nil {
            wakeWaitsForChange = false
            wakeFailureRun?.attempts += 1
            log("wake listener restarting: its model changed")
            startWake(wake, settings)
        }
        refreshWakeProblem()
    }

    /// The window that hid the orb for full screen, for `state`'s `orb`; nil while the orb is not
    /// hidden.
    private(set) var fullScreenEvidence: VoiceFullScreenEvidence?

    /// A full-screen app hides the orb and the card: an expanded or pinned card folds back to
    /// the peek, so it neither comes back over the screen nor takes the keyboard later.
    /// `evidence` is the window that made the orb's screen full screen; it is kept while hidden
    /// and given to the presenter before the state that hides the orb.
    func setHiddenForFullScreen(_ hidden: Bool, evidence: VoiceFullScreenEvidence? = nil) {
        fullScreenEvidence = hidden ? evidence : nil
        presenter?.renderFullScreenEvidence(fullScreenEvidence)
        var next = state
        next.hiddenForFullScreen = hidden
        if hidden { next.cardMode = .peek }
        state = next
    }

    // MARK: - Actions

    /// The orb's (the UI's) actions: a take one of them starts was started by the orb.
    public func perform(_ action: VoiceHostAction) {
        perform(action, trigger: .orb)
    }

    /// `trigger` is what started a take the action starts (the socket passes its action).
    func perform(_ action: VoiceHostAction, trigger: VoiceTakeTrigger) {
        switch action {
        case .orbClicked:
            if isSpeaking { return stopSpeech() }
            if take != nil { return stopTake() }
            switch state.phase {
            case .idle, .failed: startTake(.agent, handsFree: true, trigger: trigger)
            default: break
            }
        case .start(let mode):
            startTake(mode, handsFree: mode == .agent, trigger: trigger)
        case .stop:
            if take != nil { stopTake() } else if isSpeaking { stopSpeech() }
        case .cancel:
            cancel()
        case .approve(let id):
            answer(id, allow: true)
        case .deny(let id):
            answer(id, allow: false)
        case .dismissCard:
            stopSpeech()
            turn?.cardDismissed = true
            var next = state
            next.card = nil
            next.cardMode = .peek
            state = next
        case .setMuted(let muted):
            state.muted = muted
            if muted {
                stopSpeech()
                silenceTurn()
                cancelTake()
            }
            refreshKeys()
            refreshWake()
        case .openSession:
            openSession()
        case .cardHovered(let hovering):
            cardHoverChanged(hovering)
        case .cardClicked:
            state.cardMode = .expanded
        case .setCardMode(let mode):
            state.cardMode = mode
        }
    }

    /// Why the socket's `action name=` (`ask` or `dictate`) would not start a take, journaled as
    /// refused like any other take that never recorded; nil when it may.
    func socketRefusal(for mode: VoiceMode, action: String) -> String? {
        let refusal = !settings.enabled ? Self.voiceOff : state.muted ? Self.voiceMuted : nil
        if let refusal { refused(.socket(action: action), mode: mode, reason: refusal) }
        return refusal
    }

    /// The host is quitting: every take still in flight (recording, being transcribed, or sent
    /// and not yet taken by the brain) is journaled as cancelled because of it, and nothing is
    /// journaled after.
    func prepareToQuit() {
        guard !quitting else { return }
        if let pending = wakeConfirmation {
            wakeConfirmation = nil
            refused(pending.trigger, mode: .agent, reason: Self.hostQuit)
        }
        reportTakeEnd(.cancelled)
        if let current = take { journal(current, outcome: .cancelled, reason: Self.hostQuit) }
        for ended in transcribing.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            journal(ended, outcome: .cancelled, reason: Self.hostQuit)
        }
        if var waiting = submission?.record {
            waiting.outcome = .cancelled
            waiting.reason = Self.hostQuit
            write(waiting)
        }
        submission = nil
        quitting = true
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
        // The preview replaces the reply's voice: the reply is not spoken, and shows whole.
        silenceTurn()
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
        reportTakeEnd(.cancelled)
        dictation.cancel()
        if let current = take {
            // The session reported nothing (no take was capturing after all).
            take = nil
            journal(current, outcome: Self.thrownAway(current))
            refreshWake()
            settle(.idle)
        }
    }

    /// The brain went away (stopped, restarted, or a cancel failed): no snapshot will end the
    /// turn, so it ends here.
    private func brainLost() {
        lastSnapshot = nil
        if state.activeRuntime != nil { state.activeRuntime = nil }
        if submitting != nil {
            conversation.refused()
            conversationChanged()
        }
        submitting = nil
        setSessionKey(nil)
        guard turn != nil else { return }
        turn = nil
        speaker?.stop()
        revealWholeReply()
        if take == nil, [.working, .awaitingApproval, .speaking].contains(state.phase) { settle(.idle) }
    }

    // MARK: - Takes

    /// The brain runs only while voice is on; `enabled` off leaves the host idle.
    private var brainEnabled: Bool { settings.enabled && settings.brainEnabled && brain != nil }

    /// A turn is submitted, running or waiting on an approval (ours or another client's).
    private var agentBusy: Bool {
        turn != nil || submitting != nil || lastSnapshot?.isWorking == true
    }

    /// A refused take is journaled, and shown on the orb unless a take is already recording.
    private func startTake(_ mode: VoiceMode, handsFree: Bool, trigger: VoiceTakeTrigger) {
        stopSpeech()
        // A reply still streaming is never spoken into the open microphone.
        silenceTurn()
        if let refusal = startRefusal(mode) {
            refused(trigger, mode: mode, reason: refusal)
            return fail(refusal)
        }
        guard take == nil, !dictation.isCapturing else {
            return refused(trigger, mode: mode, reason: Self.takeRecording)
        }
        take = Take(id: nil, mode: mode, handsFree: handsFree,
                    endpointer: handsFree ? SilenceEndpointer(settings: settings.handsFree) : nil,
                    startedAt: now(), date: wallClock(), trigger: trigger)
        refreshWake()
        switch dictation.start(mode == .agent ? .caller : .cursor) {
        case .started(let id), .resumed(let id):
            if take != nil, take?.id == nil { take?.id = id }
            latestTakeID = id
            log("take started: \(trigger.summary), \(mode.rawValue), \(handsFree ? "hands-free" : "held")")
        case .refused(let failure), .failed(let failure):
            // `.failed` was reported through `onUpdate` too; only a refusal still holds the take.
            guard let current = take, current.id == nil else { return }
            take = nil
            journal(current, outcome: .refused, reason: Self.message(for: failure) ?? failure.message)
            refreshWake()
            if let message = Self.message(for: failure) { fail(message) } else { settle(.idle) }
        }
    }

    /// Why a take for `mode` cannot start now, or nil.
    private func startRefusal(_ mode: VoiceMode) -> String? {
        if !settings.enabled { return Self.voiceOff }
        guard mode == .agent else { return nil }
        if !brainEnabled { return Self.brainOff }
        if let problem = blockingBrainProblem { return problem }
        if agentBusy { return Self.agentBusy }
        return nil
    }

    /// A detection starts an agent take once its phrase is confirmed (`confirmWake`), or at once
    /// with confirmation off. One that arrives after the listener was told to stop (no listener is
    /// wanted: voice off, muted, the wake word off, a take recording), from a listener stopped or
    /// replaced since, or not of the phrase listened for is refused before anything else: it is
    /// journaled and logged and touches nothing, not the reply's speech, the orb or the listener
    /// running now. Its audio is not kept.
    ///
    /// The listener makes one detection per arm and a wake being confirmed is decided whenever its
    /// listener stops or is replaced (`refusePendingWake`), so a detection from the listener running
    /// now never meets another being confirmed; if one did, it is refused and the listener re-armed.
    private func wakeDetected(_ detection: WakeDetection, current: Bool) {
        let trigger = VoiceTakeTrigger(detection)
        guard let listening = runningWake else {
            return refused(trigger, mode: .agent, reason: wakeStopReason)
        }
        guard current else { return refused(trigger, mode: .agent, reason: Self.staleWake) }
        guard TriggerPhrase.normalize(detection.phrase) == TriggerPhrase.normalize(listening.wakePhrase) else {
            return refused(trigger, mode: .agent, reason: Self.otherWakePhrase)
        }
        guard wakeConfirmation == nil else {
            refused(trigger, mode: .agent, reason: Self.wakeBeingConfirmed)
            return rearmWake()
        }
        guard settings.wakeConfirm else { return startWakeTake(trigger, run: wakeRun) }
        confirmWake(detection, trigger: trigger)
    }

    /// A wake that may start a take starts it as any take starts, refusals included; with no take
    /// to pause it, the listener it came from listens again.
    private func startWakeTake(_ trigger: VoiceTakeTrigger, run: Int) {
        startTake(.agent, handsFree: true, trigger: trigger)
        if take == nil, wakeRun == run { rearmWake() }
    }

    /// Hands what woke the listener to the speech model and waits, at most `wakeConfirmTimeout`,
    /// for its words. Until they come nothing is shown, stopped, said or written; the listener
    /// stays quiet meanwhile. The audio goes to `wakeConfirmer` and nowhere else.
    ///
    /// The speech model transcribes one thing at a time, as SpeakFree uses it (its engine is not
    /// made to run two at once): while a take is being transcribed the wake waits for it, within
    /// the same time limit (`confirmWaitingWake`).
    private func confirmWake(_ detection: WakeDetection, trigger: VoiceTakeTrigger) {
        let pending = WakeConfirmation(trigger: trigger, phrase: detection.phrase, startedAt: now(), run: wakeRun)
        wakeConfirmation = pending
        schedule(Self.wakeConfirmTimeout) { [weak self] in
            guard let self else { return }
            wakeChecked(pending.id, .cannot(wakeAudioWaiting == nil ? Self.wakeConfirmSlow : Self.wakeConfirmBusy))
        }
        guard transcribing.isEmpty else {
            wakeAudioWaiting = detection.audio
            return
        }
        transcribeWake(detection.audio, pending)
    }

    /// The take that was being transcribed is done: the wake waiting for it goes to the speech model.
    private func confirmWaitingWake() {
        guard transcribing.isEmpty, let audio = wakeAudioWaiting, let pending = wakeConfirmation else { return }
        wakeAudioWaiting = nil
        transcribeWake(audio, pending)
    }

    private func transcribeWake(_ audio: [Float], _ pending: WakeConfirmation) {
        guard let wakeConfirmer else { return wakeChecked(pending.id, .cannot(Self.wakeConfirmUnavailable)) }
        wakeConfirmer.transcribe(audio) { [weak self] result in
            switch result {
            case .success(let words): self?.wakeChecked(pending.id, .heard(words))
            case .failure(let failure): self?.wakeChecked(pending.id, .cannot(Self.message(for: failure)))
            }
        }
    }

    private enum WakeCheck {
        /// What the speech model heard.
        case heard(String)
        /// Why it could not say.
        case cannot(String)
    }

    /// The first answer for the wake being confirmed, the time running out included; a later one,
    /// or one for a wake already refused because its listener stopped, finds it gone. The words
    /// decide and go no further. A wake whose phrase is not in them, or that could not be checked,
    /// is refused and its listener re-armed.
    private func wakeChecked(_ id: UUID, _ check: WakeCheck) {
        guard let pending = wakeConfirmation, pending.id == id else { return }
        wakeConfirmation = nil
        let confirmed: Bool
        let refusal: String
        let problem: String?
        switch check {
        case .heard(let words):
            confirmed = TriggerPhrase.transcript(words, contains: pending.phrase)
            refusal = Self.wakeNotConfirmed
            problem = nil
        case .cannot(let why):
            confirmed = false
            refusal = why
            problem = why
        }
        let trigger = pending.trigger.confirming(confirmed, ms: Int(((now() - pending.startedAt) * 1000).rounded()))
        // Unreachable while every stop of the listener decides its wake; kept so an answer for an
        // older listener can never act, or show a problem new settings cleared.
        guard pending.run == wakeRun, runningWake != nil else {
            return refused(trigger, mode: .agent, reason: runningWake == nil ? wakeStopReason : Self.staleWake)
        }
        wakeConfirmProblem = problem
        refreshWakeProblem()
        guard confirmed else {
            refused(trigger, mode: .agent, reason: refusal)
            return rearmWake()
        }
        startWakeTake(trigger, run: pending.run)
    }

    /// The listener the wake being confirmed came from stops or is replaced: the wake is refused
    /// now, with no answer, so the next detection, from the listener started again, is heard.
    private func refusePendingWake(_ reason: String) {
        guard let pending = wakeConfirmation else { return }
        wakeConfirmation = nil
        refused(pending.trigger, mode: .agent, reason: reason)
    }

    static func message(for failure: WakeConfirmFailure) -> String {
        switch failure {
        case .noModel: wakeConfirmNoModel
        case .loading: wakeConfirmLoading
        case .failed: wakeConfirmFailed
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
            startTake(.dictation, handsFree: false, trigger: .key(.primary, retargeted: false))
            if take == nil { endGesture() }
        case .begin(.alternate): startTake(.agent, handsFree: false, trigger: .key(.alternate, retargeted: false))
        case .retarget(.alternate):
            markRetargeted()
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
        case .retarget(.primary):
            markRetargeted()
            dictation.retarget(.cursor)
        case .end: if take != nil { stopTake() }
        case .discard: dictation.cancel()
        }
    }

    /// A later fn gesture moved the take (or asked to; the brain may have kept it at the cursor).
    private func markRetargeted() {
        guard let trigger = take?.trigger else { return }
        take?.trigger = trigger.retargeted
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
        // A take's transcription that ended may let a wake waiting for it be confirmed.
        defer { confirmWaitingWake() }
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
            // A non-finite level is ignored and the previous one stands: in the state it would
            // make `state` unencodable, and in the endpointer it would poison the noise floor.
            guard isCurrent, level.isFinite else { return }
            state.inputLevel = level
            switch take?.endpointer?.observe(level: level, at: now()) {
            case .pause?: endTake(.pause)
            case .maximum?: endTake(.maximum)
            case .nothingHeard?:
                // Nothing to send: the take is thrown away and the orb says so.
                reportTakeEnd(.nothingHeard)
                cancelNotice = Self.nothingHeard
                cancelTake()
                if cancelNotice != nil { fail(Self.nothingHeard) }
            case nil: break
            }
        case .partial(let text):
            guard isCurrent else { return }
            state.partialTranscript = text
            take?.endpointer?.observe(partial: text, at: now())
        case .transcribing:
            guard isCurrent else { return }
            reportTakeEnd(.dictation)
            guard let current = take else { return }
            // Kept, with its notice, until its outcome.
            transcribing[id] = current
            take = nil
            var next = state
            next.phase = .transcribing(current.mode)
            next.inputLevel = 0
            state = next
            refreshWake()
        case .finished(let text, let destination, let transcript):
            if isCurrent { reportTakeEnd(.dictation) }
            let ended = isCurrent ? take : transcribing.removeValue(forKey: id)
            let notice = ended?.pastedNotice
            endCapture(ifCurrent: isCurrent)
            if settings.feedTranscripts { sendToFeed(transcript, source: Self.dictationSource) }
            if destination == .caller {
                submit(text, isLatest: isLatest, ended: ended)
            } else {
                if let ended {
                    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : text.count
                    journal(ended, mode: .dictation, outcome: typed == nil ? .nothingHeard : .typed,
                            reason: notice, characters: typed)
                }
                if isLatest { if let notice { fail(notice) } else { settle(.idle) } }
            }
        case .failed(let failure):
            let notice = failure == .cancelled ? cancelNotice : nil
            cancelNotice = nil
            if isCurrent { reportTakeEnd(failure == .cancelled ? .cancelled : .failed) }
            if let ended = isCurrent ? take : transcribing.removeValue(forKey: id) {
                if failure == .cancelled {
                    journal(ended, outcome: Self.thrownAway(ended))
                } else {
                    journal(ended, outcome: .failed, reason: Self.message(for: failure) ?? failure.message)
                }
            }
            endCapture(ifCurrent: isCurrent)
            guard isLatest else { return }
            if let message = Self.message(for: failure) ?? notice { fail(message) } else { settle(.idle) }
        }
    }

    /// A tap ends the take: the orb, the fn key or `stop`.
    private func stopTake() {
        endTake(.stop)
    }

    /// Ends the take and sends it on to be transcribed.
    private func endTake(_ reason: VoiceTakeEnd.Reason) {
        reportTakeEnd(reason)
        take?.endpointer = nil
        dictation.stop()
    }

    /// Records why the current take ended, in the take and the log, and for a hands-free take in
    /// `lastTakeEnd`; the first reason given for a take is the one kept.
    private func reportTakeEnd(_ reason: VoiceTakeEnd.Reason) {
        guard let current = take, current.end == nil else { return }
        let time = now()
        var end = VoiceTakeEnd(reason: reason, seconds: max(time - current.startedAt, 0), trigger: current.trigger)
        if let endpointer = current.endpointer {
            end.quietMs = endpointer.quiet(at: time).map { Int(($0 * 1000).rounded()) }
            if endpointer.heardLevels {
                end.floor = endpointer.floor
                end.threshold = endpointer.threshold
            }
            if endpointer.automatic {
                end.pause = endpointer.requiredPause(at: time)
                end.grace = endpointer.unfinished(at: time)
            }
        }
        take?.end = end
        log("take ended: \(end.summary)")
        if current.handsFree { state.lastTakeEnd = end }
    }

    /// A cancelled take was thrown away by the endpointer (nothing heard) or by the user.
    private static func thrownAway(_ take: Take) -> VoiceTakeRecord.Outcome {
        take.end?.reason == .nothingHeard ? .nothingHeard : .cancelled
    }

    /// The journal's record of `take` with this outcome; `mode` where the words went, if known.
    private func record(_ take: Take, mode: VoiceMode? = nil, outcome: VoiceTakeRecord.Outcome,
                        reason: String? = nil, characters: Int? = nil) -> VoiceTakeRecord {
        VoiceTakeRecord(date: VoiceTakeRecord.timestamp(take.date), trigger: take.trigger, mode: mode ?? take.mode,
                        seconds: take.end?.seconds, end: take.end?.reason, outcome: outcome, reason: reason,
                        characters: characters)
    }

    /// What became of `take`, to the journal and the log.
    private func journal(_ take: Take, mode: VoiceMode? = nil, outcome: VoiceTakeRecord.Outcome,
                         reason: String? = nil, characters: Int? = nil) {
        write(record(take, mode: mode, outcome: outcome, reason: reason, characters: characters))
    }

    /// A take that never recorded: refused by the host (the socket's own refusals included), or
    /// a wake detection that started none.
    func refused(_ trigger: VoiceTakeTrigger, mode: VoiceMode, reason: String) {
        write(VoiceTakeRecord(date: VoiceTakeRecord.timestamp(wallClock()), trigger: trigger, mode: mode,
                              outcome: .refused, reason: reason))
    }

    private func write(_ record: VoiceTakeRecord) {
        guard !quitting else { return }
        takeJournal?.append(record)
        log("take \(record.summary)")
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

    /// An agent take's words: to the brain, or, when it cannot take them now, typed at the cursor
    /// or dropped (`notTaken`). `ended` is the take they came from, for the journal.
    private func submit(_ text: String, isLatest: Bool, ended: Take?) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            if let ended { journal(ended, mode: .agent, outcome: .nothingHeard) }
            if isLatest { settle(.idle) }
            return
        }
        // The brain went off, or another turn started, while this take was recording.
        guard brainEnabled, let brain else {
            return notTaken(prompt, pasted: Self.brainOffPasted, dropped: Self.wakeDroppedBrainOff, isLatest: isLatest,
                            ended: ended)
        }
        if let problem = blockingBrainProblem {
            return notTaken(prompt, pasted: Self.pasted(problem), dropped: Self.wakeDropped(problem), isLatest: isLatest,
                            ended: ended)
        }
        guard !agentBusy else {
            return notTaken(prompt, pasted: Self.agentBusyPasted, dropped: Self.wakeDroppedBusy, isLatest: isLatest,
                            ended: ended)
        }
        begin(prompt, source: .voice, isLatest: isLatest, brain: brain, ended: ended)
    }

    /// Words the brain cannot take now. The wake word's are dropped: whoever spoke may not have
    /// been talking to this Mac, so they are typed nowhere. The fn key's, the orb's and the
    /// socket's are typed at the cursor, where the user is. A take the host has no record of is
    /// dropped too, since it may have been the wake word's (and has no journal line to write). The
    /// notice shows on the orb only for the latest take; a newer one recording or being
    /// transcribed keeps the orb.
    private func notTaken(_ text: String, pasted: String, dropped: String, isLatest: Bool, ended: Take?) {
        if let ended, !ended.fromWake { return paste(text, notice: pasted, isLatest: isLatest, ended: ended) }
        if let ended {
            journal(ended, mode: .agent, outcome: .dropped, reason: dropped, characters: text.count)
        } else {
            log("take dropped (\(dropped)), \(text.count) characters: a take this host has no record of")
        }
        if isLatest { fail(dropped) }
    }

    /// Sends `text` to the agent as a typed turn, to the same session as voice. Nil once it is
    /// on its way (a refusal by the brain then shows under the orb, as for a spoken turn), else
    /// why it was not sent: nothing to send, the brain is off or cannot take a turn, an agent
    /// take is recording, or the agent is still working.
    public func send(typed text: String) -> String? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return Self.nothingToSend }
        if !settings.enabled { return Self.voiceOff }
        guard brainEnabled, let brain else { return Self.brainOff }
        if let problem = blockingBrainProblem { return problem }
        if take?.mode == .agent { return Self.takeRecording }
        if agentBusy { return Self.agentBusy }
        begin(prompt, source: .typed, isLatest: true, brain: brain, ended: nil)
        return nil
    }

    /// Submits `prompt`; the conversation shows it at once, the card and the turn once the
    /// brain takes it. A spoken one's take (`ended`) is journaled once the brain has answered.
    private func begin(_ prompt: String, source: ConversationSource, isLatest: Bool, brain: BrainDriving,
                       ended: Take?) {
        stopSpeech()
        // The voice loads while the brain thinks, so the first words come sooner.
        if repliesSpoken(source) { speaker?.warmUp() }
        let requestId = UUID().uuidString
        submitting = requestId
        conversation.submitted(prompt, source: source, date: VoiceTakeRecord.timestamp(ended?.date ?? wallClock()),
                               trigger: ended?.trigger)
        conversationChanged()
        if let ended {
            submission = (requestId, record(ended, mode: .agent, outcome: .sent, characters: prompt.count))
        }
        pendingWork = Task { [weak self] in
            do {
                try await brain.submit(prompt, requestId: requestId)
                self?.submissionAnswered(requestId, refusal: nil)
                self?.accepted(prompt, requestId: requestId, source: source, isLatest: isLatest)
            } catch {
                self?.submissionAnswered(requestId, refusal: error)
                guard let self, submitting == requestId else { return }
                submitting = nil
                conversation.refused()
                conversationChanged()
                // A brain that is not up says why better than the client's error does.
                fail(state.brainAvailable ? error.localizedDescription : state.brainProblem ?? error.localizedDescription)
            }
        }
    }

    /// The brain answered a spoken turn's submission: journaled as sent, or as refused with a
    /// fixed reason and the companion's status code (its own words stay out of the journal and
    /// the log; the orb still shows them).
    private func submissionAnswered(_ requestId: String, refusal error: Error?) {
        guard var record = submission?.record, submission?.requestId == requestId else { return }
        submission = nil
        if let error {
            record.outcome = .refused
            record.reason = Self.brainRefused(error)
        }
        write(record)
    }

    static let brainDidNotTake = "The brain did not take the turn"

    /// `The brain did not take the turn (409)`; the code is the companion's status, or the
    /// error's domain and code.
    static func brainRefused(_ error: Error) -> String {
        if case AgentSessionError.server(let code, _) = error { return "\(brainDidNotTake) (\(code))" }
        let error = error as NSError
        return "\(brainDidNotTake) (\(error.domain) \(error.code))"
    }

    /// A reply to a turn from `source` is spoken: with `voice.speakReplies` for a spoken turn
    /// and `speakTypedReplies` for a typed one, never while muted or into a take recording.
    private func repliesSpoken(_ source: ConversationSource) -> Bool {
        let wanted = source == .typed ? settings.speakTypedReplies : settings.voice.speakReplies
        return wanted && !state.muted && take == nil
    }

    /// The brain took the turn: the card and the turn are ours from here. A reply that is
    /// spoken shows on the card in step with the voice (`VoiceCard.spokenUpTo`).
    private func accepted(_ prompt: String, requestId: String, source: ConversationSource, isLatest: Bool) {
        guard submitting == requestId else { return }
        submitting = nil
        conversation.accepted()
        conversationChanged()
        let speaks = repliesSpoken(source)
        turn = Turn(requestId: requestId, speaks: speaks)
        var next = state
        // A speaker that reports no chunks (a silent one) cannot pace the card.
        next.card = VoiceCard(prompt: prompt, spokenUpTo: speaks && speaker?.reportsChunks == true ? 0 : nil)
        if isLatest, take == nil {
            next.phase = .working
            next.inputLevel = 0
            next.partialTranscript = ""
        }
        state = next
        // A snapshot for this request may have arrived before the reply did.
        if let lastSnapshot, lastSnapshot.requestId == requestId { handle(lastSnapshot) }
    }

    private func paste(_ text: String, notice: String, isLatest: Bool, ended: Take) {
        dictation.insert(text)
        journal(ended, mode: .agent, outcome: .typed, reason: notice, characters: text.count)
        if isLatest { fail(notice) }
    }

    private func handle(_ snapshot: AgentSessionSnapshot) {
        lastSnapshot = snapshot
        let before = conversation
        let events = conversation.apply(snapshot)
        if conversation != before {
            // A finished turn, or a new conversation, is kept at once.
            let newConversation = before.threadID != nil && conversation.threadID != before.threadID
            conversationChanged(saveNow: events.contains(.turnEnded) || newConversation)
        }
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
            if next.phase != .speaking { next.card?.spokenUpTo = nil }
        case "interrupted":
            speaker?.stop()
            self.turn = nil
            next.phase = .idle
            next.card?.spokenUpTo = nil
        case "failed":
            speaker?.stop()
            self.turn = nil
            next.card?.spokenUpTo = nil
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
        conversation.markDecision(approvalID: id, allow: allow)
        conversationChanged()
        pendingWork = Task { [weak self] in
            do {
                try await brain.approve(id: id, allow: allow)
            } catch {
                guard let self else { return }
                conversation.decisionFailed(approvalID: id, message: error.localizedDescription)
                conversationChanged()
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Conversation

    /// The pointer over the card pins it; leaving unpins it after `pinGrace` unless it comes
    /// back. Only a peek pins, and only a pin unpins: an expanded card ignores hover.
    private func cardHoverChanged(_ hovering: Bool) {
        cardHovered = hovering
        let token = UUID()
        unpinToken = token
        if hovering {
            if state.cardMode == .peek { state.cardMode = .pinned }
            return
        }
        guard state.cardMode == .pinned else { return }
        schedule(Self.pinGrace) { [weak self] in
            guard let self, unpinToken == token, !cardHovered, state.cardMode == .pinned else { return }
            state.cardMode = .peek
        }
    }

    /// Draws the conversation and keeps it: at once with `saveNow`, else `conversationSaveDelay`
    /// after the first change since the last save (a streaming reply changes many times a second).
    private func conversationChanged(saveNow: Bool = false) {
        presenter?.renderConversation(conversation.rows)
        guard conversationStore != nil else { return }
        if saveNow { return saveConversation() }
        guard !conversationSaveScheduled else { return }
        conversationSaveScheduled = true
        schedule(Self.conversationSaveDelay) { [weak self] in
            guard let self, conversationSaveScheduled else { return }
            saveConversation()
        }
    }

    private func saveConversation() {
        conversationSaveScheduled = false
        conversationStore?.save(conversation.record)
    }

    /// Saves a change still waiting for its delay (the host is quitting).
    func flushConversation() {
        if conversationSaveScheduled { saveConversation() }
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
        silenceTurn()
        if state.phase == .speaking { state.phase = .idle }
    }

    /// The running turn's reply is not spoken from here on; the card shows all of it.
    private func silenceTurn() {
        turn?.speaks = false
        revealWholeReply()
    }

    /// A chunk of the reply started playing: the card shows the reply up to its end. Chunks
    /// only ever reveal more, and only while the card is paced (a preview's chunks are not).
    private func chunkStarted(_ chunk: SpeechChunk) {
        guard let shown = state.card?.spokenUpTo, chunk.rawRange.upperBound > shown else { return }
        state.card?.spokenUpTo = chunk.rawRange.upperBound
    }

    private func revealWholeReply() {
        if state.card?.spokenUpTo != nil { state.card?.spokenUpTo = nil }
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
    /// recording. Starting it afresh or stopping it ends any restart under way; the reason it last
    /// stopped and the backoff's step stay until it listens (or `apply` gets new voice settings).
    private func refreshWake() {
        defer { refreshWakeProblem() }
        guard let wake else { return }
        let wanted = wakeWanted && take == nil && wakeModel?.store.status.installed == true ? settings.voice : nil
        guard wanted != runningWake else { return }
        if runningWake != nil {
            refusePendingWake(wanted == nil ? wakeStopReason : Self.staleWake)
            wakeRun += 1
            wakeRearming = false
            wake.stop()
            log("wake listener stopped: \(wanted == nil ? wakeStopReason : "its settings changed")")
        }
        runningWake = wanted
        wakeRestartToken = nil
        wakeWaitsForChange = false
        wakeListeningSince = nil
        wakeFailureRun = nil
        guard let wanted else { return }
        log("wake listener starting: \"\(wanted.wakePhrase)\", threshold \(String(format: "%.2f", wanted.wakeThreshold)), "
            + "\(wanted.wakeFrames) frame\(wanted.wakeFrames == 1 ? "" : "s")")
        startWake(wake, wanted)
    }

    /// Every start of the listener begins a run of its own; a wake still being confirmed from an
    /// earlier one (a listener that failed meanwhile) is refused.
    private func startWake(_ wake: WakeDriving, _ settings: VoiceSettings) {
        refusePendingWake(Self.staleWake)
        wakeRun += 1
        wakeRearming = false
        wake.start(settings)
    }

    /// Why no wake listener is wanted now: for the log, and for a detection that arrives anyway.
    private var wakeStopReason: String {
        if !settings.enabled { return Self.voiceOff }
        if state.muted { return Self.voiceMuted }
        if !settings.voice.wakeWordEnabled { return Self.wakeOff }
        if take != nil { return Self.takeRecording }
        return Self.wakeModelMissing
    }

    /// Listening clears the reason the listener stopped (the backoff's step stays until it has
    /// stayed up a while; see `wakeListenerFailed`).
    private func wakeListeningChanged(_ listening: Bool) {
        let was = state.wakeListening
        state.wakeListening = listening
        guard listening, !was else { return }
        // Listening again after a re-arm: the same run, still listening since it started.
        if wakeRearming {
            wakeRearming = false
            return
        }
        wakeListeningSince = now()
        if let run = wakeFailureRun {
            log("wake listener listening again after \(run.attempts) attempt\(run.attempts == 1 ? "" : "s")")
            wakeFailureRun = nil
        } else {
            log("wake listener listening")
        }
        if wakeListenerProblem != nil {
            wakeListenerProblem = nil
            refreshWakeProblem()
        }
    }

    /// The listener could not start or stopped by itself: say why and, while it is still wanted
    /// and starting it again may help, do so after the next of `wakeRestartDelays`. The step
    /// starts over only once the listener has stayed up for the longest delay, so one that
    /// fails again soon after listening does not loop every few seconds. A failure only a model
    /// or settings change fixes waits for that change. A take, a mute or a settings change in
    /// between ends the wait (the listener is then started afresh, or not at all).
    private func wakeListenerFailed(_ failure: WakeFailure) {
        let listened = wakeListeningSince.map { now() - $0 }
        wakeListeningSince = nil
        wakeRearming = false
        if let listened, let longest = Self.wakeRestartDelays.last, listened >= longest { wakeRestarts = 0 }
        wakeListenerProblem = failure.reason
        refreshWakeProblem()
        guard runningWake != nil else { return log("wake listener failed: \(failure.reason)") }
        let logs = wakeFailureRun?.reason != failure.reason
        wakeFailureRun = (failure.reason, wakeFailureRun?.attempts ?? 0)
        guard failure.retryable else {
            wakeWaitsForChange = true
            if logs {
                log("wake listener failed: \(failure.reason); not restarting until its model or the voice settings change")
            }
            return
        }
        let delay = Self.wakeRestartDelays[min(wakeRestarts, Self.wakeRestartDelays.count - 1)]
        if logs { log("wake listener failed: \(failure.reason); restarting in \(Int(delay)) s") }
        let token = UUID()
        wakeRestartToken = token
        schedule(delay) { [weak self] in
            guard let self, wakeRestartToken == token else { return }
            restartFailedWake()
        }
    }

    private func restartFailedWake() {
        wakeRestartToken = nil
        guard let wake, let settings = runningWake, wakeListenerProblem != nil, take == nil else { return }
        wakeRestarts += 1
        wakeFailureRun?.attempts += 1
        startWake(wake, settings)
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
                problem = wakeListenerProblem ?? (settings.wakeConfirm ? wakeConfirmProblem : nil)
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

    /// Listens again after a wake that started no take, with the listener running now, dropping
    /// the rest of the sound that woke it (`wakeQuietPeriod`). Not logged: the wake's own line says
    /// what happened.
    private func rearmWake() {
        guard let wake, runningWake != nil else { return }
        wakeRearming = true
        wake.rearm(quietFor: Self.wakeQuietPeriod)
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
        let settle = hostContextSettle
        hostContextLoad = Task { [weak self] in
            let snapshot = await Self.settledSnapshot(status, settle)
            guard let self else { return }
            hostContextLoad = nil
            let context = MacHUDHostContext.build(snapshot: snapshot)
            guard context != hostContext else { return }
            hostContext = context
            refreshBrain()
        }
    }

    /// How MacHUD's description is read: again every `interval` until two reads agree, at most
    /// `reads` times. At MacHUD's launch its apps announce themselves over a few seconds; the
    /// brain starts on the settled list, so its first launch carries the final context and no
    struct HostContextSettle: Sendable {
        var interval: TimeInterval = 1.5
        var reads = 8
    }

    var hostContextSettle = HostContextSettle()

    private nonisolated static func settledSnapshot(_ status: MacHUDStatusReading?,
                                                    _ settle: HostContextSettle) async -> MacHUDSnapshot? {
        guard let status else { return nil }
        var last = await status.snapshot()
        for _ in 1..<max(settle.reads, 1) {
            try? await Task.sleep(nanoseconds: UInt64(settle.interval * 1_000_000_000))
            let next = await status.snapshot()
            if next == last { break }
            last = next
        }
        return last
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
        "\(sentence(problem)) — pasted instead"
    }

    /// The orb's notice for a wake take dropped because of the brain's `problem`.
    static func wakeDropped(_ problem: String) -> String {
        "Heard you, but the agent cannot take it: \(sentence(problem))"
    }

    /// `problem` without its full stop, to go inside a notice.
    private static func sentence(_ problem: String) -> String {
        problem.hasSuffix(".") ? String(problem.dropLast()) : problem
    }

    // MARK: - Sessions

    private func setSessionKey(_ key: String?) {
        guard key != state.sessionKey else { return }
        state.sessionKey = key
        guard key != nil, state.sessionProvider == nil, let sessions else { return }
        providerLookup = Task { [weak self] in
            let name = await sessions.providerName()
            // An open that answered meanwhile named the provider already; it is the fresher answer.
            guard let self, let name, state.sessionKey != nil, state.sessionProvider == nil else { return }
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

extension VoiceTakeTrigger {
    /// A wake detection's score, phrase and run, the scores kept to three decimals (the detector
    /// scores in `Float`). Its audio is not part of it.
    init(_ detection: WakeDetection) {
        func rounded(_ score: Double) -> Double { (score * 1000).rounded() / 1000 }
        self = .wake(score: rounded(detection.score), phrase: detection.phrase, frames: detection.frames,
                     peak: rounded(detection.peak))
    }
}
