import AppKit
import HUDKit

/// The notch orb: a small plain orb centered just under the notch (hanging from the menu bar
/// on a screen without one), always visible, that breathes and floats gently while it rests,
/// stretches into SpeakFree's waveform body while dictating, pulses while the agent listens,
/// and grows its reply card out of itself (and folds it back in).
///
/// Renders purely from `VoiceHostState` and the conversation; user input goes back through
/// `VoiceHostActing`. Borderless non-activating panels at `HUDPanelWindow.notchAnchorLevel`:
/// one for the orb (resized with the shape each frame), one for the card's peek, one for the
/// pinned or expanded conversation, and the scrim behind the expanded one. Only the orb and the
/// card take mouse events while nothing is expanded; the rest of the screen's top edge stays
/// clickable.
///
/// The card's states (`VoiceCardMode`) are the controller's: the pointer over the card (peek or
/// pinned) is reported as `cardHovered`, a click as `cardClicked`, Esc and the scrim as a
/// return to `peek`. The expanded panel takes key status without activating the voice host
/// (a non-activating panel made key), and the app that was in front gets the keyboard back
/// when it collapses.
///
/// The orb is shown unless a full-screen app hides it (`hiddenForFullScreen`). `OrbPresence`
/// shows and hides its window and logs each with its reason; once a Space change, wake or screen
/// change has settled (`HUDEnvironmentMonitor`) the screen is read again after a wake or screen
/// change, and the window is put back in step with that intent if it drifted.
@MainActor
public final class VoiceOrbPresenter: VoiceHostPresenting {
    /// The screen the orb is on: the one with a notch, else the menu-bar screen. The
    /// full-screen observer watches this screen.
    public private(set) var screen: NSScreen?

    private weak var actions: VoiceHostActing?
    private var tracker = OrbSceneTracker()
    private var scene: OrbScene
    private var animator = OrbAnimator()
    private var history = LevelHistory()
    private var geometry: HUDNotchGeometry
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    let orbWindow: HUDPanelWindow
    private let orbView: OrbView
    let cardWindow: HUDPanelWindow
    private let cardView = OrbCardView(frame: .zero)
    /// The card window is on screen (open, growing, or folding back into the orb).
    private var cardShown = false
    let conversationWindow: HUDPanelWindow
    private let conversationView = ConversationPanelView(frame: .zero)
    let scrimWindow: HUDPanelWindow
    private let scrimView = ConversationScrimView(frame: .zero)
    /// The conversation as the controller last rendered it.
    private var rows: [ConversationRow] = []
    /// The conversation's mode on screen; nil while it is not shown.
    private var shownConversation: VoiceCardMode?
    private var conversationHovered = false
    /// The card hover last sent to the controller.
    private var reportedCardHover = false
    /// The app in front when the conversation expanded, which gets the keyboard back.
    private var previousApp: NSRunningApplication?
    /// Set while the expanded conversation collapses, when giving up key status is expected.
    private var collapsing = false
    private var cardGrow = CardGrow()
    /// Shows, hides and reconciles the orb's window.
    private lazy var presence = OrbPresence(window: orbWindow, fade: { [weak self] alpha, done in
        guard let self else { return }
        self.fade(self.orbWindow, to: alpha, completion: done)
    }, log: log)
    /// The orb is meant to be on screen.
    private var visible: Bool { presence.isShown }
    /// Where the orb's lines go (`OrbLog`, the unified log).
    private let log: (String) -> Void

    private var displayTimer: Timer?
    private var lastTick = Date()
    private var deadlineTimer: Timer?
    private var orbHovered = false
    private var cardHovered = false
    private var observers: [NSObjectProtocol] = []
    private var settled: HUDEnvironmentMonitor.Observation?

    public convenience init(actions: VoiceHostActing) {
        self.init(actions: actions, log: OrbLog.notice)
    }

