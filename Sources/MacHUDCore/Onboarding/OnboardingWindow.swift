import AppKit
import HUDKit
import SwiftUI

/// The onboarding overlay: a borderless HUD window covering the screen with the pointer,
/// its desktop blurred and dimmed behind the card. It is a windowed HUD window at the normal
/// level, so System Settings and macOS's permission prompts come up over it when the
/// Permissions step sends the user there.
@MainActor
final class OnboardingWindowController: OnboardingPresenting {
    private var window: OnboardingWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func present(_ model: OnboardingModel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let window = self.window ?? OnboardingWindow(frame: frame, model: model)
        window.setFrame(frame, display: true)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

final class OnboardingWindow: HUDPanelWindow {
    convenience init(frame: CGRect, model: OnboardingModel) {
        self.init(contentRect: frame, behavior: .windowed)
        showsInDock = false
        isMovableByWindowBackground = false
        hasShadow = false
        title = "MacHUD Setup"
        contentView = OnboardingWindow.content(model: model, size: frame.size, live: true)
    }

    /// The window's content: a blur of the desktop (live only), then the SwiftUI overlay.
    static func content(model: OnboardingModel, size: CGSize, live: Bool, forcedStep: OnboardingStep? = nil) -> NSView {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        if live {
            let blur = NSVisualEffectView(frame: root.bounds)
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.autoresizingMask = [.width, .height]
            root.addSubview(blur)
        }
        let host = NSHostingView(rootView: OnboardingRootView(model: model, forcedStep: forcedStep))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        root.appearance = NSAppearance(named: .darkAqua)
        return root
    }
}

/// Renders onboarding steps offscreen for review: the overlay over a stand-in desktop, in a
/// window that is never ordered on screen.
@MainActor
enum OnboardingSnapshot {
    nonisolated static let canvas = CGSize(width: 1280, height: 800)

    static func render(_ model: OnboardingModel, step: OnboardingStep, size: CGSize = canvas) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = SnapshotDesktop(frame: CGRect(origin: .zero, size: size))
        let overlay = OnboardingWindow.content(model: model, size: size, live: false, forcedStep: step)
        root.addSubview(overlay)
        window.contentView = root
        // Let SwiftUI lay out and the async pieces (hosting updates) settle.
        for _ in 0..<3 {
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep
    }

    /// Every step as `onboarding-<n>-<step>.png` in `dir`.
    @discardableResult
    static func writeAll(_ model: OnboardingModel, to dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try OnboardingStep.allCases.map { step in
            guard let rep = render(model, step: step), let data = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = dir.appendingPathComponent("onboarding-\(step.index + 1)-\(step.rawValue).png")
            try data.write(to: url)
            return url
        }
    }
}

/// A stand-in desktop behind the snapshot: wallpaper, a menu bar and two windows.
private final class SnapshotDesktop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.26, blue: 0.42, alpha: 1),
                            NSColor(srgbRed: 0.52, green: 0.38, blue: 0.55, alpha: 1)])?.draw(in: r, angle: -60)
        for (i, frame) in [CGRect(x: 80, y: 120, width: 560, height: 480),
                           CGRect(x: 700, y: 90, width: 500, height: 420)].enumerated() {
            NSColor(white: i == 0 ? 0.94 : 0.2, alpha: 1).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
        }
        NSColor(white: 0.1, alpha: 0.8).setFill()
        CGRect(x: 0, y: r.maxY - 28, width: r.width, height: 28).fill()
    }
}
