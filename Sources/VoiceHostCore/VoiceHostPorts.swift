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
    /// The take's text: typed at the cursor already, or returned for the caller.
    case finished(text: String, destination: DictationDestination)
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
    /// The companion stopped or is restarting: any turn it was running is gone.
    var onStopped: (() -> Void)? { get set }
    /// Run the companion as configured; nil stops it.
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
    /// The voice for the next reply.
    func configure(_ voice: VoiceSettings)
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
}

/// The Kokoro reply voice's model files.
@MainActor
protocol VoiceModelProviding: AnyObject {
    var status: VoiceModelStatus { get }
    /// After every change of `status`.
    var onChange: (() -> Void)? { get set }
    /// Downloads and verifies the files; a download under way continues.
    func download()
}

/// The wake word listener.
@MainActor
protocol WakeDriving: AnyObject {
    var onWake: (() -> Void)? { get set }
    var onListeningChanged: ((Bool) -> Void)? { get set }
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

/// Runs work on the main actor after a delay (a manual clock in tests).
typealias VoiceScheduler = (TimeInterval, @escaping @Sendable @MainActor () -> Void) -> Void

let mainQueueScheduler: VoiceScheduler = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
}
