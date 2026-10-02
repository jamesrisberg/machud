import Foundation

/// What the voice host is doing, as the orb, MacHUD and the `machud-voice` socket see it.
/// The controller is the only writer; the UI renders it and never keeps state of its own.
public struct VoiceHostState: Codable, Equatable, Sendable {
    public var phase: VoicePhase
    /// Microphone level while listening, 0...1, for the waveform and the orb's pulse.
    public var inputLevel: Double
    /// Words heard so far in the current take.
    public var partialTranscript: String
    /// The reply card: present from the first agent turn until dismissed.
    public var card: VoiceCard?
    /// The frontmost app is full screen on the orb's screen; the orb hides, the gestures still work.
    public var hiddenForFullScreen: Bool
    /// The brain service is running, reachable and able to take a turn.
    public var brainAvailable: Bool
    /// Why the brain cannot take a turn, in words for the user ("Choose a workspace folder for
    /// the agent.", "Codex is not installed."); nil once it can.
    public var brainProblem: String?
    /// The brain's current session, when its runtime drives one other apps also show
    /// (mechaclaude's key, `claude:<sessionId>`); `openSession` asks MacHUD to show it.
    public var sessionKey: String?
    /// The app MacHUD opens agent sessions in (the `agent-sessions` provider), once known.
    public var sessionProvider: String?
    /// The runtime the brain companion reports running (`codex`, `claude`, …); nil while none
    /// is connected. It differs from the chosen `brain.runtime` until a switch lands.
    public var activeRuntime: String?
    /// The wake word is armed and listening.
    public var wakeListening: Bool
    /// Why the wake word is on but not listening, in words for the user ("Download the Hey
    /// Jarvis model to use the wake word."); nil while it listens, and while it is off or muted.
    public var wakeProblem: String?
    /// The user muted the voice host: no fn gestures, no wake word, no spoken replies.
    public var muted: Bool
    /// An fn press began a take and the gesture is not decided yet: a second press could still
    /// move it to the agent. True from the press until the double-tap window lapses, the press
    /// outlasts a tap, the second press arrives, or the take ends. The orb shows a neutral
    /// armed look meanwhile, so it never morphs into the waveform only to turn back.
    public var gesturePending: Bool
    /// How the latest hands-free take ended, and what the endpointer measured; nil until one has.
    public var lastTakeEnd: VoiceTakeEnd?

    public init(phase: VoicePhase = .idle, inputLevel: Double = 0, partialTranscript: String = "",
                card: VoiceCard? = nil, hiddenForFullScreen: Bool = false, brainAvailable: Bool = false,
                brainProblem: String? = nil, sessionKey: String? = nil, sessionProvider: String? = nil,
                activeRuntime: String? = nil,
                wakeListening: Bool = false, wakeProblem: String? = nil, muted: Bool = false,
                gesturePending: Bool = false, lastTakeEnd: VoiceTakeEnd? = nil) {
        self.phase = phase
        self.inputLevel = inputLevel
        self.partialTranscript = partialTranscript
        self.card = card
        self.hiddenForFullScreen = hiddenForFullScreen
        self.brainAvailable = brainAvailable
        self.brainProblem = brainProblem
        self.sessionKey = sessionKey
        self.sessionProvider = sessionProvider
        self.activeRuntime = activeRuntime
        self.wakeListening = wakeListening
        self.wakeProblem = wakeProblem
        self.muted = muted
        self.gesturePending = gesturePending
        self.lastTakeEnd = lastTakeEnd
    }
}

/// Why a hands-free take ended, for diagnosing takes that end too soon or too late. Also
/// logged, one line per take.
public struct VoiceTakeEnd: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Equatable, Sendable {
        /// The pause after speech (automatic end of turn).
        case pause
        /// The take reached the endpointer's maximum length.
        case maximum
        /// No speech was heard 10 s into an automatic take: it is thrown away, not sent.
        case nothingHeard
        /// A tap: the orb, the fn key or `action stop`.
        case stop
        /// Thrown away: `action cancel`, mute, or a change to the fn key setup.
        case cancelled
        /// The dictation failed (no speech model, too short to transcribe, an audio error).
        case failed
        /// The dictation ended the take by itself.
        case dictation
    }

    public var reason: Reason
    /// The take's length, from its start to its end.
    public var seconds: TimeInterval
    /// Quiet measured since the last speech; nil while speech was still going on, or before any.
    public var quietMs: Int?
    /// The noise floor and the speech threshold at the end, on SpeakFree's level scale (0...1,
    /// RMS / 0.15); nil once no level arrived.
    public var floor: Double?
    public var threshold: Double?
    /// The pause the take needed to end on its own, grace included; nil when silence never
    /// ends it (end of turn "manual").
    public var pause: TimeInterval?
    /// The latest words read as an unfinished sentence, so the pause carried the grace.
    public var grace: Bool

    public init(reason: Reason, seconds: TimeInterval, quietMs: Int? = nil, floor: Double? = nil,
                threshold: Double? = nil, pause: TimeInterval? = nil, grace: Bool = false) {
        self.reason = reason
        self.seconds = seconds
        self.quietMs = quietMs
        self.floor = floor
        self.threshold = threshold
        self.pause = pause
        self.grace = grace
    }

    /// The log line: `pause after 2050 ms quiet (floor 0.021, threshold 0.050, pause 3.5 s with grace), take 6.4 s`.
    public var summary: String {
        var details: [String] = []
        if let floor, let threshold {
            details.append(String(format: "floor %.3f, threshold %.3f", floor, threshold))
        }
        if let pause {
            details.append(String(format: "pause %.1f s", pause) + (grace ? " with grace" : ""))
        } else {
            details.append("ends on a tap")
        }
        let quiet = quietMs.map { " after \($0) ms quiet" } ?? ""
        return "\(reason.rawValue)\(quiet) (\(details.joined(separator: ", "))), take "
            + String(format: "%.1f s", seconds)
    }
}

