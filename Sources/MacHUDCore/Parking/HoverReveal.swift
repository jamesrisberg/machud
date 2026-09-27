import Foundation

/// Hover-to-reveal as a pure state machine, fed the mouse position every tick. Used by
/// the parking orbs, the tool dock's hover buttons and its auto-hide: resting on the
/// trigger (orb, dock button) for `hoverDelay` reveals; leaving the revealed area (the
/// revealed windows plus the trigger) for `leaveDelay` conceals; a click pins the reveal
/// until the next click.
struct HoverReveal: Equatable {
    enum Phase: Equatable {
        case concealed
        /// Mouse on the trigger since `since`, not yet long enough to reveal.
        case arming(since: TimeInterval)
        case revealed
        /// Mouse outside the revealed area since `since`.
        case leaving(since: TimeInterval)
        /// Clicked open: stays revealed whatever the mouse does.
        case pinned
        /// Clicked shut while on the trigger: the mouse must leave the trigger before
        /// hovering can reveal again, or unpinning would immediately re-reveal.
        case dismissed
    }

    enum Action: Equatable { case reveal, conceal }

    static let hoverDelay: TimeInterval = 0.15
    static let leaveDelay: TimeInterval = 0.6

    /// How long the mouse must rest on the trigger before revealing.
    var hoverDelay: TimeInterval = Self.hoverDelay
    /// How long the mouse must stay outside the revealed area before concealing.
    var leaveDelay: TimeInterval = Self.leaveDelay

    private(set) var phase: Phase = .concealed

    init(hoverDelay: TimeInterval = Self.hoverDelay, leaveDelay: TimeInterval = Self.leaveDelay) {
        self.hoverDelay = hoverDelay
        self.leaveDelay = leaveDelay
    }

    var isRevealed: Bool {
        switch phase {
        case .revealed, .leaving, .pinned: return true
        case .concealed, .arming, .dismissed: return false
        }
    }

    var isPinned: Bool { phase == .pinned }

    /// `onTrigger`: the mouse is over the trigger. `inside`: over the trigger or the
    /// revealed windows.
    mutating func update(onTrigger: Bool, inside: Bool, now: TimeInterval) -> Action? {
        switch phase {
        case .concealed:
            if onTrigger {
                phase = .arming(since: now)
                // A zero delay reveals on the first tick.
                if hoverDelay <= 0 { phase = .revealed; return .reveal }
            }
        case .arming(let since):
            if !onTrigger {
                phase = .concealed
            } else if now - since >= hoverDelay {
                phase = .revealed
                return .reveal
            }
        case .revealed:
            if !inside { phase = .leaving(since: now) }
        case .leaving(let since):
            if inside {
                phase = .revealed
            } else if now - since >= leaveDelay {
                phase = .concealed
                return .conceal
            }
        case .pinned:
            break
        case .dismissed:
            if !onTrigger { phase = .concealed }
        }
        return nil
    }

    /// The orb's name for `update(onTrigger:inside:now:)`.
    mutating func update(onOrb: Bool, inside: Bool, now: TimeInterval) -> Action? {
        update(onTrigger: onOrb, inside: inside, now: now)
    }

    mutating func click() -> Action? {
        switch phase {
        case .concealed, .arming, .dismissed:
            phase = .pinned
            return .reveal
        case .revealed, .leaving:
            phase = .pinned
            return nil
        case .pinned:
            phase = .dismissed
            return .conceal
        }
    }

    /// Reveal from outside (socket, radial menu). `pin` keeps it open like a click.
    mutating func reveal(pin: Bool) -> Action? {
        let was = isRevealed
        phase = pin ? .pinned : .revealed
        return was ? nil : .reveal
    }

    mutating func conceal() -> Action? {
        let was = isRevealed
        phase = .concealed
        return was ? .conceal : nil
    }
}

/// The parking orb's hover: the original name of `HoverReveal`.
typealias OrbHover = HoverReveal