    init(actions: VoiceHostActing, log: @escaping (String) -> Void) {
        self.actions = actions
        self.log = log
        let screen = Self.orbScreen()
        self.screen = screen
        geometry = screen.map(HUDNotchGeometry.init(screen:))
            ?? HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        scene = tracker.scene(now: Date())

        let size = OrbLayout.windowSize(stretch: 0, geometry: geometry)
        orbWindow = Self.makePanel("voice-orb", size: size)
        orbWindow.hasShadow = false
        orbView = OrbView(frame: CGRect(origin: .zero, size: size), geometry: geometry)
        orbView.autoresizingMask = [.width, .height]
        orbWindow.contentView = orbView
        orbWindow.setAccessibilityLabel("Voice assistant")

        cardWindow = Self.makePanel("voice-card", size: CGSize(width: OrbLayout.cardWidth, height: 1))
        cardWindow.contentView = cardView
        cardWindow.setAccessibilityLabel("Voice assistant reply")

        conversationWindow = Self.makePanel("voice-conversation",
                                            size: CGSize(width: OrbLayout.pinnedWidth, height: OrbLayout.pinnedMinHeight))
        conversationView.autoresizingMask = [.width, .height]
        conversationWindow.contentView = conversationView
        conversationWindow.setAccessibilityLabel("Conversation with the agent")
        scrimWindow = Self.makePanel("voice-scrim", size: geometry.screenFrame.size)
        scrimWindow.hasShadow = false
        scrimView.autoresizingMask = [.width, .height]
        scrimWindow.contentView = scrimView
        scrimWindow.setAccessibilityLabel("Close the conversation")

        wireInput()
        observeEnvironment()
        presence.anchor(screenID: screen.map(HUDScreenSnapshot.id(for:)), geometry: geometry, reason: "start")
    }

    public func render(_ state: VoiceHostState) {
        let now = Date()
        let wasDictating = tracker.state.phase == .listening(.dictation)
        tracker.ingest(state, now: now)
        if state.phase == .listening(.dictation) {
            if !wasDictating { history.reset() }
            history.append(state.inputLevel)
        }
        apply(now: now)
    }

    public func renderConversation(_ rows: [ConversationRow]) {
        self.rows = rows
        refreshConversation(force: true)
    }

    public func renderFullScreenEvidence(_ evidence: VoiceFullScreenEvidence?) {
        presence.fullScreenEvidence = evidence
    }

    // MARK: Scene

    private func apply(now: Date) {
        scene = tracker.scene(now: now)
        orbView.scene = scene
        orbView.history = history
        orbView.reduceMotion = reduceMotion
        presence.apply(hidden: scene.hidden)
        applyConversation(now: now)
        applyCard()
        layoutOrb()
        startDisplayTimerIfNeeded()
        scheduleDeadline(now: now)
    }

    /// The card grows out of the orb and folds back into it, driven by `cardGrow` from the
    /// display timer. The window frame is never animated: it jumps to cover the orb and the
    /// card while the shape travels, and to the card alone once it is open, and the card view
    /// keeps its content in the card's place throughout. Under Reduce Motion the card fades in
    /// and out where it stands.
    private func applyCard() {
        if scene.showsConversation, cardShown {
            // The conversation took the card's place.
            cardShown = false
            cardHovered = false
            cardGrow.jump(to: 0)
            cardWindow.orderOut(nil)
        }
        let wantsCard = visible && !scene.showsConversation && (scene.card != nil || scene.errorMessage != nil)
        if wantsCard, cardView.card != scene.card || cardView.errorMessage != scene.errorMessage
            || cardView.sessionLink != scene.sessionLink {
            cardView.update(card: scene.card, errorMessage: scene.errorMessage, sessionLink: scene.sessionLink)
        }
        // A message alone is informational; clicks go through to the window underneath.
        cardWindow.ignoresMouseEvents = scene.card == nil
        cardGrow.target = wantsCard ? 1 : 0
        if wantsCard && !cardShown {
            cardShown = true
            cardWindow.alphaValue = reduceMotion ? 0 : 1
            layoutCard()
            cardWindow.orderFrontRegardless()
            // Same level: the orb stays above the card where the growing shape passes under it.
            if visible { orbWindow.orderFrontRegardless() }
            if reduceMotion { fade(cardWindow, to: 1) }
        } else if !wantsCard, cardShown, reduceMotion {
            cardShown = false
            cardHovered = false
            fade(cardWindow, to: 0) { [weak self] in
                guard let self, !self.cardShown else { return }
                self.cardWindow.orderOut(nil)
            }
        }
        layoutCard()
    }

    /// Places the card window and shape for the grow's progress; puts the window away once the
    /// card has folded back into the orb.
    private func layoutCard() {
        guard cardShown else { return }
        if !reduceMotion, cardGrow.target == 0, cardGrow.progress == 0 {
            cardShown = false
            cardHovered = false
            cardWindow.orderOut(nil)
            return
        }
        let card = OrbLayout.cardFrame(size: cardView.fittingCardSize, geometry: geometry)
        let orb = OrbLayout.orbFrame(geometry: geometry, bob: animator.bobOffset)
        let frame = cardView.layoutGrow(progress: reduceMotion ? 1 : cardGrow.progress, card: card, orb: orb)
        if cardWindow.frame != frame { cardWindow.setFrame(frame, display: true) }
    }

    // MARK: Conversation

