import AppKit
import HUDKit

/// The tool dock as the HUD summon brings it up and puts it back.
@MainActor
protocol HUDSummonDock: AnyObject {
    /// On: the dock shows on the display holding `point` (nil: its own display), out of its
    /// edge if it is auto-hidden, whether or not `toolDock.enabled` is on, and changes no
    /// setting. Off: it goes back to what its settings say.
    func setSummoned(_ on: Bool, at point: CGPoint?)
    /// The summon has it on screen: summoned, with a button to show.
    var showsForSummon: Bool { get }
    /// Called when the dock's summon ends from the dock's side (it was turned on or off), so
    /// the summon can see whether anything of it is left up.
    var onSummonEnded: (() -> Void)? { get set }
    /// While the wheel is open the dock's hover buttons open nothing, so no panel slides out
    /// over the wheel as the pointer passes them.
    var hoverPaused: Bool { get set }
    /// Where a click leaves the summon up: the dock and the panels open from it.
    var summonKeepFrames: [CGRect] { get }
    /// Apps (bundle ids) any of whose windows a click may land in and leave the summon up: those
    /// with a panel open from the dock, so their menus and popovers count as the panel.
    var summonKeepApps: Set<String> { get }
    /// One of the dock's own menus is open (a right-click, a several-panel button).
    var isMenuOpen: Bool { get }
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
    /// Called after `revealed` changes, whoever changed it.
    var onRevealChange: (() -> Void)? { get set }
    /// Where a click leaves the summon up: the widgets above the windows now.
    var summonKeepFrames: [CGRect] { get }
    /// Apps (bundle ids) whose widgets are above the windows now.
    var summonKeepApps: Set<String> { get }
}

/// A click while a summon is left up, as the watch saw it.
struct HUDSummonClick: Equatable {
    /// Screen coordinates.
    var point: CGPoint
    /// The bundle id of the app owning the topmost window under the click, when known.
    var app: String?
    /// That window is a menu (at the pop-up menu level or above).
    var inMenu = false
}

/// What ends a summon left up: Esc, and a click (the summon decides whether the click was away).
@MainActor
protocol HUDSummonWatch: AnyObject {
    func start(onEscape: @escaping @MainActor () -> Void, onClick: @escaping @MainActor (HUDSummonClick) -> Void)
    func stop()
}

