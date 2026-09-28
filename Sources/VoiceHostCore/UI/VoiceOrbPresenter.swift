import AppKit
import HUDKit

/// The notch orb: a small plain orb centered just under the notch (hanging from the menu bar
/// on a screen without one), always visible, that stretches into SpeakFree's waveform body
/// while dictating, pulses while the agent listens, and grows a reply card downward.
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
    private var cardShown = false
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

    private func applyCard() {
        let wantsCard = visible && (scene.card != nil || scene.errorMessage != nil)
        if wantsCard, cardView.card != scene.card || cardView.errorMessage != scene.errorMessage {
            cardView.update(card: scene.card, errorMessage: scene.errorMessage)
        }
        // A message alone is informational; clicks go through to the window underneath.
        cardWindow.ignoresMouseEvents = scene.card == nil
        let target = OrbLayout.cardFrame(size: cardView.fittingCardSize, geometry: geometry)
        if wantsCard && !cardShown {
            cardShown = true
            cardWindow.setFrame(reduceMotion ? target : OrbLayout.collapsed(target), display: false)
            cardWindow.alphaValue = 0
            cardWindow.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cardWindow.animator().setFrame(target, display: true)
                cardWindow.animator().alphaValue = 1
            }
        } else if wantsCard {
            if cardWindow.frame != target { cardWindow.setFrame(target, display: true) }
        } else if cardShown {
            cardShown = false
            cardHovered = false
            let collapsed = OrbLayout.collapsed(cardWindow.frame)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                if !reduceMotion { cardWindow.animator().setFrame(collapsed, display: true) }
                cardWindow.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.cardShown else { return }
                    self.cardWindow.orderOut(nil)
                }
            })
        }
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

    private func startDisplayTimerIfNeeded() {
        guard displayTimer == nil, visible, !animator.isSettled(for: scene, reduceMotion: reduceMotion) else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
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
        layoutOrb()
        if !visible || animator.isSettled(for: scene, reduceMotion: reduceMotion) {
            displayTimer?.invalidate()
            displayTimer = nil
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
        NSScreen.screens.first { HUDNotchGeometry(screen: $0).hasNotch } ?? NSScreen.screens.first
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
