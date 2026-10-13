import AppKit
import CoreImage
import XCTest
@testable import MacHUDCore

/// Renders the loadout wheel offscreen for review, as the screen would show it: a generated
/// desktop (shapes and text, never a screenshot) under the wheel's scrim (`RadialScrim`), and the
/// wheel's view drawn over it, settled with the shot's path highlighted (or posed part-way
/// through unfurling and popping out). Under each bubble the dimmed desktop is blurred (a
/// Gaussian of radius 25 pt, the window server's blur under HUDKit's glass) within the bubble's
/// shape, at full strength even while it fades in; with Reduce transparency it is an opaque dark
/// grey there instead (the system's material, a guess). No window is
/// ordered in and nothing acts on the desktop. Pictures go to `MACHUD_WHEEL_SNAPSHOT_DIR`;
/// without it they are rendered and checked, and nothing is written.
@MainActor
final class RadialWheelSnapshotTests: XCTestCase {
    enum Desktop: String, CaseIterable { case bright, dark, colourful }

    private static let short = ["Code", "Reading", "Mail", "Focus", "Notes", "Music", "Chat", "Docs", "Plan"]
    private static let long = ["Morning research and writing", "dev: Browsers", "Messaging", "Quarterly planning review",
                               "Design critique", "Evening reading", "Code", "Customer support rotation", "Music"]
    private static let apps = ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.mail", "com.apple.Music"]

    /// Seen around the canvas.
    private static let margin: CGFloat = 40