/// Holding the wheel's hotkey summons the HUD: as the wheel opens, the tool dock shows on the
/// wheel's display (even when it is off or auto-hidden) and the desktop widgets are raised above
/// the windows, both above the wheel's scrim (`RadialScrim`). Nothing in the settings changes.
///
/// - Letting go on an action does it and puts the dock and the widgets back as they were:
///   before it, so a capture, a preview or the editor sees the desktop as it is; after it for
///   Apply, so applying a loadout is under way before anything comes down, and for the Widgets
///   actions, which set the widgets themselves (Reveal and Lower leave them as they set them,
///   Edit is on before the summon's raising is lowered).
/// - Letting go on nothing (the centre, Esc, a petal with children) leaves them up, so the
///   dock can be used, as long as something is up (the dock has a button to show, or the
///   summon raised the widgets); they go back on Esc, a click away from the dock, its open
///   panels and their apps' menus and the widgets, a tap of the wheel's hotkey (which opens
///   the search bar), a loadout being applied or `radial dismiss`. Any wheel opening over it,
///   by the hotkey or a script, carries it on.
/// - It ends by itself when nothing of it is left up: the dock turned on or off by hand, the
///   widgets changed by someone else.
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
    var dock: HUDSummonDock? {
        didSet { dock?.onSummonEnded = { [weak self] in self?.somethingWent() } }
    }
    var widgets: HUDSummonWidgets? {
        didSet { widgets?.onRevealChange = { [weak self] in self?.somethingWent() } }
    }
    let watch: HUDSummonWatch
    /// Runs the putting back that follows an action on the main queue's next turn, after the
    /// action has started (and after any main-queue block it scheduled).
    var afterAction: (@escaping @MainActor () -> Void) -> Void = { body in
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
    /// The summon came up (true) or ended (false): Esc then belongs to the summon, not to the
    /// widgets' own Esc-to-lower.
    var onActiveChange: ((Bool) -> Void)?
    /// MacHUD's own bundle id: a click in one of its menus leaves the summon up.
    var ownApp = Bundle.main.bundleIdentifier ?? "com.jrisberg.machud"

    /// The widgets' `revealChanges` just after this summon raised them; nil when it did not.
    private var revealMark: Int?
    /// Counts summons, so a putting back scheduled for one does not end the next.
    private var generation = 0

    init(watch: HUDSummonWatch) {
        self.watch = watch
    }

    var isActive: Bool { phase != .idle }

    /// The summon raised the widgets and they are still up as it left them.
    private var raisedWidgets: Bool {
        guard let revealMark, let widgets else { return false }
        return widgets.revealChanges == revealMark && widgets.revealed
    }

    /// Something of the summon is on screen.
    private var anythingUp: Bool { (dock?.showsForSummon ?? false) || raisedWidgets }

    /// A wheel opened, centred at `point`: on a hold, or over a summon left up (however it was
    /// opened), which carries on under it.
    func wheelOpened(at point: CGPoint?) {
        let starting = phase == .idle
        watch.stop()
        phase = .wheel
        if starting {
            generation &+= 1
            revealMark = nil
            // First, so the widgets' own Esc stands aside before they are raised.
            onActiveChange?(true)
            if let widgets, widgets.servesWidgets, !widgets.revealed {
                widgets.setRevealed(true)
                revealMark = widgets.revealChanges
            }
        }
        dock?.setSummoned(true, at: point)
        dock?.hoverPaused = true
    }

    /// Whether `outcome`'s action runs before the dock and widgets go back: Apply, and the
    /// Widgets actions. Everything else (capture, draw, preview, park) sees the desktop as it is.
    nonisolated static func actsFirst(_ outcome: RadialMenu.Outcome) -> Bool {
        switch outcome {
        case .apply, .widgets: return true
        case .cancelled, .preview, .capture, .drawLayout, .park: return false
        }
    }

    /// The wheel closed on `outcome`: runs `action` (what the outcome does) in its place among
    /// the putting back. Without a summon under the wheel it only runs `action`.
    func wheelClosed(_ outcome: RadialMenu.Outcome, running action: () -> Void = {}) {
        guard phase == .wheel else { action(); return }
        dock?.hoverPaused = false
        if outcome == .cancelled {
            action()
            guard anythingUp else { end(keepingWidgets: false); return }
            phase = .held
            watch.start(onEscape: { [weak self] in self?.dismiss() },
                        onClick: { [weak self] click in self?.clicked(click) })
            return
        }
        var setsWidgets = false
        if case .widgets(edit: false, _) = outcome { setsWidgets = true }
        guard Self.actsFirst(outcome) else {
            end(keepingWidgets: setsWidgets)
            action()
            return
        }
        action()
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

    /// A loadout is about to be applied, however it was asked for: a summon left up ends first,
    /// so the dock goes back to its own display and the loadout's placement of it holds. The
    /// wheel's own Apply puts it back after starting the apply (`wheelClosed`).
    func loadoutWillApply() {
        guard phase == .held else { return }
        dismiss()
    }

    /// A click while the summon is left up: away from the dock, its open panels (and any window
    /// of their apps, so their menus and popovers), the dock's own menus and the raised
    /// widgets, it ends the summon.
    func clicked(_ click: HUDSummonClick) {
        guard phase == .held else { return }
        let frames = (dock?.summonKeepFrames ?? []) + (widgets?.summonKeepFrames ?? [])
        if frames.contains(where: { $0.contains(click.point) }) { return }
        if dock?.isMenuOpen == true { return }
        if let app = click.app {
            let apps = (dock?.summonKeepApps ?? []).union(widgets?.summonKeepApps ?? [])
            if apps.contains(app) { return }
            if click.inMenu, app == ownApp { return }
        }
        dismiss()
    }

    /// The dock's summon ended from its side, or the widgets changed: a summon left up with
    /// nothing of it on screen ends, giving Esc and the clicks back.
    private func somethingWent() {
        guard phase == .held, !anythingUp else { return }
        end(keepingWidgets: false)
    }

    /// Whether the widgets are revealed as the user left them, the summon's own raising aside:
    /// what the wheel's Widgets petal offers to change.
    func userRevealed(_ current: Bool) -> Bool {
        guard let revealMark, let widgets, widgets.revealChanges == revealMark else { return current }
        return false
    }

    private func end(keepingWidgets: Bool) {
        let lower = !keepingWidgets && raisedWidgets
        revealMark = nil
        phase = .idle
        watch.stop()
        dock?.setSummoned(false, at: nil)
        if lower { widgets?.setRevealed(false) }
        onActiveChange?(false)
    }

    var json: [String: Any] {
        var d: [String: Any] = ["active": isActive, "phase": phase.rawValue]
        if isActive { d["raisedWidgets"] = raisedWidgets }
        return d
    }
}

extension ToolDock: HUDSummonDock {}

/// The live `HUDSummonWatch`: a click anywhere, in MacHUD's own windows or another app's (mouse
/// monitors need no permission), with the app owning the window under it (the window list's
/// owner and level, which need no permission either), and Esc as a hotkey of its own while the
/// summon is left up (Carbon hotkeys need no Accessibility, and take the key from the app in
/// front). An isolated instance (`MACHUD_NO_HOTKEYS`) takes no Esc, so it never steals the key
/// from the user's own MacHUD; its summon goes on a click or `radial dismiss`.
@MainActor
final class HUDSummonEvents: HUDSummonWatch {
    private var monitors: [Any] = []
    private var escapeID: UInt32?
    var takesEscape = !Env.noHotkeys

    func start(onEscape: @escaping @MainActor () -> Void, onClick: @escaping @MainActor (HUDSummonClick) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { onClick(Self.click(at: NSEvent.mouseLocation)) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { onClick(Self.click(at: NSEvent.mouseLocation)) }
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

    /// The click at `point` (screen coordinates) with the topmost on-screen window under it.
    static func click(at point: CGPoint) -> HUDSummonClick {
        let primary = NSScreen.screens.first?.frame.maxY ?? 0
        let flipped = CGPoint(x: point.x, y: primary - point.y)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for info in list {
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.contains(flipped),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return HUDSummonClick(point: point, app: app, inMenu: layer >= menuLevel)
        }
        return HUDSummonClick(point: point)
    }
}
