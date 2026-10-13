import AppKit
import HUDKit

/// The tool dock as the HUD summon brings it up and puts it back.
@MainActor
protocol HUDSummonDock: AnyObject {
    /// On: the dock shows on the display holding `point` (nil: its own display), out of its
    /// edge if it is auto-hidden, whether or not `toolDock.enabled` is on, and changes no
    /// setting. Off: it goes back to what its settings say.
    func setSummoned(_ on: Bool, at point: CGPoint?)
    /// While the wheel is open the dock's hover buttons open nothing, so no panel slides out
    /// over the wheel as the pointer passes them.
    var hoverPaused: Bool { get set }
    /// Where a click leaves the summon up: the dock and the panels open from it.
    var summonKeepFrames: [CGRect] { get }
}

/// The desktop widgets as the HUD summon raises and lowers them.
@MainActor
protocol HUDSummonWidgets: AnyObject {
    /// Some app serves widgets.
    var servesWidgets: Bool { get }
    var revealed: Bool { get }
    /// Counts the changes to `revealed`, so the summon can tell whether anyone else changed it
    /// after it raised the widgets.
    var revealChanges: Int { get }
    func setRevealed(_ on: Bool)
    /// Where a click leaves the summon up: the placed widgets.
    var summonKeepFrames: [CGRect] { get }
}

/// What ends a summon left up: Esc, and a click (the summon decides whether the click was away).
@MainActor
protocol HUDSummonWatch: AnyObject {
    func start(onEscape: @escaping @MainActor () -> Void, onClick: @escaping @MainActor (CGPoint) -> Void)
    func stop()
}

/// Holding the wheel's hotkey summons the HUD: as the wheel opens, the tool dock shows on the
/// wheel's display (even when it is off or auto-hidden) and the desktop widgets are raised above
/// the windows, both above the wheel's scrim (`RadialScrim`). Nothing in the settings changes.
///
/// - Letting go on an action does it, then puts the dock and the widgets back as they were. A
///   Widgets Reveal or Lower sets the widgets itself, so they are left as it set them.
/// - Letting go on nothing (the centre, Esc, a petal with children) leaves them up, so the
///   dock can be used; they go back on Esc, a click away from the dock, its open panels and
///   the widgets, a tap of the wheel's hotkey (which opens the search bar) or `radial
///   dismiss`. Holding the hotkey again opens the wheel over the same summon.
/// - The widgets go back down only if the summon raised them and nobody changed them since
///   (`revealChanges`); widgets revealed before the summon stay revealed.
@MainActor
final class HUDSummon {
    enum Phase: String {
        case idle
        /// The wheel is open over the summon.
        case wheel
        /// The wheel let go on nothing: the dock and widgets stay up until dismissed.
        case held
    }

    private(set) var phase: Phase = .idle
    var dock: HUDSummonDock?
    var widgets: HUDSummonWidgets?
    let watch: HUDSummonWatch
    /// Runs the putting back after the action the wheel was let go on, which the wheel starts
    /// on the main queue's next turn at the earliest: so a loadout is applied, or the widgets'
    /// edit mode turned on, before the dock and widgets come down.
    var afterAction: (@escaping @MainActor () -> Void) -> Void = { body in
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
    /// The summon came up (true) or ended (false): Esc then belongs to the summon, not to the
    /// widgets' own Esc-to-lower.
    var onActiveChange: ((Bool) -> Void)?

    /// The widgets' `revealChanges` just after this summon raised them; nil when it did not.
    private var revealMark: Int?
    /// Counts summons, so a putting back scheduled for one does not end the next.
    private var generation = 0

    init(watch: HUDSummonWatch) {
        self.watch = watch
    }

    var isActive: Bool { phase != .idle }

    /// The wheel opened on a hold, centred at `point`. A summon left up carries on under it.
    func wheelOpened(at point: CGPoint?) {
        let starting = phase == .idle
        watch.stop()
        phase = .wheel
        if starting {
            generation &+= 1
            revealMark = nil
            if let widgets, widgets.servesWidgets, !widgets.revealed {
                widgets.setRevealed(true)
                revealMark = widgets.revealChanges
            }
            onActiveChange?(true)
        }
        dock?.setSummoned(true, at: point)
        dock?.hoverPaused = true
    }

    /// The wheel closed on `outcome`, after its action was started.
    func wheelClosed(_ outcome: RadialMenu.Outcome) {
        guard phase == .wheel else { return }
        dock?.hoverPaused = false
        guard outcome != .cancelled else {
            phase = .held
            watch.start(onEscape: { [weak self] in self?.dismiss() },
                        onClick: { [weak self] point in self?.clicked(at: point) })
            return
        }
        var setsWidgets = false
        if case .widgets(edit: false, _) = outcome { setsWidgets = true }
        let ending = generation
        afterAction { [weak self] in
            guard let self, self.generation == ending, self.phase == .wheel else { return }
            self.end(keepingWidgets: setsWidgets)
        }
    }

    /// Esc, a click away, a tap of the hotkey, `radial dismiss`: the dock and widgets go back.
    func dismiss() {
        guard phase != .idle else { return }
        dock?.hoverPaused = false
        end(keepingWidgets: false)
    }

    /// A click at `point` (screen coordinates) while the summon is left up: away from the dock,
    /// its open panels and the widgets, it ends the summon.
    func clicked(at point: CGPoint) {
        guard phase == .held else { return }
        let keep = (dock?.summonKeepFrames ?? []) + (widgets?.summonKeepFrames ?? [])
        guard !keep.contains(where: { $0.contains(point) }) else { return }
        dismiss()
    }

    /// Whether the widgets are revealed as the user left them, the summon's own raising aside:
    /// what the wheel's Widgets petal offers to change.
    func userRevealed(_ current: Bool) -> Bool {
        guard let revealMark, let widgets, widgets.revealChanges == revealMark else { return current }
        return false
    }

    private func end(keepingWidgets: Bool) {
        let mark = revealMark
        revealMark = nil
        phase = .idle
        watch.stop()
        dock?.setSummoned(false, at: nil)
        if !keepingWidgets, let mark, let widgets, widgets.revealChanges == mark, widgets.revealed {
            widgets.setRevealed(false)
        }
        onActiveChange?(false)
    }

    var json: [String: Any] {
        var d: [String: Any] = ["active": isActive, "phase": phase.rawValue]
        if isActive { d["raisedWidgets"] = revealMark != nil && widgets?.revealChanges == revealMark }
        return d
    }
}

extension ToolDock: HUDSummonDock {}

/// The live `HUDSummonWatch`: a click anywhere, in MacHUD's own windows or another app's (mouse
/// monitors need no permission), and Esc as a hotkey of its own while the summon is left up
/// (Carbon hotkeys need no Accessibility either, and take the key from the app in front). An
/// isolated instance (`MACHUD_NO_HOTKEYS`) takes no Esc, so it never steals the key from the
/// user's own MacHUD; its summon goes on a click or `radial dismiss`.
@MainActor
final class HUDSummonEvents: HUDSummonWatch {
    private var monitors: [Any] = []
    private var escapeID: UInt32?
    var takesEscape = !Env.noHotkeys

    func start(onEscape: @escaping @MainActor () -> Void, onClick: @escaping @MainActor (CGPoint) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { onClick(NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { onClick(NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
        if takesEscape {
            escapeID = HotKeyCenter.shared.register(HotKey(key: "escape", modifiers: []), onPress: {
                MainActor.assumeIsolated { onEscape() }
            })
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let id = escapeID { HotKeyCenter.shared.unregister(id) }
        escapeID = nil
    }
}