    /// Shows, changes or puts away the pinned or expanded conversation to match the scene.
    private func applyConversation(now: Date) {
        let wanted: VoiceCardMode? = visible && scene.showsConversation ? scene.cardMode : nil
        guard wanted != shownConversation else { return refreshConversation(force: false) }
        let old = shownConversation
        shownConversation = wanted
        if old == .expanded, wanted != .expanded { endExpanded(keepWindow: wanted != nil) }
        let mouse = NSEvent.mouseLocation
        guard let wanted else {
            fade(conversationWindow, to: 0) { [weak self] in
                guard let self, self.shownConversation == nil else { return }
                self.conversationWindow.orderOut(nil)
            }
            conversationHovered = false
            // The card the conversation grew from is put back where it was, then follows the
            // peek's rules (it folds into the orb once nothing keeps it open).
            if visible, scene.card != nil || scene.errorMessage != nil { cardGrow.jump(to: 1) }
            syncHover(now: now)
            return
        }
        let start = old == nil && cardShown ? cardWindow.frame : conversationWindow.frame
        refreshConversation(force: true, animated: false)
        let target = conversationWindow.frame
        if old == nil {
            // Grows out of the card it replaces, or appears where it goes.
            conversationWindow.setFrame(cardShown && !reduceMotion ? start : target, display: false)
            conversationView.assumesPointerInside = target.contains(mouse) || start.contains(mouse)
            conversationView.updateTrackingAreas()
            conversationWindow.alphaValue = reduceMotion ? 0 : 1
            conversationWindow.orderFrontRegardless()
            if reduceMotion { fade(conversationWindow, to: 1) }
            setConversationFrame(target, animated: true)
        } else {
            setConversationFrame(target, animated: true)
        }
        conversationHovered = target.contains(mouse) || conversationWindow.frame.contains(mouse)
        if wanted == .expanded, old != .expanded { beginExpanded() }
        if visible { orbWindow.orderFrontRegardless() }
        syncHover(now: now)
    }

    /// What the conversation's look depends on besides its rows; a render that changes none of
    /// it (the input level while a take records) leaves the conversation alone.
    private struct ConversationLook: Equatable {
        var mode: VoiceCardMode
        var busy: Bool
        var link: String?
        var geometry: CGRect
        var errorMessage: String?
    }

    private var conversationLook: ConversationLook?

    /// The conversation's rows, mode and frame, while it is shown; `force` after new rows or a
    /// change of mode.
    private func refreshConversation(force: Bool, animated: Bool = true) {
        guard let mode = shownConversation else { return }
        let expanded = mode == .expanded
        let link = tracker.state.sessionKey == nil ? nil : OrbSceneTracker.sessionLink(provider: tracker.state.sessionProvider)
        let look = ConversationLook(mode: mode, busy: Self.isBusy(tracker.state.phase), link: link,
                                    geometry: geometry.screenFrame, errorMessage: scene.errorMessage)
        guard force || look != conversationLook else { return }
        conversationLook = look
        let width = expanded ? OrbLayout.expandedFrame(geometry: geometry).width : OrbLayout.pinnedWidth
        conversationView.panelWidth = width
        // The peek, where failures show, is away: they show above the field instead.
        conversationView.update(rows: rows, mode: expanded ? .expanded : .pinned, busy: look.busy, sessionLink: link,
                                errorMessage: look.errorMessage)
        let frame = expanded
            ? OrbLayout.expandedFrame(geometry: geometry)
            : OrbLayout.pinnedFrame(contentHeight: conversationView.fittingHeight, geometry: geometry)
        setConversationFrame(frame, animated: animated)
        if expanded { scrimWindow.setFrame(screen?.frame ?? geometry.screenFrame, display: false) }
    }

    private var conversationTarget: CGRect?

    private func setConversationFrame(_ frame: CGRect, animated: Bool) {
        guard frame != conversationTarget || conversationWindow.frame != frame else { return }
        conversationTarget = frame
        guard animated, !reduceMotion, conversationWindow.isVisible, conversationWindow.frame != frame else {
            conversationWindow.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OrbLayout.cardOpenDuration * 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            conversationWindow.animator().setFrame(frame, display: true)
        }
    }

    private static func isBusy(_ phase: VoicePhase) -> Bool {
        phase == .working || phase == .awaitingApproval
    }