/// Where a take's words go.
public enum VoiceMode: String, Codable, Equatable, Sendable {
    /// Pasted at the cursor (SpeakFree dictation).
    case dictation
    /// Sent to the brain as an agent turn.
    case agent
}

public enum VoicePhase: Codable, Equatable, Sendable {
    /// The resting orb.
    case idle
    /// Recording. Dictation shows the waveform; agent shows the pulsing orb.
    case listening(VoiceMode)
    /// Recording ended; the take is being transcribed (and, for dictation, pasted).
    case transcribing(VoiceMode)
    /// The brain is working on a turn.
    case working
    /// The brain is waiting on an approval shown in the card.
    case awaitingApproval
    /// A reply is being spoken aloud.
    case speaking
    /// Something failed; the message is short and user-facing.
    case failed(String)

    /// On the wire a phase is `{"name": …}`, plus `"mode"` for listening and transcribing and
    /// `"message"` for failed, so socket clients read it without Swift's enum encoding.
    private enum CodingKeys: String, CodingKey { case name, mode, message }

    public var name: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .transcribing: "transcribing"
        case .working: "working"
        case .awaitingApproval: "awaitingApproval"
        case .speaking: "speaking"
        case .failed: "failed"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        switch self {
        case .listening(let mode), .transcribing(let mode): try c.encode(mode, forKey: .mode)
        case .failed(let message): try c.encode(message, forKey: .message)
        default: break
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        switch name {
        case "idle": self = .idle
        case "listening": self = .listening(try c.decode(VoiceMode.self, forKey: .mode))
        case "transcribing": self = .transcribing(try c.decode(VoiceMode.self, forKey: .mode))
        case "working": self = .working
        case "awaitingApproval": self = .awaitingApproval
        case "speaking": self = .speaking
        case "failed": self = .failed((try? c.decode(String.self, forKey: .message)) ?? "")
        default:
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Unknown phase \(name)")
        }
    }
}

/// The reply card under the orb.
public struct VoiceCard: Codable, Equatable, Sendable {
    /// What the user asked, as transcribed.
    public var prompt: String
    /// The reply so far (streams in).
    public var reply: String
    /// Short progress lines from tools, newest last.
    public var progress: [String]
    /// An approval the brain is waiting on.
    public var approval: VoiceApproval?

    public init(prompt: String = "", reply: String = "", progress: [String] = [], approval: VoiceApproval? = nil) {
        self.prompt = prompt
        self.reply = reply
        self.progress = progress
        self.approval = approval
    }
}

public struct VoiceApproval: Codable, Equatable, Sendable {
    public var id: String
    /// One line: what the brain wants to do.
    public var summary: String
    /// Optional detail (a command, a path), shown smaller.
    public var detail: String

    public init(id: String, summary: String, detail: String = "") {
        self.id = id
        self.summary = summary
        self.detail = detail
    }
}

/// What the UI and the socket can ask the controller to do.
public enum VoiceHostAction: Codable, Equatable, Sendable {
    /// The orb was clicked: start an agent take, or stop the current take, or dismiss.
    case orbClicked
    /// Start a take directly (socket, radial menu).
    case start(VoiceMode)
    /// Stop recording and send the take on.
    case stop
    /// Throw away the current take or interrupt the brain.
    case cancel
    case approve(id: String)
    case deny(id: String)
    case dismissCard
    case setMuted(Bool)
    /// Show the brain's current session (`sessionKey`) in the app MacHUD opens sessions in.
    case openSession
}

/// The UI's way back into the controller.
@MainActor
public protocol VoiceHostActing: AnyObject {
    func perform(_ action: VoiceHostAction)
}

/// Draws the voice host. The controller calls `render` on every state change; the presenter
/// sends user input back through the `VoiceHostActing` it was given.
@MainActor
public protocol VoiceHostPresenting: AnyObject {
    func render(_ state: VoiceHostState)
}
