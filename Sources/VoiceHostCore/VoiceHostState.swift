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
    /// The brain service is running and reachable.
    public var brainAvailable: Bool
    /// The wake word is armed and listening.
    public var wakeListening: Bool
    /// The user muted the voice host: no fn gestures, no wake word, no spoken replies.
    public var muted: Bool

    public init(phase: VoicePhase = .idle, inputLevel: Double = 0, partialTranscript: String = "",
                card: VoiceCard? = nil, hiddenForFullScreen: Bool = false, brainAvailable: Bool = false,
                wakeListening: Bool = false, muted: Bool = false) {
        self.phase = phase
        self.inputLevel = inputLevel
        self.partialTranscript = partialTranscript
        self.card = card
        self.hiddenForFullScreen = hiddenForFullScreen
        self.brainAvailable = brainAvailable
        self.wakeListening = wakeListening
        self.muted = muted
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
