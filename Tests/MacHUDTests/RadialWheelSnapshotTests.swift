import AppKit
import XCTest
@testable import MacHUDCore

/// Renders the loadout wheel offscreen to PNGs for review: no window is ordered in and nothing
/// acts on the desktop. Pictures go to `MACHUD_WHEEL_SNAPSHOT_DIR`, else a temporary folder
/// (printed). The glass does not render offscreen, so the tiles are drawn over a dark fill.
@MainActor
final class RadialWheelSnapshotTests: XCTestCase {
    private static let short = ["Code", "Reading", "Mail", "Focus", "Notes", "Music", "Chat", "Docs", "Plan"]
    private static let long = ["Morning research and writing", "dev: Browsers", "Messaging", "Quarterly planning review",
                               "Design critique", "Evening reading", "Code", "Customer support rotation", "Music"]

    private var directory: URL {
        ProcessInfo.processInfo.environment["MACHUD_WHEEL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("machud-wheel-snapshots-\(getpid())")
    }

    private static func symbol(_ name: String) -> [NSImage] {
        [NSImage(systemSymbolName: name, accessibilityDescription: nil)].compactMap { $0 }
    }

    private static func appIcons(_ ids: [String]) -> [NSImage] {
        ids.compactMap { RadialMenu.icon(for: .app(bundleID: $0, titleMatch: nil), panels: nil) }
    }

    private static let apps = ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.mail", "com.apple.Music"]

    /// `loadouts` loadout wedges named from `names`, then Capture, Park and (when `widgets`) Widgets.
    private static func wedges(_ names: [String], loadouts: Int, widgets: Bool = true,
                               allScreens: Bool = false, park: RadialMenu.Wedge.ParkTargets = .init()) -> [RadialMenu.Wedge] {
        var out = (0..<loadouts).map { i in
            RadialMenu.Wedge(name: names[i % names.count], icons: appIcons(Array(apps.prefix(2 + i % 4))),
                             kind: .loadout(names[i % names.count]))
        }
        out.append(RadialMenu.Wedge(name: "Capture", icons: symbol("camera.viewfinder"),
                                    kind: .capture(offersAllScreens: allScreens)))
        out.append(RadialMenu.Wedge(name: "Park", icons: symbol("rectangle.portrait.and.arrow.right"), kind: .park(park)))
        if widgets { out.append(RadialMenu.Wedge(name: "Widgets", icons: symbol("square.grid.2x2"), kind: .widgets)) }
        return out
    }

    private func shoot(_ name: String, _ wedges: [RadialMenu.Wedge], _ selection: RadialGeometry.Selection,
                       backdrop: NSColor? = nil, into files: inout [URL]) throws {
        let url = directory.appendingPathComponent("wheel-\(name).png")
        try RadialMenu.writeSnapshot(wedges: wedges, selection: selection, backdrop: backdrop, to: url)
        files.append(url)
    }

    func testSnapshotsOfTheWheel() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []

        // 3, 6, 9 and 12 wedges, short names and long ones, the first loadout on Apply.
        for (count, widgets) in [(3, false), (6, true), (9, true), (12, true)] {
            let loadouts = count - (widgets ? 3 : 2)
            for (label, names) in [("short", Self.short), ("long", Self.long)] {
                try shoot("\(String(format: "%02d", count))-\(label)", Self.wedges(names, loadouts: loadouts, widgets: widgets),
                          .wedge(index: 0, ring: .middle), into: &files)
            }
        }
        // Nothing highlighted; and over a white page, which the glass lets through.
        try shoot("06-idle", Self.wedges(Self.long, loadouts: 3), .cancel, into: &files)
        try shoot("06-bright-desktop", Self.wedges(Self.long, loadouts: 3), .wedge(index: 1, ring: .outer),
                  backdrop: .white, into: &files)

        // Each ring of a loadout wedge at the top (0), the right side (2) and the bottom (4) of
        // an eight-wedge wheel.
        let eight = Self.wedges(Self.long, loadouts: 5)
        for (place, index) in [("top", 0), ("side", 2), ("bottom", 4)] {
            for ring in RadialGeometry.Ring.allCases {
                try shoot("08-\(place)-\(ring.rawValue)", eight, .wedge(index: index, ring: ring), into: &files)
            }
        }

        // Park: with and without a focused window, with one and with several parked.
        let parkCases: [(String, RadialMenu.Wedge.ParkTargets)] = [
            ("nothing", .init()),
            ("focused", .init(focused: "Safari · Apple Developer Documentation")),
            ("one-parked", .init(focused: nil, parked: ["Mail · Inbox"])),
            ("several-parked", .init(focused: "Notes · Groceries", parked: ["Mail · Inbox", "Terminal", "Music"])),
        ]
        for (label, targets) in parkCases {
            let wedges = Self.wedges(Self.long, loadouts: 3, park: targets)
            for ring in [RadialGeometry.Ring.inner, .middle] {
                try shoot("park-\(label)-\(ring.rawValue)", wedges, .wedge(index: 4, ring: ring), into: &files)
            }
        }

        // Widgets: reveal and edit.
        let widgets = Self.wedges(Self.long, loadouts: 3)
        try shoot("widgets-inner", widgets, .wedge(index: 5, ring: .inner), into: &files)
        try shoot("widgets-middle", widgets, .wedge(index: 5, ring: .middle), into: &files)

        // Capture, with and without the experimental every-screen ring.
        for (label, allScreens) in [("one-screen", false), ("all-screens", true)] {
            let wedges = Self.wedges(Self.long, loadouts: 3, allScreens: allScreens)
            for ring in RadialGeometry.Ring.allCases.prefix(RadialMenu.ringCount(for: .capture(offersAllScreens: allScreens))) {
                try shoot("capture-\(label)-\(ring.rawValue)", wedges, .wedge(index: 3, ring: ring), into: &files)
            }
        }

        try assertNotBlank(files)
        print("Wheel snapshots: \(directory.path)")
    }

    /// Each picture is not blank: the wheel differs from the corner.
    private func assertNotBlank(_ files: [URL]) throws {
        for url in files {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)), url.lastPathComponent)
            let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1))
            let middle = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 3))
            XCTAssertNotEqual(corner, middle, "\(url.lastPathComponent) is blank")
        }
    }
}
