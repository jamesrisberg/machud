import BrainKit
import Foundation
import SpeakFreeLib
import VoiceKit
@testable import VoiceHostCore

@MainActor
final class FakeDictation: DictationDriving {
    var onUpdate: ((UUID, DictationUpdate) -> Void)?
    var unavailable: DictationFailure?
    var isCapturing = false
    var starts: [DictationDestination] = []
    var retargets: [DictationDestination] = []
    var stops = 0
    var cancels = 0
    var inserted: [String] = []
    private(set) var takeID = UUID()
    var currentDestination: DictationDestination?

    func start(_ destination: DictationDestination) -> DictationStartOutcome {
        if let unavailable { return .refused(unavailable) }
        guard !isCapturing else { return .refused(.busy) }
        starts.append(destination)
        takeID = UUID()
        isCapturing = true
        currentDestination = destination
        onUpdate?(takeID, .recording(destination))
        return .started(takeID)
    }

    func retarget(_ destination: DictationDestination) {
        retargets.append(destination)
        currentDestination = destination
        onUpdate?(takeID, .retargeted(destination))
    }

    func stop() {
        stops += 1
        isCapturing = false
        onUpdate?(takeID, .transcribing)
    }

    func cancel() {
        cancels += 1
        isCapturing = false
        onUpdate?(takeID, .failed(.cancelled))
    }

    func insert(_ text: String) { inserted.append(text) }

    /// Every history setting handed over, in order.
    var histories: [DictationHistorySettings?] = []
    func setHistory(_ history: DictationHistorySettings?) { histories.append(history) }

    /// Completes the current take with `text` (typed or returned) and `transcript` (the words
    /// as spoken; `text` when not given).
    func finish(_ text: String, transcript: String? = nil) {
        isCapturing = false
        onUpdate?(takeID, .finished(text: text, destination: currentDestination ?? .cursor, transcript: transcript ?? text))
    }

    func level(_ value: Double) { onUpdate?(takeID, .level(value)) }

    func partial(_ text: String) { onUpdate?(takeID, .partial(text)) }
}

@MainActor
final class FakeKeys: VoiceKeySource {
    struct Start: Equatable {
        var mode: KeyGestureRecognizer.Mode
        var alternateEnabled: Bool
    }
    var starts: [Start] = []
    var configurations: [KeyGestureRecognizer.Configuration] = []
    var stops = 0
    var isSessionActive: (() -> Bool)?
    var onIntent: ((KeyGestureRecognizer.Intent) -> Void)?
    var onRelease: (() -> Void)?
    var running: Bool { onIntent != nil }

    func start(mode: KeyGestureRecognizer.Mode, configuration: KeyGestureRecognizer.Configuration,
               isSessionActive: @escaping () -> Bool,
               onIntent: @escaping (KeyGestureRecognizer.Intent) -> Void,
               onRelease: @escaping () -> Void) {
        starts.append(Start(mode: mode, alternateEnabled: configuration.alternateEnabled))
        configurations.append(configuration)
        self.isSessionActive = isSessionActive
        self.onIntent = onIntent
        self.onRelease = onRelease
    }

    func stop() {
        stops += 1
        onIntent = nil
        onRelease = nil
    }

    func send(_ intent: KeyGestureRecognizer.Intent) { onIntent?(intent) }
    /// The fn key came up.
    func release() { onRelease?() }
}

@MainActor
final class FakeBrain: BrainDriving {
    var onHealthChanged: ((BrainHealth) -> Void)?
    /// What the controller reads as each snapshot's session key.
    var sessionKey: String?
    var onSnapshot: ((AgentSessionSnapshot) -> Void)?
    var onStopped: (() -> Void)?
    var cancelError: Error?
    var configurations: [BrainServiceConfiguration?] = []
    var submitted: [(text: String, requestId: String)] = []
    var approvals: [(id: String, allow: Bool)] = []
    var cancels = 0
    var submitError: Error?

    func configure(_ configuration: BrainServiceConfiguration?) { configurations.append(configuration) }