    /// The scrim dims the screen behind the panel, the panel takes key status and the field
    /// takes the keyboard. The orb stays on top: voice keeps working.
    private func beginExpanded() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        scrimWindow.setFrame(screen?.frame ?? geometry.screenFrame, display: false)
        scrimWindow.alphaValue = 0
        scrimWindow.orderFrontRegardless()
        conversationWindow.keyable = true
        conversationWindow.orderFrontRegardless()
        if visible { orbWindow.orderFrontRegardless() }
        conversationWindow.makeKey()
        conversationView.focusComposer()
        fade(scrimWindow, to: 1)
    }

    /// Puts the scrim away and gives the keyboard back to the app that had it. The panel stops
    /// being key; it stays on screen only when it goes back to pinned.
    private func endExpanded(keepWindow: Bool) {
        collapsing = true
        defer { collapsing = false }
        conversationWindow.keyable = false
        if conversationWindow.isKeyWindow {
            conversationWindow.makeFirstResponder(nil)
            conversationWindow.orderOut(nil)
            if keepWindow { conversationWindow.orderFrontRegardless() }
        }
        fade(scrimWindow, to: 0) { [weak self] in
            guard let self, self.shownConversation != .expanded else { return }
            self.scrimWindow.orderOut(nil)
        }
        if NSApp.isActive, let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
    }

    /// Tells the tracker whether the pointer keeps the peek open, and the controller whether it
    /// is over the card (which pins it).
    private func syncHover(now: Date) {
        tracker.setHovering(orbHovered || (cardHovered && cardShown), now: now)
        scene = tracker.scene(now: now)
        let overCard = (cardHovered && cardShown) || (conversationHovered && shownConversation != nil)
        guard overCard != reportedCardHover else { return }
        reportedCardHover = overCard
        actions?.perform(.cardHovered(overCard))
    }

    private func layoutOrb() {
        orbView.animator = animator
        let size = OrbLayout.windowSize(stretch: animator.stretch, geometry: geometry)
        if orbWindow.frame.size != size || orbWindow.frame.maxY != geometry.topAnchorY {
            orbWindow.anchorUnderNotch(size: size, geometry: geometry)
        }
    }

    private func fade(_ window: NSWindow, to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = OrbLayout.fadeDuration
            window.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    // MARK: Timers

    private var isSettled: Bool {
        animator.isSettled(for: scene, reduceMotion: reduceMotion) && (cardGrow.isSettled || reduceMotion)
    }

    /// 60 frames a second while something moves quickly; the resting breath and float alone
    /// are slow enough for 24, which keeps an always-visible orb cheap.
    private var frameInterval: TimeInterval {
        let restingOnly = scene.motion == .idle && cardGrow.isSettled
            && animator.stretch == OrbAnimator.target(for: scene)
        return restingOnly ? 1.0 / 24 : 1.0 / 60
    }

    private func startDisplayTimerIfNeeded() {
        if let timer = displayTimer, timer.timeInterval != frameInterval {
            timer.invalidate()
            displayTimer = nil
        }
        guard displayTimer == nil, visible || cardShown, !isSettled else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now
        animator.advance(dt: dt, scene: scene, level: tracker.state.inputLevel, reduceMotion: reduceMotion)
        cardGrow.advance(dt: dt, reduceMotion: reduceMotion)
        layoutOrb()
        layoutCard()
        if !(visible || cardShown) || isSettled {
            displayTimer?.invalidate()
            displayTimer = nil
        } else if displayTimer?.timeInterval != frameInterval {
            displayTimer?.invalidate()
            displayTimer = nil
            startDisplayTimerIfNeeded()
        }
    }

    private func scheduleDeadline(now: Date) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = tracker.nextDeadline(now: now) else { return }
        let timer = Timer(fire: deadline.addingTimeInterval(0.01), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    // MARK: Input

    private func wireInput() {
        orbView.onClick = { [weak self] in self?.actions?.perform(.orbClicked) }
        orbView.onHover = { [weak self] hovering in
            self?.orbHovered = hovering
            self?.hoverChanged()
        }
        orbView.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        cardView.onApprove = { [weak self] id in self?.actions?.perform(.approve(id: id)) }
        cardView.onDeny = { [weak self] id in self?.actions?.perform(.deny(id: id)) }
        cardView.onClose = { [weak self] in self?.actions?.perform(.dismissCard) }
        cardView.onOpenSession = { [weak self] in self?.actions?.perform(.openSession) }
        cardView.onHover = { [weak self] hovering in
            self?.cardHovered = hovering
            self?.hoverChanged()
        }
        cardView.onClick = { [weak self] in self?.actions?.perform(.cardClicked) }
        conversationView.onHover = { [weak self] hovering in
            self?.conversationHovered = hovering
            self?.hoverChanged()
        }
        conversationView.onApprove = { [weak self] id in self?.actions?.perform(.approve(id: id)) }
        conversationView.onDeny = { [weak self] id in self?.actions?.perform(.deny(id: id)) }
        conversationView.onExpand = { [weak self] in self?.actions?.perform(.cardClicked) }
        conversationView.onCollapse = { [weak self] in self?.actions?.perform(.setCardMode(.peek)) }
        conversationView.onClose = { [weak self] in self?.actions?.perform(.dismissCard) }
        conversationView.onOpenSession = { [weak self] in self?.actions?.perform(.openSession) }
        conversationView.onSend = { [weak self] text in self?.actions?.send(typed: text) ?? "The voice host is stopping" }
        scrimView.onClick = { [weak self] in self?.actions?.perform(.setCardMode(.peek)) }
        // Moving to another app (⌘-Tab) collapses the expanded conversation: its scrim would
        // otherwise stay over the screen without the keyboard to close it.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: conversationWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shownConversation == .expanded, !self.collapsing else { return }
                self.actions?.perform(.setCardMode(.peek))
            }
        })
    }

    private func hoverChanged() {
        let now = Date()
        syncHover(now: now)
        apply(now: now)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let muted = tracker.state.muted
        menu.addItem(OrbMenuItem(title: muted ? "Unmute" : "Mute") { [weak self] in
            self?.actions?.perform(.setMuted(!muted))
        })
        let dismiss = OrbMenuItem(title: "Dismiss") { [weak self] in self?.actions?.perform(.dismissCard) }
        dismiss.isEnabled = tracker.state.card != nil
        menu.autoenablesItems = false
        menu.addItem(dismiss)
        menu.addItem(OrbMenuItem(title: "Show Conversation") { [weak self] in
            self?.actions?.perform(.setCardMode(.expanded))
        })
        return menu
    }

    // MARK: Report

    public func orbWindowReport() -> VoiceOrbWindowReport? {
        let screenID = presence.anchor?.screenID.flatMap { Int($0) }
        return VoiceOrbWindowReport(
            number: orbWindow.windowNumber, isVisible: orbWindow.isVisible, isOnActiveSpace: orbWindow.isOnActiveSpace,
            alpha: Double(orbWindow.alphaValue), frame: VoiceRect(orbWindow.frame), level: orbWindow.level.rawValue,
            screen: VoiceOrbWindowReport.Screen(id: screenID, frame: VoiceRect(geometry.screenFrame),
                                                hasNotch: geometry.hasNotch))
    }

    // MARK: Environment

    private func observeEnvironment() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged(reason: "screen parameters changed") }
        })
        settled = HUDEnvironmentMonitor.shared.observeSettled { [weak self] change in self?.environmentSettled(change) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.apply(now: Date())
            }
        })
    }

    /// Once the desktop has settled after a change: after a wake or a screen change the screen is
    /// read again (`NSScreen` can still be stale at the raw notification), then the orb's window
    /// is put back in step with what the presenter intends.
    private func environmentSettled(_ change: HUDEnvironmentMonitor.Change) {
        let reason = "settled after \(change)"
        if OrbPresence.refreshesScreen(after: change) { screensChanged(reason: reason) }
        presence.reconcile(after: reason)
    }

    /// Moves the orb to its screen's current geometry and re-anchors it there.
    private func screensChanged(reason: String) {
        guard let screen = Self.orbScreen() else { return }
        self.screen = screen
        geometry = HUDNotchGeometry(screen: screen)
        orbView.geometry = geometry
        presence.anchor(screenID: HUDScreenSnapshot.id(for: screen), geometry: geometry, reason: reason)
        orbWindow.anchorUnderNotch(size: OrbLayout.windowSize(stretch: animator.stretch, geometry: geometry), geometry: geometry)
        apply(now: Date())
    }

    private static func orbScreen() -> NSScreen? {
        VoiceOrbScreen.current()
    }

    /// `identifier` names the window in HUDKit's presence log.
    private static func makePanel(_ identifier: String, size: CGSize) -> HUDPanelWindow {
        let panel = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: size), keyable: false,
                                   level: HUDPanelWindow.notchAnchorLevel)
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        // The orb and card stay put under the notch.
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        return panel
    }
}

/// A menu item that runs a closure.
private final class OrbMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// The screen the orb lives on: the primary screen (the one with the menu bar, where MacHUD's
/// tool dock sits), under its notch when it has one and hanging from the menu bar otherwise.
/// The full-screen check uses the same screen.
public enum VoiceOrbScreen {
    @MainActor
    public static func current() -> NSScreen? { NSScreen.screens.first }
}

/// Dims the screen behind the expanded conversation; a click on it collapses the conversation.
final class ConversationScrimView: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
