import AppKit
import CoreImage
import XCTest
@testable import MacHUDCore

/// Renders the loadout wheel offscreen for review, as the screen would show it: a generated
/// desktop (shapes and text, never a screenshot), sharp outside the field and, inside it,
/// blurred (a Gaussian of radius 25 pt, the soft backdrop's) through the field's blur profile,
/// under the wheel's tint through its tint profile, with the wheel's view drawn on top. No window is ordered in and nothing acts on the desktop. Pictures go to
/// `MACHUD_WHEEL_SNAPSHOT_DIR`; without it they are rendered and checked, and nothing is written.
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

    /// `loadouts` loadout wedges named from `names`, then Capture, Park and (when `widgets`) Widgets.
    private static func wedges(_ names: [String], loadouts: Int, widgets: RadialMenu.Wedge.WidgetsState? = .init(),
                               allScreens: Bool = false, park: RadialMenu.Wedge.ParkTargets = .init()) -> [RadialMenu.Wedge] {
        var out = (0..<loadouts).map { i in
            RadialMenu.Wedge(name: names[i % names.count], icons: appIcons(2 + i % 4), kind: .loadout(names[i % names.count]))
        }
        out.append(RadialMenu.Wedge(name: "Capture", icons: symbol("camera.viewfinder"), kind: .capture(offersAllScreens: allScreens)))
        out.append(RadialMenu.Wedge(name: "Park", icons: symbol("rectangle.portrait.and.arrow.right"), kind: .park(park)))
        if let widgets { out.append(RadialMenu.Wedge(name: "Widgets", icons: symbol("square.grid.2x2"), kind: .widgets(widgets))) }
        return out
    }

    struct Shot {
        var name: String
        var wedges: [RadialMenu.Wedge]
        var selection: RadialGeometry.Selection
        var desktop: Desktop
        var resting: RadialMenu.RestingButtons = .faint
        /// Reduce transparency on: the soft backdrop shows the system's opaque material.
        var reduced = false
        /// The field's outline: the wheel's, or (for comparison, pictures only) a plain ellipse
        /// around every word with the same full blur inside and the same fade.
        var ellipse = false
        /// A whole screen of this visible size (a 24 pt menu bar above it), the wheel opened at `pointer`.
        var screen: CGSize?
        var pointer: CGPoint = .zero
    }

    // MARK: The set

    private func shots() -> [Shot] {
        var out: [Shot] = []
        let desktops = Desktop.allCases
        func desktop(_ n: Int) -> Desktop { desktops[n % desktops.count] }

        // At rest: 3, 6, 8 and 12 wedges, and long names at 6 and 12.
        out.append(Shot(name: "rest-03-bright", wedges: Self.wedges(Self.short, loadouts: 1, widgets: nil), selection: .cancel, desktop: .bright))
        out.append(Shot(name: "rest-06-dark", wedges: Self.wedges(Self.short, loadouts: 3), selection: .cancel, desktop: .dark))
        out.append(Shot(name: "rest-08-colourful", wedges: Self.wedges(Self.short, loadouts: 5), selection: .cancel, desktop: .colourful))
        out.append(Shot(name: "rest-12-bright", wedges: Self.wedges(Self.short, loadouts: 9), selection: .cancel, desktop: .bright))
        out.append(Shot(name: "rest-06-long-colourful", wedges: Self.wedges(Self.long, loadouts: 3), selection: .cancel, desktop: .colourful))
        out.append(Shot(name: "rest-12-long-dark", wedges: Self.wedges(Self.long, loadouts: 9), selection: .cancel, desktop: .dark))

        // A loadout wedge with each ring hovered at the top, a diagonal, the side and the bottom.
        let eight = Self.wedges(Self.long, loadouts: 5)
        var n = 0
        for (place, index) in [("top", 0), ("diagonal", 1), ("side", 2), ("bottom", 4)] {
            for ring in RadialGeometry.Ring.allCases {
                out.append(Shot(name: "hover-08-\(place)-\(ring.rawValue)-\(desktop(n).rawValue)", wedges: eight,
                                selection: .wedge(index: index, ring: ring), desktop: desktop(n)))
                n += 1
            }
        }
        out.append(Shot(name: "hover-12-long-side-outer-bright", wedges: Self.wedges(Self.long, loadouts: 9),
                        selection: .wedge(index: 3, ring: .outer), desktop: .bright))

        // Park: no focused window, focused, one parked, several parked; a two-line hint.
        let park: [(String, RadialMenu.Wedge.ParkTargets, RadialGeometry.Ring)] = [
            ("nothing-inner", .init(), .inner),
            ("focused-inner", .init(focused: "Safari · Apple Developer Documentation"), .inner),
            ("one-parked-middle", .init(focused: nil, parked: ["Mail · Inbox"]), .middle),
            ("several-parked-middle", .init(focused: "Notes · Groceries", parked: ["Mail · Inbox", "Terminal", "Music"]), .middle),
            ("long-title-inner", .init(focused: "Safari · How to design a radial menu that reads clearly over any desktop, with examples and a long subtitle"), .inner),
        ]
        for (k, (label, targets, ring)) in park.enumerated() {
            out.append(Shot(name: "park-\(label)-\(desktop(k).rawValue)", wedges: Self.wedges(Self.long, loadouts: 3, park: targets),
                            selection: .wedge(index: 4, ring: ring), desktop: desktop(k)))
        }

        // Widgets: reveal, edit; and while revealed (Lower) and while editing (Done).
        let widgets: [(String, RadialMenu.Wedge.WidgetsState, RadialGeometry.Ring)] = [
            ("reveal", .init(), .inner), ("edit", .init(), .middle),
            ("lower", .init(revealed: true), .inner), ("done", .init(editing: true), .middle),
        ]
        for (k, (label, state, ring)) in widgets.enumerated() {
            out.append(Shot(name: "widgets-\(label)-\(desktop(k + 1).rawValue)", wedges: Self.wedges(Self.long, loadouts: 3, widgets: state),
                            selection: .wedge(index: 5, ring: ring), desktop: desktop(k + 1)))
        }

        // Capture, with and without the every-screen ring.
        out.append(Shot(name: "capture-one-screen-inner-dark", wedges: Self.wedges(Self.long, loadouts: 3),
                        selection: .wedge(index: 3, ring: .inner), desktop: .dark))
        out.append(Shot(name: "capture-one-screen-middle-bright", wedges: Self.wedges(Self.long, loadouts: 3),
                        selection: .wedge(index: 3, ring: .middle), desktop: .bright))
        for (k, ring) in RadialGeometry.Ring.allCases.enumerated() {
            out.append(Shot(name: "capture-all-screens-\(ring.rawValue)-\(desktop(k + 2).rawValue)",
                            wedges: Self.wedges(Self.long, loadouts: 3, allScreens: true),
                            selection: .wedge(index: 3, ring: ring), desktop: desktop(k + 2)))
        }

        // Variant B: only the hovered wedge's buttons.
        out.append(Shot(name: "variant-b-rest-08-bright", wedges: eight, selection: .cancel, desktop: .bright, resting: .hidden))
        out.append(Shot(name: "variant-b-hover-08-side-middle-colourful", wedges: eight, selection: .wedge(index: 2, ring: .middle),
                        desktop: .colourful, resting: .hidden))
        out.append(Shot(name: "variant-b-hover-12-long-top-inner-dark", wedges: Self.wedges(Self.long, loadouts: 9),
                        selection: .wedge(index: 0, ring: .inner), desktop: .dark, resting: .hidden))

        // The system's material (Reduce transparency on): opaque and dark, through a plain soft disc.
        out.append(Shot(name: "system-material-reduce-transparency-08-bright", wedges: eight,
                        selection: .wedge(index: 1, ring: .middle), desktop: .bright, reduced: true))
        // A plain ellipse around every word in place of the wheel's outline, for comparison.
        out.append(Shot(name: "ellipse-rest-08-bright", wedges: eight, selection: .cancel, desktop: .bright, ellipse: true))
        out.append(Shot(name: "ellipse-hover-08-side-middle-colourful", wedges: eight, selection: .wedge(index: 2, ring: .middle),
                        desktop: .colourful, ellipse: true))

        // A 13-inch display at Larger Text (1024 by 640, less the menu bar), eight wedges, the
        // wheel opened near the bottom right corner.
        out.append(Shot(name: "screen-1024x640-08-corner-bright", wedges: eight, selection: .wedge(index: 2, ring: .outer),
                        desktop: .bright, screen: CGSize(width: 1024, height: 616), pointer: CGPoint(x: 960, y: 40)))
        out.append(Shot(name: "screen-1024x640-08-middle-colourful", wedges: eight, selection: .cancel,
                        desktop: .colourful, screen: CGSize(width: 1024, height: 616), pointer: CGPoint(x: 512, y: 308)))
        return out
    }

    func testSnapshotsOfTheWheel() throws {
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var pictures = try shots().map { shot in (shot.name, try XCTUnwrap(render(shot), shot.name)) }
        // The two profiles alone at eight wedges, white where they are full.
        let field = RadialField(layout: RadialLayout(wedges: Self.wedges(Self.long, loadouts: 5)), reduced: false)
        pictures.append(("profile-blur-08", try XCTUnwrap(Self.profile(field.blurImage, size: field.support.size))))
        pictures.append(("profile-tint-08", try XCTUnwrap(Self.profile(field.tintImage, size: field.support.size))))
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
    /// opens again, at eight and twelve wedges on a large and a small display; and one frame
    /// of twelve wedges' words with a button lit.
    func testHowLongTheWheelTakesToOpenAndToDraw() throws {
        let displays = [("1440x900", RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900)),
                        ("1024x640", RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 616), primaryHeight: 640))]
        for (label, display) in displays {
            for loadouts in [5, 9] {
                let wedges = Self.wedges(Self.long, loadouts: loadouts)
                let menu = RadialMenu()
                menu.warpPointer = { _ in }
                let context = try XCTUnwrap(Self.context(size: CGSize(width: 1400, height: 1400)))
                var times: [Double] = []
                for _ in 0..<3 {
                    let start = Date()
                    menu.prepare(wedges: Self.wedges(Self.long, loadouts: loadouts), at: CGPoint(x: display.frame.midX, y: display.frame.midY),
                                 on: display, movesPointer: true)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { menu.wheel.draw(menu.wheel.bounds) }
                    NSGraphicsContext.restoreGraphicsState()
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                print(String(format: "Wheel open to first frame, %d wedges on %@: first %.0f ms, then %.0f ms and %.0f ms",
                             wedges.count, label, times[0], times[1], times[2]))
            }
        }

        let wedges = Self.wedges(Self.long, loadouts: 9)
        let layout = RadialLayout(wedges: wedges)
        let field = RadialField(layout: layout, reduced: false)
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: field.canvas.size))
        view.configure(layout: layout, field: field, wedges: wedges)
        view.settle(selection: .wedge(index: 3, ring: .middle))
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
        print(String(format: "Wheel frame at twelve wedges: %.2f ms", elapsed / Double(frames) * 1000))
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
            let placed = RadialMenu.place(wedges: shot.wedges, at: shot.pointer, visibleFrame: CGRect(origin: .zero, size: screen))
            layout = placed.layout
            centre = placed.center
            size = CGSize(width: screen.width, height: screen.height + 24)
        } else {
            layout = RadialLayout(wedges: shot.wedges)
            centre = .zero
            size = .zero
        }
        let field = RadialField(layout: layout, reduced: shot.reduced)
        // The blur's and the tint's images and where they go, in the wheel's coordinates.
        let profiles = shot.ellipse ? Self.ellipse(layout) : (rect: field.support, blur: field.blurImage, tint: field.tintImage)
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
        // The wheel's tint through its profile, as dark as the backdrop's path asks.
        context.saveGState()
        context.clip(to: rect, mask: tintMask)
        context.setFillColor(NSColor.black.withAlphaComponent(RadialBackdrop.darkness(for: shot.reduced ? .systemMaterial : .blur)).cgColor)
        context.fill(bounds)
        context.restoreGState()
        // The words.
        let view = RadialWheelView(frame: CGRect(origin: .zero, size: field.canvas.size))
        view.restingButtons = shot.resting
        view.configure(layout: layout, field: field, wedges: shot.wedges)
        view.settle(selection: shot.selection)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.translateBy(x: wheelCentre.x - field.canvas.center.x, y: wheelCentre.y - field.canvas.center.y)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = picture
        return rep
    }

    /// The profiles of a plain ellipse around every place a word can be (`RadialField.places`),
    /// padded like the wheel's field: full inside, fading over the same distance, the tint weaker
    /// toward the rim by the same amount. Pictures only.
    private static func ellipse(_ layout: RadialLayout) -> (rect: CGRect, blur: CGImage, tint: CGImage) {
        let places = RadialField.places(layout)
        let box = places.reduce(places[0]) { $0.union($1) }
        let c = CGPoint(x: box.midX, y: box.midY)
        let corners = places.flatMap { r in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                              CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] }
        let (X, Y) = (box.width / 2, box.height / 2)
        let reach = corners.map { hypot(($0.x - c.x) / X, ($0.y - c.y) / Y) }.max() ?? 1
        let pad = RadialField.pad * layout.scale, fade = RadialField.fade * layout.scale
        let (a, b) = (X * reach + pad, Y * reach + pad)
        let farthest = corners.map { hypot($0.x, $0.y) }.max() ?? 1
        func blur(_ p: CGPoint) -> CGFloat {
            let (dx, dy) = (p.x - c.x, p.y - c.y)
            let rho = hypot(dx / a, dy / b)
            guard rho > 1 else { return 1 }
            let d = hypot(dx, dy) * (1 - 1 / rho)
            guard d < fade else { return 0 }
            let t = d / fade
            return 1 - t * t * t * (t * (t * 6 - 15) + 10)
        }
        func tint(_ p: CGPoint) -> CGFloat {
            let u = min(1, hypot(p.x, p.y) / farthest)
            return blur(p) * (1 - RadialField.rim * u * u * (3 - 2 * u))
        }
        let room = CGRect(x: c.x - a - fade - 8, y: c.y - b - fade - 8, width: 2 * (a + fade + 8), height: 2 * (b + fade + 8)).integral
        let images = RadialField.images(over: room) { p in (blur(p), tint(p)) }
        return (images.0, images.1, images.2)
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

    private func assertNotBlank(_ rep: NSBitmapImageRep, _ name: String) throws {
        let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1))
        let middle = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        XCTAssertNotEqual(corner, middle, "\(name) is blank")
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