    func submit(_ text: String, requestId: String) async throws {
        submitted.append((text, requestId))
        if let submitError { throw submitError }
    }

    func approve(id: String, allow: Bool) async throws { approvals.append((id, allow)) }
    func cancel() async throws {
        cancels += 1
        if let cancelError { throw cancelError }
    }

    /// Pushes a snapshot for the last submitted request.
    func push(status: String, output: String = "", progress: String = "", approvals: [AgentApproval] = [],
              error: String? = nil, requestId: String? = nil, turnId: String? = "turn-1") {
        let snapshot = Self.snapshot(status: status, output: output, progress: progress, approvals: approvals,
                                     error: error, requestId: requestId ?? submitted.last?.requestId,
                                     turnId: turnId)
        onSnapshot?(snapshot)
    }

    static func snapshot(status: String, output: String, progress: String, approvals: [AgentApproval],
                         error: String?, requestId: String?, turnId: String?, threadId: String? = "thread",
                         sessionKey: String? = nil, runtime: String? = nil,
                         toolServers: AgentToolServerStatus? = nil) -> AgentSessionSnapshot {
        struct Wire: Encodable {
            let threadId: String?, turnId: String?, status: String, output: String, progress: String
            let approvals: [AgentApproval], error: String?, revision: Int, instanceId: String?, requestId: String?
            let sessionKey: String?, runtime: String?, toolServers: AgentToolServerStatus?
        }
        let wire = Wire(threadId: threadId, turnId: turnId, status: status, output: output, progress: progress,
                        approvals: approvals, error: error, revision: 1, instanceId: "i", requestId: requestId,
                        sessionKey: sessionKey, runtime: runtime, toolServers: toolServers)
        let data = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(AgentSessionSnapshot.self, from: data)
    }
}

@MainActor
final class FakeSpeaker: ReplySpeaking {
    var isSpeaking = false
    var onFinished: (() -> Void)?
    var voices: [VoiceSettings] = []
    var spoken = ""
    var finishes = 0
    var stops = 0

    func configure(_ voice: VoiceSettings) { voices.append(voice) }
    func append(_ text: String) {
        spoken += text
        if !text.isEmpty { isSpeaking = true }
    }
    func finish() { finishes += 1 }
    func stop() {
        stops += 1
        isSpeaking = false
    }

    /// The voice has said everything.
    func complete() {
        isSpeaking = false
        onFinished?()
    }
}

/// A model's store (Kokoro, Parakeet, a wake model), without a download.
@MainActor
final class FakeModels: VoiceModelProviding {
    var status = VoiceModelStatus(installed: false, downloading: false, progress: 0, bytes: 325_000_000)
    var onChange: (() -> Void)?
    var downloads = 0

    func download() {
        downloads += 1
        status.downloading = true
        onChange?()
    }

    func update(_ change: (inout VoiceModelStatus) -> Void) {
        change(&status)
        onChange?()
    }
}

@MainActor
final class FakeWake: WakeDriving {
    var onWake: (() -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onProblem: ((String?) -> Void)?
    var starts: [VoiceSettings] = []
    var stops = 0
    var listening = false

    func start(_ settings: VoiceSettings) {
        starts.append(settings)
        listening = true
        onListeningChanged?(true)
    }

    /// Listening stops by itself, as a failed microphone does.
    func fail(_ reason: String) {
        listening = false
        onListeningChanged?(false)
        onProblem?(reason)
    }

    func stop() {
        stops += 1
        listening = false
        onListeningChanged?(false)
    }
}

@MainActor
final class RecordingPresenter: VoiceHostPresenting {
    var states: [VoiceHostState] = []
    var conversations: [[ConversationRow]] = []
    func render(_ state: VoiceHostState) { states.append(state) }
    func renderConversation(_ rows: [ConversationRow]) { conversations.append(rows) }
}

/// A manual clock and scheduler.
@MainActor
final class ManualClock {
    var now: TimeInterval = 0
    var scheduled: [(at: TimeInterval, work: @MainActor () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        scheduled.append((now + delay, work))
    }

    func advance(to time: TimeInterval) {
        now = time
        let due = scheduled.filter { $0.at <= time }
        scheduled.removeAll { $0.at <= time }
        due.forEach { $0.work() }
    }
}

/// Every runtime installed, or those in `missing` not.
enum FakeRuntimes {
    static func detect(missing: Set<String> = []) -> (BrainSettings) -> [BrainRuntimeDetection] {
        { _ in
            BrainRuntimes.ids.map { id in
                let installed = !missing.contains(id)
                return BrainRuntimeDetection(id: id, name: BrainRuntimes.name(for: id), installed: installed,
                                             path: installed ? "/fake/bin/\(id)" : nil,
                                             apiServerEnabled: id == "hermes" ? true : nil)
            }
        }
    }
}

/// MacHUD's text-feed broker: what was sent.
final class FakeFeed: TextFeeding, @unchecked Sendable {
    struct Item: Equatable {
        var text: String
        var source: String
        var title: String?
    }
    private(set) var items: [Item] = []

