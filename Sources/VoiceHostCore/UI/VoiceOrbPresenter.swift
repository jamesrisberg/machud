import AppKit
import HUDKit

/// The notch orb: a small plain orb centered just under the notch (hanging from the menu bar
/// on a screen without one), always visible, that breathes and floats gently while it rests,
/// stretches into SpeakFree's waveform body while dictating, pulses while the agent listens,
/// and grows its reply card out of itself (and folds it back in).
///
/// Renders purely from `VoiceHostState`; user input goes back through `VoiceHostActing`.
/// Two borderless non-activating panels at `HUDPanelWindow.notchAnchorLevel`, one for the orb
/// (resized with the shape each frame) and one for the card, so only the orb and the card
/// take mouse events; the rest of the screen's top edge stays clickable.
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

    private let orbWindow: HUDPanelWindow
    private let orbView: OrbView
    private let cardWindow: HUDPanelWindow
    private let cardView = OrbCardView(frame: .zero)
    /// The card window is on screen (open, growing, or folding back into the orb).
    private var cardShown = false
    private var cardGrow = CardGrow()
    private var visible = false

    private var displayTimer: Timer?
    private var lastTick = Date()
    private var deadlineTimer: Timer?
    private var orbHovered = false
    private var cardHovered = false
    private var observers: [NSObjectProtocol] = []

    public init(actions: VoiceHostActing) {
        self.actions = actions
        let screen = Self.orbScreen()
        self.screen = screen
        geometry = screen.map(HUDNotchGeometry.init(screen:))
            ?? HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        scene = tracker.scene(now: Date())

        let size = OrbLayout.windowSize(stretch: 0, geometry: geometry)
        orbWindow = Self.makePanel(size: size)
        orbWindow.hasShadow = false
        orbView = OrbView(frame: CGRect(origin: .zero, size: size), geometry: geometry)
        orbView.autoresizingMask = [.width, .height]
        orbWindow.contentView = orbView
        orbWindow.setAccessibilityLabel("Voice assistant")

        cardWindow = Self.makePanel(size: CGSize(width: OrbLayout.cardWidth, height: 1))
        cardWindow.contentView = cardView
        cardWindow.setAccessibilityLabel("Voice assistant reply")

        wireInput()
        observeEnvironment()
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

    // MARK: Scene

    private func apply(now: Date) {
        scene = tracker.scene(now: now)
        orbView.scene = scene
        orbView.history = history
        orbView.reduceMotion = reduceMotion
        applyVisibility()
        applyCard()
        layoutOrb()
        startDisplayTimerIfNeeded()
        scheduleDeadline(now: now)
    }

    private func applyVisibility() {
        let show = !scene.hidden
        guard show != visible else { return }
        visible = show
        orbWindow.ignoresMouseEvents = !show
        if show {
            orbWindow.alphaValue = 0
            orbWindow.orderFrontRegardless()
            fade(orbWindow, to: 1)
        } else {
            fade(orbWindow, to: 0) { [weak self] in
                guard let self, !self.visible else { return }
                self.orbWindow.orderOut(nil)
            }
        }
    }

    /// The card grows out of the orb and folds back into it, driven by `cardGrow` from the
    /// display timer. The window frame is never animated: it jumps to cover the orb and the
    /// card while the shape travels, and to the card alone once it is open, and the card view
    /// keeps its content in the card's place throughout. Under Reduce Motion the card fades in
    /// and out where it stands.
    private func applyCard() {
        let wantsCard = visible && (scene.card != nil || scene.errorMessage != nil)
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

    private func layoutOrb() {
        orbView.animator = animator
        let size = OrbLayout.windowSize(stretch: animator.stretch, geometry: geometry)
        if orbWindow.frame.size != size || orbWindow.frame.maxY != geometry.topAnchorY {
            orbWindow.anchorUnderNotch(size: size, geometry: geometry)
        }
    }

    private func fade(_ window: NSWindow, to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
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
    }

    private func hoverChanged() {
        let now = Date()
        tracker.setHovering(orbHovered || (cardHovered && cardShown), now: now)
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
        return menu
    }

    // MARK: Environment

    private func observeEnvironment() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.apply(now: Date())
            }
        })
    }

    private func screensChanged() {
        guard let screen = Self.orbScreen() else { return }
        self.screen = screen
        geometry = HUDNotchGeometry(screen: screen)
        orbView.geometry = geometry
        orbWindow.setFrame(.zero, display: false)
        apply(now: Date())
    }

    private static func orbScreen() -> NSScreen? {
        VoiceOrbScreen.current()
    }

    private static func makePanel(size: CGSize) -> HUDPanelWindow {
        let panel = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: size), keyable: false,
                                   level: HUDPanelWindow.notchAnchorLevel)
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
