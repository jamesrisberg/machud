import Foundation

/// Menu bar management as a pure state machine. Time is passed in (`now`, seconds on any
/// monotonic clock) and the owner feeds `update` from a poll, so every timer is testable.
///
/// - `expanded`: every status item shows. With `autoCollapseSeconds > 0` it collapses after
///   that long with the mouse out of the menu bar and no menu open.
/// - `collapsed`: the items left of the separator are pushed off the menu bar. Resting on the
///   expander for `hoverDelay` peeks.
/// - `peeking`: expanded for now; leaving the menu bar for `leaveDelay` (after any `hold`)
///   collapses again. A click or the hotkey turns a peek into a real expand.
///
/// While a menu is open (a revealed item's menu, MacHUD's own) nothing collapses on its own.
struct MenuBarState: Equatable {
    enum Mode: String, Equatable { case expanded, collapsed, peeking }

    /// A change the owner must make to the status items.
    enum Effect: Equatable {
        /// Show the hidden items (shrink the separator).
        case show
        /// Hide them (stretch the separator).
        case hide
    }

    /// Same timings as the parking orb.
    static let hoverDelay = HoverReveal.hoverDelay
    static let leaveDelay = HoverReveal.leaveDelay

    private(set) var mode: Mode = .expanded
    /// 0 turns auto-collapse off.
    var autoCollapseSeconds: TimeInterval = 0
    private(set) var menuOpen = false

    /// Mouse on the expander while collapsed, since.
    private var armingSince: TimeInterval?
    /// Mouse outside the menu bar while peeking, since.
    private var leavingSince: TimeInterval?
    /// A socket peek stays up at least until then.
    private var holdUntil: TimeInterval?
    /// Start of the current auto-collapse countdown.
    private var idleSince: TimeInterval?
    /// Collapsed by a click with the mouse on the expander: it must leave the expander before
    /// hovering can peek again, or the click would be undone at once.
    private var dismissed = false

    init(mode: Mode = .expanded, autoCollapseSeconds: TimeInterval = 0) {
        self.mode = mode
        self.autoCollapseSeconds = autoCollapseSeconds
    }

    /// The hidden items are on the menu bar (expanded or peeking).
    var itemsVisible: Bool { mode != .collapsed }

    /// When auto-collapse would fire if nothing else happens, for reporting and tests.
    var autoCollapseDeadline: TimeInterval? {
        guard mode == .expanded, autoCollapseSeconds > 0, !menuOpen, let idleSince else { return nil }
        return idleSince + autoCollapseSeconds
    }

    // MARK: - Commands (socket, hotkey, menu, click)

    mutating func expand(now: TimeInterval) -> Effect? {
        let was = itemsVisible
        mode = .expanded
        resetTimers(now: now)
        return was ? nil : .show
    }

    /// `onExpander`: the command came from a click on the expander (the mouse is on it).
    mutating func collapse(now: TimeInterval, onExpander: Bool = false) -> Effect? {
        let was = itemsVisible
        mode = .collapsed
        resetTimers(now: now)
        dismissed = onExpander
        return was ? .hide : nil
    }

    /// Hotkey and expander click: a peek or a collapse becomes a real expand, an expand
    /// collapses.
    mutating func toggle(now: TimeInterval, onExpander: Bool = false) -> Effect? {
        mode == .expanded ? collapse(now: now, onExpander: onExpander) : expand(now: now)
    }

    /// Show the hidden items until the mouse has been out of the menu bar for `leaveDelay`,
    /// and at least `hold` seconds. No-op while expanded.
    mutating func peek(now: TimeInterval, hold: TimeInterval = 0) -> Effect? {
        guard mode != .expanded else { return nil }
        let was = itemsVisible
        mode = .peeking
        resetTimers(now: now)
        holdUntil = hold > 0 ? now + hold : nil
        return was ? nil : .show
    }

    /// A menu opened or closed. Closing restarts the countdowns, so nothing collapses
    /// the instant a menu goes away.
    mutating func setMenuOpen(_ open: Bool, now: TimeInterval) {
        guard open != menuOpen else { return }
        menuOpen = open
        if !open {
            idleSince = now
            leavingSince = nil
        }
    }

    // MARK: - Poll

    /// `onExpander`: the mouse is over the expander item. `inBar`: over the menu bar strip.
    mutating func update(onExpander: Bool, inBar: Bool, now: TimeInterval) -> Effect? {
        if dismissed && !onExpander { dismissed = false }
        switch mode {
        case .collapsed:
            guard onExpander, !dismissed else { armingSince = nil; return nil }
            guard let since = armingSince else { armingSince = now; return nil }
            if now - since >= Self.hoverDelay {
                mode = .peeking
                resetTimers(now: now)
                return .show
            }
        case .peeking:
            if menuOpen || inBar || onExpander || (holdUntil.map { now < $0 } ?? false) {
                leavingSince = nil
                return nil
            }
            guard let since = leavingSince else { leavingSince = now; return nil }
            if now - since >= Self.leaveDelay {
                mode = .collapsed
                resetTimers(now: now)
                return .hide
            }
        case .expanded:
            if menuOpen || inBar { idleSince = now; return nil }
            if let deadline = autoCollapseDeadline, now >= deadline {
                mode = .collapsed
                resetTimers(now: now)
                return .hide
            }
        }
        return nil
    }

    private mutating func resetTimers(now: TimeInterval) {
        armingSince = nil
        leavingSince = nil
        holdUntil = nil
        idleSince = now
        dismissed = false
    }
}
