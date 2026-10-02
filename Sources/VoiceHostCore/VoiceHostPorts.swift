import BrainKit
import Foundation
import SpeakFreeLib
import VoiceKit

// The controller's collaborators. Each has a live implementation in `Live/` and a fake in the
// tests, so the controller's behavior is tested without a microphone, an event tap, a brain
// process or a speaker.

/// A take's progress, as the controller needs it.
enum DictationUpdate: Equatable {
    /// Capture is running for this destination.
    case recording(DictationDestination)
    case retargeted(DictationDestination)
    /// Microphone level, 0...1.
    case level(Double)
    /// Live-preview text; empty clears it.
    case partial(String)
    /// Capture ended; the take is being transcribed.
    case transcribing
    /// The take's text: typed at the cursor already, or returned for the caller. `transcript`
    /// is the words as spoken (punctuation and glossary applied, no styling), for the text feed.
    case finished(text: String, destination: DictationDestination, transcript: String)
    case failed(DictationFailure)
}

/// One dictation take at a time: capture, transcription and (for `.cursor`) delivery.
@MainActor
protocol DictationDriving: AnyObject {
    /// Updates for the take with this id, on the main actor.
    var onUpdate: ((UUID, DictationUpdate) -> Void)? { get set }
    /// True from start until the take's transcription begins.
    var isCapturing: Bool { get }
    func start(_ destination: DictationDestination) -> DictationStartOutcome
    func retarget(_ destination: DictationDestination)
    /// End the take and send it on.
    func stop()
    /// Throw the capturing take away.
    func cancel()
    /// Types `text` at the cursor (a take the agent could not take).
    func insert(_ text: String)
    /// Finished takes are kept (or not) as `history` says from now on.
    func setHistory(_ history: DictationHistorySettings?)
    /// The speech model may have been installed: use it from the next take.
    func prepareEngine()
}

extension DictationDriving {
    /// A capture path that writes no recordings keeps no history.
    func setHistory(_ history: DictationHistorySettings?) {}
    func prepareEngine() {}
}

/// The fn key's gestures (`KeyGestureRecognizer` intents), recognized with the configuration
/// the controller times its own gesture window with.
@MainActor
protocol VoiceKeySource: AnyObject {
    /// - Parameter onRelease: the key came up (reported before the recognizer handles it).
    func start(mode: KeyGestureRecognizer.Mode, configuration: KeyGestureRecognizer.Configuration,
               isSessionActive: @escaping () -> Bool,
               onIntent: @escaping (KeyGestureRecognizer.Intent) -> Void,
               onRelease: @escaping () -> Void)
    func stop()
}

/// The brain companion as the voice host sees it.
enum BrainHealth: Equatable {
    case stopped
    case starting
    /// Running; the client is not connected yet.
    case connecting
    /// Running with a connected client: turns can go to it.
    case ready
    /// Cannot start as configured (no workspace, no Node.js); the reason is user-facing.
    case unavailable(String)
    /// It exited and is being started again.
    case restarting(String)
    /// It kept failing and was given up on until the configuration changes.
    case failed(String)
}

/// The brain process and the client for it.
@MainActor
protocol BrainDriving: AnyObject {
    var onHealthChanged: ((BrainHealth) -> Void)? { get set }
    var onSnapshot: ((AgentSessionSnapshot) -> Void)? { get set }
    /// The companion that was running stopped or is restarting: any turn it was running is
    /// gone. A first start, or a start that never came up, is not a stop.
    var onStopped: (() -> Void)? { get set }
    /// Run the companion as configured; nil stops it. A change of runtime alone reaches the
    /// running companion without a restart.
    func configure(_ configuration: BrainServiceConfiguration?)
    func submit(_ text: String, requestId: String) async throws
    func approve(id: String, allow: Bool) async throws
    func cancel() async throws
}

/// Speaks a reply that arrives in pieces.
@MainActor
protocol ReplySpeaking: AnyObject {
    /// True while a sentence is speaking or queued.
    var isSpeaking: Bool { get }
    /// Everything appended and finished has been said (or speech failed).
    var onFinished: (() -> Void)? { get set }
    /// A chunk of the reply starts playing; its `rawRange` counts `Character`s of everything
    /// appended for the reply.
    var onChunkStarted: ((SpeechChunk) -> Void)? { get set }
    /// The voice for the next reply.
    func configure(_ voice: VoiceSettings)
    /// Gets the voice ready for a reply that is coming (loads the model); never plays.
    func warmUp()
    func append(_ text: String)
    func finish()
    func stop()
}

