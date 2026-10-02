import BrainKit
import Foundation
import VoiceKit

/// Everything the voice host is configured by. Stored as `voice.json` in MacHUD's config
/// directory; the voice host owns the file and MacHUD edits it through `settings set`.
public struct VoiceHostSettings: Codable, Equatable, Sendable {
    public enum KeyMode: String, Codable, Equatable, Sendable {
        /// Hold fn to dictate; tap then hold to talk to the agent.
        case hold
        /// Tap fn to dictate; double-tap to talk to the agent.
        case toggle
    }

    /// Voice features on at all (fn gestures, orb, wake word).
    public var enabled: Bool
    public var keyMode: KeyMode
    /// The agent gesture (double-tap / tap-then-hold) is recognised.
    public var agentGesture: Bool
    /// The brain is on; off leaves dictation only.
    public var brainEnabled: Bool
    /// Loopback port for the brain service (Archibald uses 8790).
    public var brainPort: Int
    public var brain: BrainSettings
    /// The brain gets MacHUD's tool server (`machud-mcp`) and a description of MacHUD and its
    /// apps. Stored inside `brain` as `brain.machudTools`, beside BrainKit's own keys.
    public var machudTools: Bool
    /// MacHUD's tools ask before each call (`brain.machudToolsRequireApproval`); off, they run
    /// without asking, as they only drive reversible UI. The brain's other actions keep its own
    /// approval policy either way.
    public var machudToolsRequireApproval: Bool
    public var voice: VoiceSettings
    /// Keep dictation history; nil (absent from `voice.json`) follows the default rule
    /// (`DictationHistoryLocator.plan(for:)`).
    public var history: DictationHistorySettings?
    /// Each finished dictation's text goes to the apps that keep a text feed (`feed add` on
    /// MacHUD's socket, source "Dictation").
    public var feedTranscripts: Bool
    /// Each finished agent reply goes to the text feed too (source "Agent").
    public var feedAgentReplies: Bool
    /// When a hands-free take (orb, wake word, socket `ask`) is over.
    public var handsFree: HandsFreeSettings

    public init(enabled: Bool = true, keyMode: KeyMode = .hold, agentGesture: Bool = true,
                brainEnabled: Bool = true, brainPort: Int = 8791,
                brain: BrainSettings = BrainSettings(), machudTools: Bool = true,
                machudToolsRequireApproval: Bool = false, voice: VoiceSettings = VoiceSettings(),
                history: DictationHistorySettings? = nil, feedTranscripts: Bool = true,
                feedAgentReplies: Bool = false, handsFree: HandsFreeSettings = HandsFreeSettings()) {
        self.enabled = enabled
        self.keyMode = keyMode
        self.agentGesture = agentGesture
        self.brainEnabled = brainEnabled
        self.brainPort = brainPort
        self.brain = brain
        self.machudTools = machudTools
        self.machudToolsRequireApproval = machudToolsRequireApproval
        self.voice = voice
        self.history = history
        self.feedTranscripts = feedTranscripts
        self.feedAgentReplies = feedAgentReplies
        self.handsFree = handsFree
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, keyMode, agentGesture, brainEnabled, brainPort, brain, voice, history, feedTranscripts,
             feedAgentReplies, handsFree
    }

