import AppKit
import Combine
import CoreImage
import HUDKit
import SwiftUI

/// The onboarding overlay: a borderless HUD window covering the screen with the pointer, the
/// desktop behind it blurred and lightly tinted but still visible. It is a windowed HUD window
/// at the normal level, so System Settings and macOS's permission prompts come up over it when
/// the Permissions step sends the user there. While the user arranges windows or tries the
/// radial menu it shrinks to a small floating card at the top of that screen and gives the
/// desktop back.
@MainActor
final class OnboardingWindowController: OnboardingPresenting {
    private var window: OnboardingWindow?
    private var screen: NSScreen?
    private var compactWatch: AnyCancellable?

    var isVisible: Bool { window?.isVisible ?? false }

    func present(_ model: OnboardingModel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        self.screen = screen
        let window = self.window ?? OnboardingWindow(frame: screen.frame, model: model)
        self.window = window
        compactWatch = model.$compact.removeDuplicates().sink { [weak self] compact in
            // After the change lands, so the SwiftUI content already shows the new form.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(compact: compact) } }
        }
        fit(compact: model.compact)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        compactWatch = nil
        window?.orderOut(nil)
        window = nil
    }

    /// Full screen with the blur, or the compact card near the top of the screen.
    private func fit(compact: OnboardingModel.Compact?) {
        guard let window, let screen else { return }
        window.showsBlur = compact == nil
        if compact == nil {
            window.level = .normal
            window.setFrame(screen.frame, display: true)
        } else {
            let size = OnboardingRootView.compactSize
            let visible = screen.visibleFrame
            window.level = .floating
            window.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14,
                                   width: size.width, height: size.height), display: true)
        }
    }
}

final class OnboardingWindow: HUDPanelWindow {
    private var blur: NSView?

    /// The behind-window blur of the whole screen; off while the window is the compact card,
    /// which carries its own glass.
    var showsBlur: Bool {
        get { blur?.isHidden == false }
        set { blur?.isHidden = !newValue }
    }

    convenience init(frame: CGRect, model: OnboardingModel) {
        self.init(contentRect: frame, behavior: .windowed)
        showsInDock = false
        isMovableByWindowBackground = false
        hasShadow = false
        title = "MacHUD Setup"
        let content = OnboardingWindow.content(model: model, size: frame.size, live: true)
        blur = content.subviews.first { $0 is NSVisualEffectView }
        contentView = content
    }

    /// The window's content: a blur of the desktop (live only), then the SwiftUI overlay.
    static func content(model: OnboardingModel, size: CGSize, live: Bool, forcedStep: OnboardingStep? = nil,
                        forcedCompact: OnboardingModel.Compact?? = nil) -> NSView {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        if live {
            // `.hudWindow` blurs strongly but stays see-through, unlike `.fullScreenUI`, which
            // reads as an opaque cover.
            let blur = NSVisualEffectView(frame: root.bounds)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.autoresizingMask = [.width, .height]
            root.addSubview(blur)
        }
        let host = NSHostingView(rootView: OnboardingRootView(model: model, forcedStep: forcedStep,
                                                              forcedCompact: forcedCompact, live: live))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        root.appearance = NSAppearance(named: .darkAqua)
        return root
    }
}

/// Renders onboarding steps offscreen for review: the overlay over a stand-in desktop, in a
/// window that is never ordered on screen. The live blur cannot render offscreen, so the
/// stand-in desktop is blurred in the picture itself (`blurred`), or left sharp to show the
/// tint alone.
@MainActor
enum OnboardingSnapshot {
    nonisolated static let canvas = CGSize(width: 1280, height: 800)

    static func render(_ model: OnboardingModel, step: OnboardingStep, compact: OnboardingModel.Compact? = nil,
                       blurred: Bool = true, size: CGSize = canvas) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = SnapshotDesktop(frame: CGRect(origin: .zero, size: size))
        // The compact card leaves the desktop unblurred, as it is live.
        root.blurred = blurred && compact == nil
        let overlay = OnboardingWindow.content(model: model, size: size, live: false, forcedStep: step,
                                               forcedCompact: .some(compact))
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

    /// One picture to write: a step, optionally as the compact card or over the sharp desktop.
    struct Shot {
        var file: String
        var step: OnboardingStep
        var compact: OnboardingModel.Compact?
        var blurred = true
    }