/// A downloadable model's state, as `models status` reports it.
struct VoiceModelStatus: Equatable, Sendable {
    var installed: Bool
    var downloading: Bool
    /// 0...1 while downloading; 1 once installed.
    var progress: Double
    /// The whole download's size.
    var bytes: Int64
    /// Why the last download failed, in words for the user.
    var error: String?
    /// The model's own id, where one family has several (Parakeet's English or multilingual).
    var id: String?
}

/// A downloadable model's files (the Kokoro reply voice, the Parakeet speech model, a wake model).
@MainActor
protocol VoiceModelProviding: AnyObject {
    var status: VoiceModelStatus { get }
    /// After every change of `status`.
    var onChange: (() -> Void)? { get set }
    /// Downloads and verifies the files; a download under way continues.
    func download()
}

/// A wake phrase the host can listen for: the model that detects it and that model's files.
/// Only phrases with a model are offered; the model is downloaded when the user asks.
@MainActor
struct WakePhraseModel {
    /// The socket's id for it (`hey-jarvis`), from the phrase.
    let id: String
    let phrase: String
    /// VoiceKit's manifest id (`openwakeword-hey-jarvis-v0.1`); `models download` takes it too.
    let manifestID: String
    /// The model's licence as its manifest states it.
    let licence: String
    /// The terms in a few words, shown beside the phrase.
    let note: String
    /// False: the model is downloaded on request, never bundled.
    let redistributable: Bool
    let store: VoiceModelProviding

    init(model: WakeModel, store: VoiceModelProviding) {
        self.init(id: Self.id(for: model.phrase), phrase: model.phrase, manifestID: model.manifest.id,
                  licence: model.manifest.licence, redistributable: model.manifest.redistributable, store: store)
    }

    init(id: String, phrase: String, manifestID: String, licence: String, redistributable: Bool,
         store: VoiceModelProviding) {
        self.id = id
        self.phrase = phrase
        self.manifestID = manifestID
        self.licence = licence
        self.redistributable = redistributable
        note = redistributable
            ? "Downloaded when you ask."
            : "Personal, non-commercial use only. Downloaded when you ask, never bundled with MacHUD."
        self.store = store
    }

    /// "Hey Jarvis" → `hey-jarvis`.
    static func id(for phrase: String) -> String {
        TriggerPhrase.normalize(phrase).replacingOccurrences(of: " ", with: "-")
    }

    /// `models status`'s entry for it.
    var json: [String: Any] {
        let status = store.status
        var entry: [String: Any] = [
            "id": id, "phrase": phrase, "manifestId": manifestID, "licence": licence, "note": note,
            "redistributable": redistributable, "installed": status.installed,
            "downloading": status.downloading, "progress": status.progress, "bytes": status.bytes,
        ]
        if let error = status.error { entry["error"] = error }
        return entry
    }

    func matches(phrase other: String) -> Bool {
        TriggerPhrase.normalize(other) == TriggerPhrase.normalize(phrase)
    }
}

/// The wake word listener.
@MainActor
protocol WakeDriving: AnyObject {
    var onWake: (() -> Void)? { get set }
    var onListeningChanged: ((Bool) -> Void)? { get set }
    /// Listening stopped by itself (the microphone refused, the model failed), in words for the
    /// user; nil when a start clears it.
    var onProblem: ((String?) -> Void)? { get set }
    /// Start (or restart) listening for `settings.wakePhrase`.
    func start(_ settings: VoiceSettings)
    func stop()
}

/// MacHUD's `agent-sessions` broker (`sessions` on MacHUD's control socket).
protocol SessionOpening: Sendable {
    /// Shows the session in the first running provider (MacHUD launches one if none runs);
    /// the provider app's name, or why not.
    func open(id: String) async -> Result<String, SessionOpenError>
    /// The app sessions open in: the first running provider, else the first installed one.
    func providerName() async -> String?
}

struct SessionOpenError: Error, Equatable {
    let message: String
}

/// MacHUD's `text-feed` broker (`feed add` on MacHUD's control socket), which hands text to the
/// apps that keep a feed (Stash's history). Fire-and-forget: never blocks or fails a take.
protocol TextFeeding: Sendable {
    /// `source` is a short label ("Dictation", "Agent").
    func add(text: String, source: String, title: String?)
}

/// Runs work on the main actor after a delay (a manual clock in tests).
typealias VoiceScheduler = (TimeInterval, @escaping @Sendable @MainActor () -> Void) -> Void

let mainQueueScheduler: VoiceScheduler = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
}

/// MacHUD's installed apps and loadouts, for the brain's host context.
protocol MacHUDStatusReading: Sendable {
    /// Nil when MacHUD does not answer.
    func snapshot() async -> MacHUDSnapshot?
}