    private var directory: URL? {
        ProcessInfo.processInfo.environment["MACHUD_WHEEL_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private static func appIcons(_ count: Int) -> [NSImage] {
        apps.prefix(count).compactMap { RadialMenu.icon(for: .app(bundleID: $0, titleMatch: nil), panels: nil) }
    }

    /// `loadouts` loadouts named from `names`, then Capture, Park and (when `widgets`) Widgets.
    private static func tree(_ names: [String], loadouts: Int, widgets: RadialMenu.WidgetsState? = .init(),
                             allScreens: Bool = false, park: RadialMenu.ParkTargets = .init()) -> [RadialNode] {
        let entries = (0..<loadouts).map { i in
            RadialMenu.LoadoutEntry(name: i < names.count ? names[i] : "\(names[i % names.count]) \(i / names.count + 1)",
                                    icons: appIcons(2 + i % 3))
        }
        return RadialMenu.tree(loadouts: entries, offersAllScreens: allScreens, park: park, widgets: widgets)
    }

    struct Shot {
        var name: String
        var tree: [RadialNode]
        var selection: [String]
        var desktop: Desktop
        /// Reduce transparency on: the glass shows the system's opaque material.
        var reduced = false
        /// A whole screen of this visible size (a 24 pt menu bar above it), the wheel in the middle of it.
        var screen: CGSize?
        /// Posed this long after the wheel opened on `from`, then moved to `selection`, rather than at rest.
        var after: TimeInterval?
        var from: [String] = []
    }

    // MARK: The set

    /// What is rendered without `MACHUD_WHEEL_SNAPSHOT_DIR`.
    private static let checked: Set<String> = ["stage-3-actions-03-bright", "reduce-transparency-06-bright",
                                               "screen-1024x640-03-open-bright", "unfurl-actions-03-bright-0.12s"]

    private func shots() -> [Shot] {
        var out: [Shot] = []
        let three = Self.tree(Self.short, loadouts: 3)

        // The three stages of a path, on a bright and a dark desktop: the top petals as the
        // wheel opens, Apply Loadout reached with three loadouts out, and a loadout's actions out.
        for desktop in [Desktop.bright, .dark, .colourful] {
            out.append(Shot(name: "stage-1-top-03-\(desktop.rawValue)", tree: three, selection: [], desktop: desktop))
            out.append(Shot(name: "stage-2-loadouts-03-\(desktop.rawValue)", tree: three, selection: ["loadouts"], desktop: desktop))
            out.append(Shot(name: "stage-3-actions-03-\(desktop.rawValue)", tree: three, selection: ["loadouts", "Reading", "apply"],
                            desktop: desktop))
        }
        out.append(Shot(name: "stage-3-loadout-03-colourful", tree: three, selection: ["loadouts", "Code"], desktop: .colourful))

        // A loadout's actions open, with 3, 10 and 14 loadouts, and Capture open, on each desktop.
        let ten = Self.tree(Self.short, loadouts: 10), fourteenLong = Self.tree(Self.long, loadouts: 14)
        let capture = Self.tree(Self.short, loadouts: 3, allScreens: true)
        for desktop in Desktop.allCases {
            out.append(Shot(name: "actions-10-\(desktop.rawValue)", tree: ten, selection: ["loadouts", "Focus", "apply"], desktop: desktop))
            out.append(Shot(name: "actions-14-long-\(desktop.rawValue)", tree: fourteenLong, selection: ["loadouts", "dev: Browsers", "apply"],
                            desktop: desktop))
            out.append(Shot(name: "actions-14-long-edge-\(desktop.rawValue)", tree: fourteenLong,
                            selection: ["loadouts", "Design critique", "preview"], desktop: desktop))
            out.append(Shot(name: "capture-\(desktop.rawValue)", tree: capture, selection: ["capture", "screen"], desktop: desktop))
        }

        // Part-way: the wheel opening, the loadouts coming out, a loadout's and Capture's stems
        // unfurling with their leaves popping at the tips.
        for t in [0.06, 0.12, 0.2] {
            out.append(Shot(name: "bloom-open-03-bright-\(t)s", tree: three, selection: [], desktop: .bright, after: t))
            out.append(Shot(name: "unfurl-actions-03-bright-\(t)s", tree: three, selection: ["loadouts", "Reading"], desktop: .bright,
                            after: t, from: ["loadouts"]))
            out.append(Shot(name: "unfurl-capture-dark-\(t)s", tree: capture, selection: ["capture"], desktop: .dark, after: t))
        }
        out.append(Shot(name: "bloom-loadouts-14-colourful-0.1s", tree: Self.tree(Self.short, loadouts: 14), selection: ["loadouts"],
                        desktop: .colourful, after: 0.1))

        // More loadouts: up to five on the first row, the rest on rows further out, all in the
        // top sector; and long names.
        let six = Self.tree(Self.short, loadouts: 6)
        let fourteen = Self.tree(Self.short, loadouts: 14)
        out.append(Shot(name: "loadouts-06-open-bright", tree: six, selection: ["loadouts"], desktop: .bright))
        out.append(Shot(name: "loadouts-10-open-dark", tree: ten, selection: ["loadouts"], desktop: .dark))
        out.append(Shot(name: "loadouts-14-open-colourful", tree: fourteen, selection: ["loadouts"], desktop: .colourful))
        out.append(Shot(name: "loadouts-14-open-bright", tree: fourteen, selection: ["loadouts"], desktop: .bright))
        out.append(Shot(name: "loadouts-10-outer-row-actions-bright", tree: ten, selection: ["loadouts", "Chat", "apply"],
                        desktop: .bright))
        out.append(Shot(name: "loadouts-10-inner-row-actions-dark", tree: ten, selection: ["loadouts", "Focus", "clear"], desktop: .dark))
        for (count, desktop) in [(3, Desktop.bright), (6, .dark), (10, .colourful), (14, .bright)] {
            out.append(Shot(name: "loadouts-\(String(format: "%02d", count))-long-open-\(desktop.rawValue)",
                            tree: Self.tree(Self.long, loadouts: count), selection: ["loadouts"], desktop: desktop))
        }
        let long = Self.tree(Self.long, loadouts: 6)
        out.append(Shot(name: "loadouts-06-long-apply-bright", tree: long, selection: ["loadouts", "dev: Browsers", "apply"],
                        desktop: .bright))

        // Capture (with All screens), Park with a long title, Widgets while revealed.
        out.append(Shot(name: "capture-all-screens-dark", tree: Self.tree(Self.short, loadouts: 3, allScreens: true),
                        selection: ["capture", "all"], desktop: .dark))
        out.append(Shot(name: "capture-draw-bright", tree: three, selection: ["capture", "draw"], desktop: .bright))
        out.append(Shot(name: "park-long-title-colourful",
                        tree: Self.tree(Self.short, loadouts: 3,
                                        park: .init(focused: "Safari · How to design a radial menu that reads clearly over any desktop, with examples")),
                        selection: ["park", "park"], desktop: .colourful))
        out.append(Shot(name: "park-restore-dark", tree: Self.tree(Self.short, loadouts: 3, park: .init(parked: ["Mail · Inbox", "Notes"])),
                        selection: ["park", "restore"], desktop: .dark))
        out.append(Shot(name: "widgets-lower-bright", tree: Self.tree(Self.short, loadouts: 3, widgets: .init(revealed: true)),
                        selection: ["widgets", "reveal"], desktop: .bright))
        out.append(Shot(name: "no-widgets-no-loadouts-dark", tree: Self.tree(Self.short, loadouts: 0, widgets: nil),
                        selection: ["loadouts"], desktop: .dark))

        // Reduce transparency on: the system's opaque material under every bubble.
        out.append(Shot(name: "reduce-transparency-06-bright", tree: Self.tree(Self.short, loadouts: 6),
                        selection: ["loadouts", "Mail"], desktop: .bright, reduced: true))
        out.append(Shot(name: "reduce-transparency-03-actions-colourful", tree: three, selection: ["loadouts", "Reading", "apply"],
                        desktop: .colourful, reduced: true))

        // Whole screens, the wheel in the middle (the pointer moved to its centre as it shows;
        // and on an action): a 13-inch display at Larger Text (1024 by 640, less the menu bar)
        // and a 1440 by 900 one, with three and fourteen long-named loadouts.
        for (label, screen) in [("1024x640", CGSize(width: 1024, height: 616)), ("1440x900", CGSize(width: 1440, height: 876))] {
            let three = Self.tree(Self.long, loadouts: 3), fourteen = Self.tree(Self.long, loadouts: 14)
            out.append(Shot(name: "screen-\(label)-03-open-bright", tree: three, selection: [], desktop: .bright, screen: screen))
            out.append(Shot(name: "screen-\(label)-03-apply-bright", tree: three, selection: ["loadouts", "Messaging", "apply"],
                            desktop: .bright, screen: screen))
            out.append(Shot(name: "screen-\(label)-14-loadouts-colourful", tree: fourteen, selection: ["loadouts"],
                            desktop: .colourful, screen: screen))
        }
        return out
    }

    func testSnapshotsOfTheWheel() throws {
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Without a folder to write to, a few pictures are rendered and checked: one of each way
        // the harness composes (the blur, the system's material, a whole screen with its
        // pointer, a pose part-way through popping out).
        let shots = directory == nil ? shots().filter { Self.checked.contains($0.name) } : shots()
        let pictures = try shots.map { shot in (shot.name, try XCTUnwrap(render(shot), shot.name)) }
        XCTAssertFalse(pictures.isEmpty)
        for (name, rep) in pictures {
            try assertNotBlank(rep, name)
            if let directory {
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("wheel-\(name).png"))
            }
        }
        if let directory { print("Wheel snapshots: \(directory.path)") }
    }

