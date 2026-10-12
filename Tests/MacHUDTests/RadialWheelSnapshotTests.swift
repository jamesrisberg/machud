import AppKit
import CoreImage
import XCTest
@testable import MacHUDCore

/// Renders the loadout wheel offscreen for review, as the screen would show it: a generated
/// desktop (shapes and text, never a screenshot), sharp outside the field and, inside it,
/// blurred (a Gaussian of radius 25 pt, the soft backdrop's) through the field's blur profile
/// for what shows, under the wheel's tint through its tint profile, with the wheel's view drawn
/// on top, settled with the shot's path highlighted. No window is ordered in and nothing acts on
/// the desktop. Pictures go to `MACHUD_WHEEL_SNAPSHOT_DIR`; without it they are rendered and
/// checked, and nothing is written.
@MainActor
final class RadialWheelSnapshotTests: XCTestCase {
    enum Desktop: String, CaseIterable { case bright, dark, colourful }

    private static let short = ["Code", "Reading", "Mail", "Focus", "Notes", "Music", "Chat", "Docs", "Plan"]
    private static let long = ["Morning research and writing", "dev: Browsers", "Messaging", "Quarterly planning review",
                               "Design critique", "Evening reading", "Code", "Customer support rotation", "Music"]
    private static let apps = ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.mail", "com.apple.Music"]

    /// Seen around the canvas, so the picture shows where the field ends.
    private static let margin: CGFloat = 40