    /// Every step as `onboarding-<n>-<step>.png`, then the two compact cards and the welcome
    /// page over the unblurred desktop (the tint alone).
    static var shots: [Shot] {
        OnboardingStep.allCases.map { Shot(file: "onboarding-\($0.index + 1)-\($0.rawValue).png", step: $0) } + [
            Shot(file: "onboarding-compact-arrange.png", step: .loadout, compact: .arrange),
            Shot(file: "onboarding-compact-practice.png", step: .radial, compact: .practice),
            Shot(file: "onboarding-tint-only.png", step: .welcome, blurred: false),
        ]
    }

    @discardableResult
    static func writeAll(_ model: OnboardingModel, to dir: URL, prefix: String = "") throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try shots.map { shot in
            try write(model, shot: shot, to: dir.appendingPathComponent(prefix + shot.file))
        }
    }

    @discardableResult
    static func write(_ model: OnboardingModel, shot: Shot, to url: URL) throws -> URL {
        guard let rep = render(model, step: shot.step, compact: shot.compact, blurred: shot.blurred),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }
}

/// A stand-in desktop behind the snapshot: wallpaper, a menu bar, a few windows with content
/// and the tool dock, busy enough to show what comes through the overlay.
private final class SnapshotDesktop: NSView {
    var blurred = true

    override func draw(_ dirtyRect: NSRect) {
        guard blurred, let image = Self.picture(size: bounds.size), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Self.drawScene(in: bounds)
            return
        }
        let input = CIImage(cgImage: cg).clampedToExtent()
        let blur = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .cropped(to: CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height)))
        let context = CIContext()
        guard let out = context.createCGImage(blur, from: blur.extent) else { Self.drawScene(in: bounds); return }
        NSImage(cgImage: out, size: bounds.size).draw(in: bounds)
    }

    private static func picture(size: CGSize) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        drawScene(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    private static func drawScene(in r: CGRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.3, blue: 0.5, alpha: 1),
                            NSColor(srgbRed: 0.62, green: 0.4, blue: 0.52, alpha: 1),
                            NSColor(srgbRed: 0.95, green: 0.7, blue: 0.45, alpha: 1)])?.draw(in: r, angle: -35)
        let windows: [(CGRect, NSColor, NSColor)] = [
            (CGRect(x: 60, y: 110, width: 560, height: 520), NSColor(white: 0.96, alpha: 1), NSColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1)),
            (CGRect(x: 660, y: 330, width: 560, height: 360), NSColor(white: 0.14, alpha: 1), NSColor(srgbRed: 0.3, green: 0.85, blue: 0.5, alpha: 1)),
            (CGRect(x: 700, y: 90, width: 470, height: 210), NSColor(srgbRed: 1, green: 0.97, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.9, green: 0.5, blue: 0.2, alpha: 1)),
        ]
        for (frame, fill, ink) in windows {
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
            NSColor(white: 0.5, alpha: 0.3).setFill()
            CGRect(x: frame.minX, y: frame.maxY - 26, width: frame.width, height: 26).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: frame.minX + 10 + CGFloat(i) * 18, y: frame.maxY - 18, width: 11, height: 11)).fill()
            }
            var y = frame.maxY - 50
            var line = 0
            while y > frame.minY + 16 {
                ink.withAlphaComponent(line % 4 == 0 ? 0.9 : 0.45).setFill()
                let width = (frame.width - 40) * CGFloat([0.9, 0.7, 0.8, 0.5, 0.65][line % 5])
                NSBezierPath(roundedRect: CGRect(x: frame.minX + 20, y: y, width: width, height: 8), xRadius: 4, yRadius: 4).fill()
                y -= 22
                line += 1
            }
        }
        // The tool dock at the bottom of the display.
        let dock = CGRect(x: r.midX - 170, y: 12, width: 340, height: 56)
        NSColor(white: 1, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: dock, xRadius: 18, yRadius: 18).fill()
        for i in 0..<6 {
            NSColor(calibratedHue: CGFloat(i) / 6, saturation: 0.6, brightness: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: dock.minX + 14 + CGFloat(i) * 54, y: dock.minY + 8, width: 40, height: 40),
                         xRadius: 9, yRadius: 9).fill()
        }
        NSColor(white: 0.1, alpha: 0.8).setFill()
        CGRect(x: 0, y: r.maxY - 28, width: r.width, height: 28).fill()
    }
}
