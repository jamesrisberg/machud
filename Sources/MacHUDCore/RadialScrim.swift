import AppKit
import HUDKit

/// A dark veil over the whole screen the wheel opens on, just under the wheel's window, so its
/// bubbles stand out from a busy desktop while the desktop stays recognisable. It is a window of
/// its own: the window server blurs the wheel's window wherever it draws (`HUDWindowBlur`), so a
/// veil there would blur the whole screen. It never takes the mouse, focus or a key, shows on
/// every Space with the wheel, fades in as the wheel opens and out fast as it goes.
@MainActor
final class RadialScrim {
    /// Black at this opacity over the screen. The bubbles' blur is of what lies under the wheel's
    /// window, the veil included, so it darkens their glass on a bright desktop too.
    static let darkness: CGFloat = 0.4
    static let fadeIn: TimeInterval = 0.2
    static let fadeOut: TimeInterval = 0.12

    private(set) var window: NSWindow?
    /// Between `show` and `hide`: it is there or fading in (a hidden veil may still be fading out).
    private(set) var isShowing = false

    /// The veil's window, made once.
    func makeWindow() -> NSWindow {
        if let window { return window }
        let w = RadialScrimPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.identifier = NSUserInterfaceItemIdentifier("machud.wheel.scrim")
        let veil = NSView(frame: .zero)
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.darkness).cgColor
        w.contentView = veil
        w.alphaValue = 0
        window = w
        return w
    }

    /// Over `frame` (a screen, in screen coordinates), just under `wheel`, fading in.
    func show(on frame: CGRect, below wheel: NSWindow) {
        let w = makeWindow()
        isShowing = true
        if !w.isVisible { w.alphaValue = 0 }
        if w.frame != frame { w.setFrame(frame, display: false) }
        w.order(.below, relativeTo: wheel.windowNumber)
        HUDAnimation.fadeIn(w, duration: Self.fadeIn)
    }

    /// Fades out fast and goes; a `show` before it has gone brings it back.
    func hide() {
        guard isShowing, let w = window else { return }
        isShowing = false
        HUDAnimation.fadeOut(w, duration: Self.fadeOut)
    }
}

/// The veil's window: never key or main.
private final class RadialScrimPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
