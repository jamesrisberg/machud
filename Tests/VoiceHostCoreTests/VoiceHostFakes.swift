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

    /// Completes the current take with `text`.
    func finish(_ text: String) {
        isCapturing = false
        onUpdate?(takeID, .finished(text: text, destination: currentDestination ?? .cursor))
    }

    func level(_ value: Double) { onUpdate?(takeID, .level(value)) }
}

@MainActor
final class FakeKeys: VoiceKeySource {
    struct Start: Equatable {
        var mode: KeyGestureRecognizer.Mode
        var alternateEnabled: Bool
    }
    var starts: [Start] = []
    var stops = 0
    var isSessionActive: (() -> Bool)?
    var onIntent: ((KeyGestureRecognizer.Intent) -> Void)?
    var running: Bool { onIntent != nil }

    func start(mode: KeyGestureRecognizer.Mode, alternateEnabled: Bool,
               isSessionActive: @escaping () -> Bool,
               onIntent: @escaping (KeyGestureRecognizer.Intent) -> Void) {
        starts.append(Start(mode: mode, alternateEnabled: alternateEnabled))
        self.isSessionActive = isSessionActive
        self.onIntent = onIntent
    }

    func stop() {
        stops += 1
        onIntent = nil
    }

    func send(_ intent: KeyGestureRecognizer.Intent) { onIntent?(intent) }
}

@MainActor
final class FakeBrain: BrainDriving {
    var onAvailabilityChanged: ((Bool) -> Void)?
    var onSnapshot: ((AgentSessionSnapshot) -> Void)?
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
    func cancel() async throws { cancels += 1 }

    /// Pushes a snapshot for the last submitted request.
    func push(status: String, output: String = "", progress: String = "", approvals: [AgentApproval] = [],
              error: String? = nil, requestId: String? = nil, turnId: String? = "turn-1") {
        let snapshot = Self.snapshot(status: status, output: output, progress: progress, approvals: approvals,
                                     error: error, requestId: requestId ?? submitted.last?.requestId,
                                     turnId: turnId)
        onSnapshot?(snapshot)
    }

    static func snapshot(status: String, output: String, progress: String, approvals: [AgentApproval],
                         error: String?, requestId: String?, turnId: String?) -> AgentSessionSnapshot {
        struct Wire: Encodable {
            let threadId: String?, turnId: String?, status: String, output: String, progress: String
            let approvals: [AgentApproval], error: String?, revision: Int, instanceId: String?, requestId: String?
        }
        let wire = Wire(threadId: "thread", turnId: turnId, status: status, output: output, progress: progress,
                        approvals: approvals, error: error, revision: 1, instanceId: "i", requestId: requestId)
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

@MainActor
final class FakeWake: WakeDriving {
    var onWake: (() -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var starts: [VoiceSettings] = []
    var stops = 0
    var listening = false

    func start(_ settings: VoiceSettings) {
        starts.append(settings)
        listening = true
        onListeningChanged?(true)
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
    func render(_ state: VoiceHostState) { states.append(state) }
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