    func add(text: String, source: String, title: String?) {
        items.append(Item(text: text, source: source, title: title))
    }
}

/// Parakeet's download without a network: `installed` is what is on "disk"; `prefetch` and
/// `install` wait until the test lets them go (`finish`).
final class FakeParakeet: ParakeetDownloading, @unchecked Sendable {
    var installed: Set<String> = []
    var failure: Error?
    private(set) var prefetched: [String] = []
    private(set) var installs: [String] = []
    private var prefetchProgress: (@Sendable (Int64, Int64) -> Void)?
    private var installProgress: (@Sendable (Double) -> Void)?
    private var release: CheckedContinuation<Void, Never>?

    func isDownloaded(_ id: String) -> Bool { installed.contains(id) }

    func prefetch(_ id: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        prefetched.append(id)
        prefetchProgress = progress
    }

    func install(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        installs.append(id)
        installProgress = progress
        await withCheckedContinuation { release = $0 }
        if let failure { throw failure }
        installed.insert(id)
    }

    var isInstalling: Bool { release != nil }
    func reportBytes(_ written: Int64, of total: Int64) { prefetchProgress?(written, total) }
    func reportInstall(_ fraction: Double) { installProgress?(fraction) }

    /// Lets the install end (with `failure`, if set).
    func finish() {
        release?.resume()
        release = nil
    }
}

/// MacHUD's session broker.
final class FakeSessions: SessionOpening, @unchecked Sendable {
    var result: Result<String, SessionOpenError> = .success("SessionsApp")
    var provider: String? = "SessionsApp"
    private(set) var opened: [String] = []

    func open(id: String) async -> Result<String, SessionOpenError> {
        opened.append(id)
        return result
    }

    func providerName() async -> String? { provider }
}

extension FakeModels {
    /// A wake model's store, installed or not.
    static func wake(installed: Bool) -> FakeModels {
        let models = FakeModels()
        models.status = VoiceModelStatus(installed: installed, downloading: false, progress: installed ? 1 : 0,
                                         bytes: 3_685_906)
        return models
    }
}

/// MacHUD's apps and loadouts as the fake MacHUD reports them; nil does not answer.
final class FakeMacHUDStatus: MacHUDStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: MacHUDSnapshot?
    private var _reads = 0

    init(_ snapshot: MacHUDSnapshot?) { _snapshot = snapshot }

    var current: MacHUDSnapshot? {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }

    var reads: Int { lock.withLock { _reads } }

    /// Answers read in turn before `current`, the last one becoming `current` (apps announcing
    /// themselves while MacHUD starts).
    func announce(_ snapshots: [MacHUDSnapshot?]) {
        lock.withLock { _queue = snapshots }
    }

    private var _queue: [MacHUDSnapshot?] = []

    func snapshot() async -> MacHUDSnapshot? {
        lock.withLock {
            _reads += 1
            if !_queue.isEmpty { _snapshot = _queue.removeFirst() }
            return _snapshot
        }
    }
}