    private var directory: URL? {
        ProcessInfo.processInfo.environment["MACHUD_WHEEL_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private static func symbol(_ name: String) -> [NSImage] {
        [NSImage(systemSymbolName: name, accessibilityDescription: nil)].compactMap { $0 }
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
        /// Reduce transparency on: the soft backdrop shows the system's opaque material.
        var reduced = false
        /// A whole screen of this visible size (a 24 pt menu bar above it), the wheel opened at `pointer`.
        var screen: CGSize?
        var pointer: CGPoint = .zero
    }

    // MARK: The set

    /// What is rendered without `MACHUD_WHEEL_SNAPSHOT_DIR`.
    private static let checked: Set<String> = ["stage-3-actions-03-bright", "system-material-reduce-transparency-06-bright",
                                               "screen-1024x640-10-corner-open-bright"]

    private func shots() -> [Shot] {
        var out: [Shot] = []
        let three = Self.tree(Self.short, loadouts: 3)

        // The three stages of a path, on a bright and a dark desktop: the top petals as the
        // wheel opens, Apply Loadout reached with three loadouts out, and a loadout's actions out.
        for desktop in [Desktop.bright, .dark] {
            out.append(Shot(name: "stage-1-top-03-\(desktop.rawValue)", tree: three, selection: [], desktop: desktop))
            out.append(Shot(name: "stage-2-loadouts-03-\(desktop.rawValue)", tree: three, selection: ["loadouts"], desktop: desktop))
            out.append(Shot(name: "stage-3-actions-03-\(desktop.rawValue)", tree: three, selection: ["loadouts", "Reading", "apply"],
                            desktop: desktop))
        }
        out.append(Shot(name: "stage-3-loadout-03-colourful", tree: three, selection: ["loadouts", "Code"], desktop: .colourful))

        // Many loadouts, and long names.
        let ten = Self.tree(Self.short, loadouts: 10)
        out.append(Shot(name: "loadouts-10-bright", tree: ten, selection: ["loadouts"], desktop: .bright))
        out.append(Shot(name: "loadouts-10-side-clear-dark", tree: ten, selection: ["loadouts", "Music", "clear"], desktop: .dark))
        out.append(Shot(name: "loadouts-10-bottom-preview-colourful", tree: ten, selection: ["loadouts", "Plan", "preview"],
                        desktop: .colourful))
        let long = Self.tree(Self.long, loadouts: 6)
        out.append(Shot(name: "loadouts-06-long-dark", tree: long, selection: ["loadouts"], desktop: .dark))
        out.append(Shot(name: "loadouts-06-long-apply-bright", tree: long, selection: ["loadouts", "dev: Browsers", "apply"],
                        desktop: .bright))
        out.append(Shot(name: "loadouts-14-colourful", tree: Self.tree(Self.short, loadouts: 14), selection: ["loadouts"],
                        desktop: .colourful))

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

        // The system's material (Reduce transparency on): opaque and dark, through a plain soft disc.
        out.append(Shot(name: "system-material-reduce-transparency-06-bright", tree: Self.tree(Self.short, loadouts: 6),
                        selection: ["loadouts", "Mail"], desktop: .bright, reduced: true))

        // A 13-inch display at Larger Text (1024 by 640, less the menu bar), ten loadouts, the
        // wheel opened near the bottom right corner (as it shows, the pointer moved to its
        // centre; and with an action lit) and in the middle.
        let screen = CGSize(width: 1024, height: 616)
        out.append(Shot(name: "screen-1024x640-10-corner-open-bright", tree: ten, selection: [], desktop: .bright, screen: screen,
                        pointer: CGPoint(x: 960, y: 40)))
        out.append(Shot(name: "screen-1024x640-10-corner-hover-bright", tree: ten, selection: ["loadouts", "Mail", "apply"],
                        desktop: .bright, screen: screen, pointer: CGPoint(x: 960, y: 40)))
        out.append(Shot(name: "screen-1024x640-10-middle-colourful", tree: ten, selection: ["loadouts"], desktop: .colourful,
                        screen: screen, pointer: CGPoint(x: 512, y: 308)))
        return out
    }

    func testSnapshotsOfTheWheel() throws {
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Without a folder to write to, a few pictures are rendered and checked: one of each way
        // the harness composes (the blur, the system's material, a whole screen with its pointer).
        let shots = directory == nil ? shots().filter { Self.checked.contains($0.name) } : shots()
        var pictures = try shots.map { shot in (shot.name, try XCTUnwrap(render(shot), shot.name)) }
        if directory != nil {
            // The two profiles alone, with a loadout's actions out, white where they are full.
            let layout = RadialLayout(tree: Self.tree(Self.short, loadouts: 3))
            let whole = RadialField(layout: layout, reduced: false)
            let field = RadialField(shape: .init(layout: layout, open: ["loadouts", "Reading"], reduced: false), over: whole.support)
            pictures.append(("profile-blur-03-actions", try XCTUnwrap(Self.profile(field.blurImage, size: field.support.size))))
            pictures.append(("profile-tint-03-actions", try XCTUnwrap(Self.profile(field.tintImage, size: field.support.size))))
        }
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

    /// How long the wheel takes, offscreen at 2x, printed for review: from a hotkey press to
    /// its first frame (laying it out, its field, its words) the first time it opens and when it
    /// opens again, at three and ten loadouts on a large and a small display; how long a
    /// loadout's actions take to unfold the first time (their field); and one frame with a
    /// loadout's actions out and one lit.
    func testHowLongTheWheelTakesToOpenAndToDraw() throws {
        let displays = [("1440x900", RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900)),
                        ("1024x640", RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 616), primaryHeight: 640))]
        for (label, display) in displays {
            for loadouts in [3, 10] {
                let menu = RadialMenu()
                menu.warpPointer = { _ in }
                let context = try XCTUnwrap(Self.context(size: CGSize(width: 1400, height: 1400)))
                var times: [Double] = []
                for _ in 0..<3 {
                    let start = Date()
                    menu.prepare(tree: Self.tree(Self.long, loadouts: loadouts), at: CGPoint(x: display.frame.midX, y: display.frame.midY),
                                 on: display, movesPointer: true)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { menu.wheel.draw(menu.wheel.bounds) }
                    NSGraphicsContext.restoreGraphicsState()
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                let unfold = Date()
                _ = menu.field(open: ["loadouts", menu.tree[0].children[0].id])
                let unfolding = Date().timeIntervalSince(unfold) * 1000
                print(String(format: "Wheel open to first frame, %d loadouts on %@: first %.0f ms, then %.0f ms and %.0f ms; a loadout's actions' field %.1f ms",
                             loadouts, label, times[0], times[1], times[2], unfolding))
            }
        }

        let tree = Self.tree(Self.long, loadouts: 10)
        let layout = RadialLayout(tree: tree)
        let field = RadialField(layout: layout, reduced: false)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: field.canvas.size))
        view.configure(layout: layout, canvas: field.canvas, tree: tree)
        view.settle(selection: ["loadouts", tree[0].children[3].id, "apply"])
        let context = try XCTUnwrap(Self.context(size: field.canvas.size))
        let frames = 30
        var elapsed: TimeInterval = 0
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            view.draw(view.bounds)
            let start = Date()
            for _ in 0..<frames {
                context.clear(CGRect(origin: .zero, size: field.canvas.size))
                view.draw(view.bounds)
            }
            elapsed = Date().timeIntervalSince(start)
        }
        NSGraphicsContext.restoreGraphicsState()
        print(String(format: "Wheel frame at ten loadouts, an action lit: %.2f ms", elapsed / Double(frames) * 1000))
    }

    // MARK: Rendering

    private static func context(size: CGSize) -> CGContext? {
        let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.scaleBy(x: 2, y: 2)
        return context
    }

    private func render(_ shot: Shot) -> NSBitmapImageRep? {
        let layout: RadialLayout
        let centre: CGPoint
        let size: CGSize
        if let screen = shot.screen {
            // A whole screen with its menu bar, the wheel where it would open.
            let placed = RadialMenu.place(tree: shot.tree, at: shot.pointer, visibleFrame: CGRect(origin: .zero, size: screen))
            layout = placed.layout
            centre = placed.center
            size = CGSize(width: screen.width, height: screen.height + 24)
        } else {
            layout = RadialLayout(tree: shot.tree)
            centre = .zero
            size = .zero
        }
        // The field of what shows with this selection, over the whole wheel's rectangle.
        let whole = RadialField(layout: layout, reduced: shot.reduced)
        let field = RadialField(shape: .init(layout: layout, open: shot.selection, reduced: shot.reduced), over: whole.support)
        let profiles = (rect: field.support, blur: field.blurImage, tint: field.tintImage)
        // Otherwise the picture is the profiles' rectangle with a margin.
        let (picture, wheelCentre) = shot.screen != nil ? (size, centre)
            : (CGSize(width: profiles.rect.width + 2 * Self.margin, height: profiles.rect.height + 2 * Self.margin),
               CGPoint(x: Self.margin - profiles.rect.minX, y: Self.margin - profiles.rect.minY))
        guard let context = Self.context(size: picture) else { return nil }
        let bounds = CGRect(origin: .zero, size: picture)
        let rect = profiles.rect.offsetBy(dx: wheelCentre.x, dy: wheelCentre.y)

        let desktop = Self.desktop(shot.desktop, size: picture)
        context.draw(desktop, in: bounds)
        if shot.screen != nil { Self.menuBar(in: context, width: picture.width, top: picture.height) }
        // The backdrop through the blur profile: the blurred desktop, or with Reduce
        // transparency the system's material (opaque, dark; its grey here is a guess).
        guard let blurMask = Self.grey(profiles.blur), let tintMask = Self.grey(profiles.tint) else { return nil }
        context.saveGState()
        context.clip(to: rect, mask: blurMask)
        if shot.reduced {
            context.setFillColor(NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor)
            context.fill(bounds)
        } else if let blurred = Self.blur(desktop) {
            context.draw(blurred, in: bounds)
        }
        context.restoreGState()
        // The wheel's tint through its profile.
        context.saveGState()
        context.clip(to: rect, mask: tintMask)
        context.setFillColor(NSColor.black.withAlphaComponent(RadialField.darkness).cgColor)
        context.fill(bounds)
        context.restoreGState()
        // The words.
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: field.canvas.size))
        view.configure(layout: layout, canvas: field.canvas, tree: shot.tree)
        view.settle(selection: shot.selection)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.saveGState()
        context.translateBy(x: wheelCentre.x - field.canvas.center.x, y: wheelCentre.y - field.canvas.center.y)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        // On a whole screen, the pointer: at the wheel's centre as it shows (moved there where
        // the wheel could not open around it), or on the word it lights.
        if shot.screen != nil {
            var pointer = centre
            if let word = layout.word(shot.selection) {
                pointer = CGPoint(x: centre.x + word.frame.midX, y: centre.y + word.frame.midY)
            }
            // An arrow pointer, its tip at `pointer` (the system's cursor image draws nothing offscreen).
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
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = picture
        return rep
    }

    /// A profile image as a picture: white where it is full, black where it is 0.
    private static func profile(_ image: CGImage, size: CGSize) -> NSBitmapImageRep? {
        guard let context = context(size: size), let mask = grey(image) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)
        context.clip(to: bounds, mask: mask)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        guard let out = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = size
        return rep
    }

    /// A profile's alpha as a grey image for clipping: white where the profile is full.
    private static func grey(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        var grey = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { grey[y * w + x] = bytes[y * image.bytesPerRow + x * 4 + 3] }
        }
        guard let provider = CGDataProvider(data: Data(grey) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
