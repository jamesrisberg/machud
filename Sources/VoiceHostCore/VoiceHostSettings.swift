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
    public var voice: VoiceSettings

    public init(enabled: Bool = true, keyMode: KeyMode = .hold, agentGesture: Bool = true,
                brainEnabled: Bool = true, brainPort: Int = 8791,
                brain: BrainSettings = BrainSettings(), voice: VoiceSettings = VoiceSettings()) {
        self.enabled = enabled
        self.keyMode = keyMode
        self.agentGesture = agentGesture
        self.brainEnabled = brainEnabled
        self.brainPort = brainPort
        self.brain = brain
        self.voice = voice
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
        voice = (try? c.decode(VoiceSettings.self, forKey: .voice)) ?? d.voice
    }
}