    /// The keys this host adds to the `brain` object.
    private enum BrainToolKeys: String, CodingKey {
        case machudTools, machudToolsRequireApproval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceHostSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        keyMode = (try? c.decode(KeyMode.self, forKey: .keyMode)) ?? d.keyMode
        agentGesture = (try? c.decode(Bool.self, forKey: .agentGesture)) ?? d.agentGesture
        brainEnabled = (try? c.decode(Bool.self, forKey: .brainEnabled)) ?? d.brainEnabled
        let port = (try? c.decode(Int.self, forKey: .brainPort)) ?? d.brainPort
        brainPort = (1024...65535).contains(port) ? port : d.brainPort
        brain = (try? c.decode(BrainSettings.self, forKey: .brain)) ?? d.brain
        let tools = try? c.nestedContainer(keyedBy: BrainToolKeys.self, forKey: .brain)
        machudTools = (try? tools?.decode(Bool.self, forKey: .machudTools)) ?? d.machudTools
        machudToolsRequireApproval = (try? tools?.decode(Bool.self, forKey: .machudToolsRequireApproval))
            ?? d.machudToolsRequireApproval
        voice = (try? c.decode(VoiceSettings.self, forKey: .voice)) ?? d.voice
        history = try? c.decodeIfPresent(DictationHistorySettings.self, forKey: .history)
        feedTranscripts = (try? c.decode(Bool.self, forKey: .feedTranscripts)) ?? d.feedTranscripts
        feedAgentReplies = (try? c.decode(Bool.self, forKey: .feedAgentReplies)) ?? d.feedAgentReplies
        handsFree = (try? c.decode(HandsFreeSettings.self, forKey: .handsFree)) ?? d.handsFree
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(keyMode, forKey: .keyMode)
        try c.encode(agentGesture, forKey: .agentGesture)
        try c.encode(brainEnabled, forKey: .brainEnabled)
        try c.encode(brainPort, forKey: .brainPort)
        // One `brain` object: BrainKit's settings, then this host's keys in the same container.
        let brainEncoder = c.superEncoder(forKey: .brain)
        try brain.encode(to: brainEncoder)
        var tools = brainEncoder.container(keyedBy: BrainToolKeys.self)
        try tools.encode(machudTools, forKey: .machudTools)
        try tools.encode(machudToolsRequireApproval, forKey: .machudToolsRequireApproval)
        try c.encode(voice, forKey: .voice)
        try c.encodeIfPresent(history, forKey: .history)
        try c.encode(feedTranscripts, forKey: .feedTranscripts)
        try c.encode(feedAgentReplies, forKey: .feedAgentReplies)
        try c.encode(handsFree, forKey: .handsFree)
    }
}

/// How a hands-free take ends (`handsFree` in `voice.json`). Key-held takes end with the key.
public struct HandsFreeSettings: Codable, Equatable, Sendable {
    public enum EndOfTurn: String, Codable, Equatable, Sendable {
        /// A pause after speech ends the take (`SilenceEndpointer`).
        case auto
        /// Only a tap (the orb, the fn key, `voice action stop`) or the maximum length ends it.
        case manual
    }

    /// How readily a sound counts as speech over the room's noise.
    public enum Sensitivity: String, Codable, Equatable, Sendable {
        case low, medium, high
    }

    /// The choices for `pause`, in seconds.
    public static let pauseRange: ClosedRange<TimeInterval> = 1...4
    public static let pauseStep: TimeInterval = 0.5

    public var endOfTurn: EndOfTurn
    /// Quiet after speech, in seconds, before an automatic take is sent: `pauseRange` in steps
    /// of `pauseStep`, other values are brought to the nearest choice.
    public var pause: TimeInterval {
        didSet { pause = Self.pauseChoice(pause) }
    }
    public var sensitivity: Sensitivity

    public init(endOfTurn: EndOfTurn = .auto, pause: TimeInterval = 2, sensitivity: Sensitivity = .medium) {
        self.endOfTurn = endOfTurn
        self.pause = Self.pauseChoice(pause)
        self.sensitivity = sensitivity
    }

    static func pauseChoice(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 2 }
        let stepped = (seconds / pauseStep).rounded() * pauseStep
        return min(max(stepped, pauseRange.lowerBound), pauseRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey { case endOfTurn, pause, sensitivity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HandsFreeSettings()
        self.init(endOfTurn: (try? c.decode(EndOfTurn.self, forKey: .endOfTurn)) ?? d.endOfTurn,
                  pause: (try? c.decode(TimeInterval.self, forKey: .pause)) ?? d.pause,
                  sensitivity: (try? c.decode(Sensitivity.self, forKey: .sensitivity)) ?? d.sensitivity)
    }
}

extension VoiceHostSettings {
    /// These settings with a wake phrase that can be listened for: while the wake word is on, a
    /// phrase no model detects (the default "Hey Computer") becomes the first of `phrases`, the
    /// phrases with a model. While it is off the phrase is left as it is, and with no phrases
    /// nothing changes.
    func resolvingWakePhrase(available phrases: [String]) -> VoiceHostSettings {
        guard voice.wakeWordEnabled, let first = phrases.first else { return self }
        let chosen = TriggerPhrase.normalize(voice.wakePhrase)
        guard !phrases.contains(where: { TriggerPhrase.normalize($0) == chosen }) else { return self }
        var resolved = self
        resolved.voice.wakePhrase = first
        return resolved
    }
}
