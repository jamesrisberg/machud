import Foundation

enum OrbForm: Equatable {
    /// The round orb (resting, agent, working, speaking).
    case orb
    /// Stretched sideways into the dictation waveform body.
    case waveform
}

enum OrbTint: Equatable, CaseIterable {
    case resting, muted, dictation, agent, working, approval, speaking, failed
}

enum OrbMotion: Equatable {
    case none
    /// Waveform bars from the level history.
    case bars
    /// SpeakFree's transcribing spinner inside the waveform body.
    case spinner
    /// The orb grows with the input level.
    case pulse
    /// A highlight circles the rim.
    case spin
    /// A slow glow.
    case breathe
}

/// What the orb and card show for one moment: the state mapped through the presenter's
/// few display rules (failure display time, card linger, hover peek).
struct OrbScene: Equatable {
    var hidden: Bool
    var form: OrbForm
    var tint: OrbTint
    var motion: OrbMotion
    /// VoiceOver value for the orb.
    var accessibilityStatus: String
    /// The card to show, nil when it is folded away.
    var card: VoiceCard?
    /// A failure message shown under the orb.
    var errorMessage: String?
    var muted = false

    init(hidden: Bool, form: OrbForm, tint: OrbTint, motion: OrbMotion, accessibilityStatus: String,
         card: VoiceCard? = nil, errorMessage: String? = nil, muted: Bool = false) {
        self.hidden = hidden
        self.form = form
        self.tint = tint
        self.motion = motion
        self.accessibilityStatus = accessibilityStatus
        self.card = card
        self.errorMessage = errorMessage
        self.muted = muted
    }
}

/// Maps `VoiceHostState` to an `OrbScene`. The controller owns every piece of voice state; the
/// tracker only keeps the display timing the state cannot carry: when a failure appeared (it
/// shows for `failureDisplay`), when an agent turn ended (the card lingers for `cardLinger`),
/// and whether the pointer is over the orb or card (hover peeks the last card).
struct OrbSceneTracker {
    static let failureDisplay: TimeInterval = 3
    static let cardLinger: TimeInterval = 8
    static let hoverGrace: TimeInterval = 0.4

    private(set) var state = VoiceHostState()
    private var failureShownAt: Date?
    private var cardLingerUntil: Date?
    private var hovering = false
    private var hoverGraceUntil: Date?

    mutating func ingest(_ new: VoiceHostState, now: Date) {
        let old = state
        state = new
        if case .failed = new.phase {
            if new.phase != old.phase { failureShownAt = now }
        } else {
            failureShownAt = nil
        }
        if new.card == nil || Self.isTake(new.phase) {
            cardLingerUntil = nil
        } else if Self.isTurn(new.phase) {
            cardLingerUntil = nil
        } else if Self.isTurn(old.phase) {
            cardLingerUntil = now.addingTimeInterval(Self.cardLinger)
        }
    }

    mutating func setHovering(_ hovering: Bool, now: Date) {
        if self.hovering && !hovering { hoverGraceUntil = now.addingTimeInterval(Self.hoverGrace) }
        if hovering { hoverGraceUntil = nil }
        self.hovering = hovering
    }

    func scene(now: Date) -> OrbScene {
        var phase = state.phase
        var errorMessage: String?
        if case .failed(let message) = phase {
            if let shown = failureShownAt, now.timeIntervalSince(shown) < Self.failureDisplay {
                errorMessage = message
            } else {
                phase = .idle
            }
        }
        var scene = Self.map(phase, muted: state.muted)
        scene.errorMessage = errorMessage
        scene.muted = state.muted
        if state.hiddenForFullScreen {
            scene.hidden = true
            scene.errorMessage = nil
            return scene
        }
        scene.card = showsCard(phase: phase, now: now) ? state.card : nil
        return scene
    }

    /// The next moment the scene changes without a new state (a failure or linger expiring,
    /// hover grace ending), so the presenter can re-render then.
    func nextDeadline(now: Date) -> Date? {
        var deadlines: [Date] = []
        if let shown = failureShownAt { deadlines.append(shown.addingTimeInterval(Self.failureDisplay)) }
        if state.card != nil, let linger = cardLingerUntil { deadlines.append(linger) }
        if let grace = hoverGraceUntil { deadlines.append(grace) }
        return deadlines.filter { $0 > now }.min()
    }

    private func showsCard(phase: VoicePhase, now: Date) -> Bool {
        guard state.card != nil, !Self.isTake(phase) else { return false }
        if Self.isTurn(phase) { return true }
        if let linger = cardLingerUntil, now < linger { return true }
        if hovering { return true }
        if let grace = hoverGraceUntil, now < grace { return true }
        return false
    }

    /// Recording or transcribing a new take: the old card folds away.
    private static func isTake(_ phase: VoicePhase) -> Bool {
        switch phase {
        case .listening, .transcribing: return true
        default: return false
        }
    }

    /// The brain is on a turn: the card is open.
    private static func isTurn(_ phase: VoicePhase) -> Bool {
        switch phase {
        case .working, .awaitingApproval, .speaking: return true
        default: return false
        }
    }

    static func map(_ phase: VoicePhase, muted: Bool) -> OrbScene {
        func s(_ form: OrbForm, _ tint: OrbTint, _ motion: OrbMotion, _ status: String) -> OrbScene {
            OrbScene(hidden: false, form: form, tint: tint, motion: motion, accessibilityStatus: status)
        }
        switch phase {
        case .idle: return muted ? s(.orb, .muted, .none, "Muted") : s(.orb, .resting, .none, "Ready")
        case .listening(.dictation): return s(.waveform, .dictation, .bars, "Dictating")
        case .transcribing(.dictation): return s(.waveform, .dictation, .spinner, "Transcribing")
        case .listening(.agent): return s(.orb, .agent, .pulse, "Listening")
        case .transcribing(.agent): return s(.orb, .agent, .spin, "Transcribing")
        case .working: return s(.orb, .working, .spin, "Working")
        case .awaitingApproval: return s(.orb, .approval, .breathe, "Waiting for approval")
        case .speaking: return s(.orb, .speaking, .breathe, "Speaking")
        case .failed(let message): return s(.orb, .failed, .none, "Error: \(message)")
        }
    }
}

/// Fixed-length history of input levels for the waveform, oldest first.
struct LevelHistory: Equatable {
    private(set) var values: [Double]

    init(capacity: Int = OrbLayout.barCount) {
        values = Array(repeating: 0, count: capacity)
    }

    mutating func append(_ level: Double) {
        guard !values.isEmpty else { return }
        values.removeFirst()
        values.append(min(max(level, 0), 1))
    }

    mutating func reset() {
        values = Array(repeating: 0, count: values.count)
    }
}

/// Text trimming for the card, which has a fixed height budget.
enum OrbCardText {
    static let replyLimit = 900
    static let progressLimit = 3

    /// The end of a long reply (the part being spoken or streamed), led by an ellipsis.
    static func replyTail(_ reply: String, limit: Int = replyLimit) -> String {
        guard reply.count > limit else { return reply }
        var tail = String(reply.suffix(limit))
        if let space = tail.firstIndex(of: " "), tail.distance(from: tail.startIndex, to: space) < 40 {
            tail = String(tail[tail.index(after: space)...])
        }
        return "…" + tail
    }

    static func progressTail(_ lines: [String], limit: Int = progressLimit) -> [String] {
        Array(lines.suffix(limit))
    }
}
