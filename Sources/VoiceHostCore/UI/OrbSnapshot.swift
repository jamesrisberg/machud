import AppKit
import HUDKit

/// Renders the orb and card for a state offscreen, onto a stand-in for the top of a notched
/// screen (menu bar, camera housing, a window below), for visual review. No window is shown.
@MainActor
enum OrbSnapshot {
    static let canvas = CGSize(width: 560, height: 470)

    /// A notched screen whose top edge is the canvas's top edge.
    static var geometry: HUDNotchGeometry {
        HUDNotchGeometry(screenFrame: CGRect(origin: .zero, size: canvas),
                         visibleFrame: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height - 32),
                         safeAreaInsetTop: 32, notchWidth: 185)
    }

    /// Renders `state` with the morph at `stretch` (nil: settled for the state), the input
    /// level history `levels`, the running motion `phaseTime` seconds in (the resting float
    /// already eased in), the card grown out of the orb to `cardProgress` (nil: open) and the
    /// armed look at `armed` (nil: settled for the state), under Reduce Motion or not, at 2x.
    static func render(_ state: VoiceHostState, stretch: CGFloat? = nil, levels: [Double] = [],
                       hovering: Bool = false, phaseTime: Double = 0.35,
                       cardProgress: CGFloat? = nil, armed: CGFloat? = nil,
                       reduceMotion: Bool = false) -> NSBitmapImageRep? {
        var tracker = OrbSceneTracker()
        let now = Date()
        tracker.ingest(state, now: now)
        tracker.setHovering(hovering, now: now)
        let scene = tracker.scene(now: now)
        var animator = OrbAnimator(stretch: stretch ?? OrbAnimator.target(for: scene),
                                   float: OrbAnimator.floatTarget(for: scene, reduceMotion: reduceMotion))
        // Settle the level and advance the free-running phase to a representative frame.
        for _ in 0..<Int(phaseTime * 60) {
            animator.advance(dt: 1.0 / 60, scene: scene, level: state.inputLevel, reduceMotion: reduceMotion)
        }
        if stretch != nil || armed != nil { animator = OrbAnimator(stretch: stretch, armed: armed, copying: animator) }
        var history = LevelHistory()
        levels.forEach { history.append($0) }

        let geometry = Self.geometry
        let root = SnapshotBackdrop(frame: CGRect(origin: .zero, size: canvas))
        root.appearance = NSAppearance(named: .darkAqua)

        if !scene.hidden {
            let orbSize = OrbLayout.windowSize(stretch: animator.stretch, geometry: geometry)
            let orbFrame = geometry.anchorFrame(for: orbSize)
            let orb = OrbView(frame: orbFrame, geometry: geometry)
            orb.scene = scene
            orb.reduceMotion = reduceMotion
            orb.animator = animator
            orb.history = history
            root.addSubview(orb)

            if scene.card != nil || scene.errorMessage != nil {
                let card = OrbCardView(frame: .zero)
                card.update(card: scene.card, errorMessage: scene.errorMessage, sessionLink: scene.sessionLink)
                let cardFrame = OrbLayout.cardFrame(size: card.fittingCardSize, geometry: geometry)
                card.frame = card.layoutGrow(progress: cardProgress ?? 1, card: cardFrame,
                                             orb: OrbLayout.orbFrame(geometry: geometry, bob: animator.bobOffset))
                // The card window sits under the orb's.
                root.addSubview(card, positioned: .below, relativeTo: orb)
                card.layoutSubtreeIfNeeded()
            }
        }

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale),
                                         pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = canvas
        root.layoutSubtreeIfNeeded()
        var result: NSBitmapImageRep?
        root.appearance?.performAsCurrentDrawingAppearance {
            root.cacheDisplay(in: root.bounds, to: rep)
            result = rep
        }
        return result
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}

/// The stand-in screen top: a desktop gradient, a window's title bar under the menu bar,
/// the menu bar, and the camera housing.
private final class SnapshotBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.42, blue: 0.55, alpha: 1),
                            NSColor(srgbRed: 0.62, green: 0.55, blue: 0.62, alpha: 1)])?.draw(in: r, angle: -90)
        // A window under the menu bar, so the orb is seen against real chrome.
        let window = CGRect(x: 40, y: 40, width: r.width - 80, height: r.height - 32 - 50)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.84, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: window.minX, y: window.maxY - 28, width: window.width, height: 28)).fill()
        for i in 0..<9 {
            NSColor(white: 0.78, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: window.minX + 24, y: window.maxY - 70 - CGFloat(i) * 26,
                                             width: window.width * (i % 3 == 2 ? 0.5 : 0.8), height: 10),
                         xRadius: 3, yRadius: 3).fill()
        }
        // Menu bar and camera housing.
        NSColor(white: 0.12, alpha: 0.85).setFill()
        CGRect(x: 0, y: r.maxY - 32, width: r.width, height: 32).fill()
        NSColor.black.setFill()
        let housing = CGRect(x: r.midX - 92.5, y: r.maxY - 32, width: 185, height: 32)
        NSBezierPath(roundedRect: housing, xRadius: 9, yRadius: 9).fill()
        CGRect(x: housing.minX, y: housing.midY, width: housing.width, height: housing.height / 2).fill()
    }
}