    /// How long the wheel takes, offscreen at 2x, printed for review: from a hotkey press to its
    /// bubbles showing (laying it out, making the bubbles and drawing their words) the first time
    /// it opens and when it opens again, at three and ten loadouts on a large and a small
    /// display; and how long the pointer moving from one loadout to the next takes on the main
    /// thread, one loadout's actions going and the next one's coming, the first time and after.
    func testHowLongTheWheelTakesToOpenAndToFollowThePointer() throws {
        let displays = [("1440x900", RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900)),
                        ("1024x640", RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 616), primaryHeight: 640))]
        for (label, display) in displays {
            for loadouts in [3, 10, 20] {
                let menu = RadialMenu()
                menu.warpPointer = { _ in }
                let window = menu.makeWindow()
                defer { window.close() }
                var times: [Double] = []
                for _ in 0..<3 {
                    let start = Date()
                    menu.prepare(tree: Self.tree(Self.long, loadouts: loadouts), at: CGPoint(x: display.frame.midX, y: display.frame.midY),
                                 on: display, movesPointer: true)
                    menu.wheel.open()
                    times.append(Date().timeIntervalSince(start) * 1000)
                    menu.wheel.close()
                }
                menu.wheel.open()
                let ids = menu.tree[0].children.map(\.id)
                var moves: [Double] = []
                for round in 0..<2 {
                    let start = Date()
                    for id in ids { menu.select(path: ["loadouts", id]) }
                    moves.append(Date().timeIntervalSince(start) * 1000 / Double(ids.count))
                    if round == 0 { menu.select(path: ["park"]) }
                }
                print(String(format: "Wheel open, %d loadouts on %@: first %.0f ms, then %.0f ms and %.0f ms; loadout to loadout %.2f ms, then %.2f ms",
                             loadouts, label, times[0], times[1], times[2], moves[0], moves[1]))
            }
        }
    }

    // MARK: Rendering

    private static func context(size: CGSize) -> CGContext? {
        let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.scaleBy(x: 2, y: 2)
        return context
    }

    /// Each animation on `layer` evaluated `t` after `start` (layer time) into the layer's model
    /// values: the spring's samples as they are, the fades linearly.
    private static func pose(_ layer: CALayer, at t: TimeInterval, from start: CFTimeInterval) {
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) else { continue }
            let begin = animation.beginTime == 0 ? start : animation.beginTime
            let u = max(0, min(1, (start + t - begin) / animation.duration))
            if let keys = animation as? CAKeyframeAnimation, let values = keys.values as? [NSValue] {
                layer.setValue(values[Int((u * Double(values.count - 1)).rounded())], forKeyPath: keys.keyPath!)
            } else if let basic = animation as? CABasicAnimation, basic.keyPath == "strokeEnd",
                      let from = basic.fromValue as? CGFloat, let to = basic.toValue as? CGFloat, let shape = layer as? CAShapeLayer {
                shape.strokeEnd = from + (to - from) * CGFloat(u)
            } else if let basic = animation as? CABasicAnimation, basic.keyPath == "opacity",
                      let from = basic.fromValue as? Float, let to = basic.toValue as? Float {
                layer.opacity = from + (to - from) * Float(u)
            } else if let basic = animation as? CABasicAnimation, let from = basic.fromValue as? NSValue, let to = basic.toValue as? NSValue {
                // A shrink: a scale and a translation, each linear between its ends.
                let (a, b) = (from.caTransform3DValue, to.caTransform3DValue)
                func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(u) }
                var m = CATransform3DIdentity
                (m.m11, m.m22, m.m41, m.m42) = (mix(a.m11, b.m11), mix(a.m22, b.m22), mix(a.m41, b.m41), mix(a.m42, b.m42))
                layer.setValue(NSValue(caTransform3D: m), forKeyPath: basic.keyPath!)
            }
        }
    }

    /// The wheel's view for `shot`, settled or posed, in an offscreen window that is never
    /// ordered in.
    private func wheel(_ shot: Shot, layout: RadialLayout, canvas: RadialMenu.Canvas) -> (RadialWheelView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: canvas.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: canvas.size))
        window.contentView?.addSubview(view)
        view.reducesMotion = { false }
        view.configure(layout: layout, canvas: canvas, tree: shot.tree)
        if let t = shot.after {
            // Opened on `from` and settled there (unless that is where it stays), then moved on.
            view.selection = shot.from
            var start = view.layer.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
            view.open()
            if shot.from != shot.selection {
                for bubble in view.subviews.compactMap({ $0 as? RadialBubble }) { bubble.layer?.removeAllAnimations() }
                start = view.layer.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
            }
            view.selection = shot.selection
            for bubble in view.subviews.compactMap({ $0 as? RadialBubble }) where !bubble.isHidden {
                if let layer = bubble.layer { Self.pose(layer, at: t, from: start) }
            }
            // The stems, in the view under the bubbles.
            for layer in view.subviews.first?.layer?.sublayers ?? [] { Self.pose(layer, at: t, from: start) }
        } else {
            view.settle(selection: shot.selection)
        }
        // A window never ordered in builds its views' layers when it is told to display.
        window.display()
        return (view, window)
    }

    /// Every layer of the tree has drawn its contents.
    private static func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        for sub in layer.sublayers ?? [] { display(sub) }
    }

    private func render(_ shot: Shot) -> NSBitmapImageRep? {
        let layout: RadialLayout
        let centre: CGPoint
        if let screen = shot.screen {
            let placed = RadialMenu.place(tree: shot.tree, visibleFrame: CGRect(origin: .zero, size: screen))
            (layout, centre) = (placed.layout, placed.center)
        } else {
            (layout, centre) = (RadialLayout(tree: shot.tree), .zero)
        }
        let canvas = RadialWheelView.canvas(for: layout)
        let picture = shot.screen.map { CGSize(width: $0.width, height: $0.height + 24) }
            ?? CGSize(width: canvas.size.width + 2 * Self.margin, height: canvas.size.height + 2 * Self.margin)
        let wheelCentre = shot.screen != nil ? centre : CGPoint(x: Self.margin + canvas.center.x, y: Self.margin + canvas.center.y)
        guard let context = Self.context(size: picture) else { return nil }
        let bounds = CGRect(origin: .zero, size: picture)

        context.draw(Self.desktop(shot.desktop, size: picture), in: bounds)
        if shot.screen != nil { Self.menuBar(in: context, width: picture.width, top: picture.height) }
        // The scrim over the whole screen; what the bubbles blur is the desktop under it.
        context.setFillColor(NSColor.black.withAlphaComponent(RadialScrim.darkness).cgColor)
        context.fill(bounds)
        guard let desktop = context.makeImage() else { return nil }

        let (view, window) = wheel(shot, layout: layout, canvas: canvas)
        defer { window.close() }
        let origin = CGPoint(x: wheelCentre.x - canvas.center.x, y: wheelCentre.y - canvas.center.y)
        // The window server's blur, under every bubble that draws, in its shape as it is now.
        let blurred = shot.reduced ? nil : Self.blur(desktop)
        for bubble in view.subviews.compactMap({ $0 as? RadialBubble }) where !bubble.isHidden && (bubble.layer?.opacity ?? 0) > 0 {
            guard let layer = bubble.layer else { continue }
            let frame = bubble.frame.offsetBy(dx: origin.x, dy: origin.y)
            let radius = bubble.glass.style.cornerRadius
            var shape = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
            var move = CGAffineTransform(translationX: frame.minX, y: frame.minY)
            let t = layer.sublayerTransform
            var scale = CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22, tx: t.m41, ty: t.m42)
            let anchor = CGPoint(x: layer.anchorPoint.x * frame.width, y: layer.anchorPoint.y * frame.height)
            scale = CGAffineTransform(translationX: -anchor.x, y: -anchor.y).concatenating(scale).concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
            shape = shape.copy(using: &scale) ?? shape
            shape = shape.copy(using: &move) ?? shape
            context.saveGState()
            context.addPath(shape)
            context.clip()
            if let blurred {
                context.draw(blurred, in: bounds)
            } else {
                context.setFillColor(NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor)
                context.fill(bounds)
            }
            context.restoreGState()
        }
        // The bubbles.
        guard let layer = view.layer else { return nil }
        Self.display(layer)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { layer.render(in: context) }
        context.restoreGState()
        // On a whole screen, the pointer: at the wheel's centre as it shows (moved there as it
        // opens), or on the word it lights.
        if shot.screen != nil {
            var pointer = centre
            if let word = layout.word(shot.selection) {
                pointer = CGPoint(x: centre.x + word.frame.midX, y: centre.y + word.frame.midY)
            }
            Self.arrow(at: pointer, in: context)
        }
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = picture
        return rep
    }

    /// An arrow pointer, its tip at `pointer` (the system's cursor image draws nothing offscreen).
    private static func arrow(at pointer: CGPoint, in context: CGContext) {
        let tip = [(0.0, 0.0), (0, -17), (4, -13), (7, -20), (10, -19), (7, -12.5), (12, -12.5)]
        let arrow = NSBezierPath()
        for (k, (x, y)) in tip.enumerated() {
            let p = CGPoint(x: pointer.x + x, y: pointer.y + y)
            if k == 0 { arrow.move(to: p) } else { arrow.line(to: p) }
        }
        arrow.close()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.black.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.2
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A Gaussian of radius 25 pt (50 px at 2x) over the desktop, its edges clamped.
    private static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(50, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent)
    }

    /// Some pixel on the middle row differs from the corner's.
    private func assertNotBlank(_ rep: NSBitmapImageRep, _ name: String) throws {
        let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1))
        let row = stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 64)).compactMap { rep.colorAt(x: $0, y: rep.pixelsHigh / 2) }
        XCTAssertTrue(row.contains { $0 != corner }, "\(name) is blank")
    }

    // MARK: Fake desktops

    /// Repeatable pseudo-random numbers, so every run draws the same desktop.
    private struct Dice {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
        mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
    }

    private static let prose = "The quick brown fox jumps over the lazy dog while the team reviews the quarterly plan, "
        + "drafts the release notes, answers support mail and files the design critique before lunch. "

    private static func desktop(_ kind: Desktop, size: CGSize) -> CGImage {
        let context = Self.context(size: size)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        var dice = Dice(state: UInt64(size.width * 7 + size.height * 13) + UInt64(Desktop.allCases.firstIndex(of: kind)!) * 977)
        let bounds = CGRect(origin: .zero, size: size)

        let wallpaper: [NSColor]
        let window: NSColor, bar: NSColor, ink: NSColor
        switch kind {
        case .bright:
            wallpaper = [NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.84, green: 0.89, blue: 0.95, alpha: 1)]
            (window, bar, ink) = (.white, NSColor(white: 0.93, alpha: 1), NSColor(white: 0.12, alpha: 1))
        case .dark:
            wallpaper = [NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1), NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1)]
            (window, bar, ink) = (NSColor(white: 0.15, alpha: 1), NSColor(white: 0.21, alpha: 1), NSColor(white: 0.82, alpha: 1))
        case .colourful:
            wallpaper = [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.45, green: 0.15, blue: 0.75, alpha: 1)]
            (window, bar, ink) = (NSColor(white: 0.98, alpha: 1), NSColor(white: 0.9, alpha: 1), NSColor(white: 0.1, alpha: 1))
        }
        NSGradient(colors: wallpaper)?.draw(in: bounds, angle: 60)
        if kind == .colourful {
            for _ in 0..<14 {
                let r = dice.range(60, 220)
                NSColor(hue: dice.next(), saturation: 0.8, brightness: 0.95, alpha: 0.85).setFill()
                NSBezierPath(ovalIn: CGRect(x: dice.range(-r, size.width), y: dice.range(-r, size.height), width: r * 2, height: r * 2)).fill()
            }
        }

        // Windows with title bars, text and pictures.
        let count = kind == .colourful ? 7 : 5
        for k in 0..<count {
            let w = dice.range(260, 520), h = dice.range(200, 420)
            let frame = CGRect(x: dice.range(-80, size.width - w + 80), y: dice.range(-60, size.height - h + 60), width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            window.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
            NSGraphicsContext.restoreGraphicsState()
            let title = CGRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
            bar.setFill()
            NSBezierPath(roundedRect: title, xRadius: 10, yRadius: 10).fill()
            for (j, colour) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                colour.setFill()
                NSBezierPath(ovalIn: CGRect(x: title.minX + 12 + CGFloat(j) * 20, y: title.midY - 6, width: 12, height: 12)).fill()
            }
            var y = title.minY - 22
            let font = NSFont.systemFont(ofSize: k % 2 == 0 ? 12 : 13, weight: k == 0 ? .semibold : .regular)
            var offset = Int(dice.range(0, 60))
            while y > frame.minY + 14 {
                if dice.next() < 0.18 {
                    let picture = CGRect(x: frame.minX + 16, y: y - 50, width: min(frame.width - 32, dice.range(90, 240)), height: 56)
                    NSColor(hue: dice.next(), saturation: kind == .dark ? 0.5 : 0.7, brightness: kind == .dark ? 0.6 : 0.9, alpha: 1).setFill()
                    NSBezierPath(roundedRect: picture, xRadius: 6, yRadius: 6).fill()
                    y -= 70
                    continue
                }
                let start = prose.index(prose.startIndex, offsetBy: offset % (prose.count - 80))
                let line = String(prose[start...].prefix(Int((frame.width - 32) / 6.4)))
                NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: ink])
                    .draw(at: CGPoint(x: frame.minX + 16, y: y))
                offset += 37
                y -= 19
            }
        }
        // A row of app icons.
        for k in 0..<10 {
            NSColor(hue: CGFloat(k) / 10, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 24 + CGFloat(k) * 58, y: 12, width: 46, height: 46), xRadius: 11, yRadius: 11).fill()
        }
        return context.makeImage()!
    }

    private static func menuBar(in context: CGContext, width: CGFloat, top: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(white: 0.97, alpha: 0.85).setFill()
        CGRect(x: 0, y: top - 24, width: width, height: 24).fill()
        NSAttributedString(string: "  Finder   File   Edit   View   Go   Window   Help",
                           attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 8, y: top - 19))
        NSGraphicsContext.restoreGraphicsState()
    }
}
