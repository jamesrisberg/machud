import AppKit
import HUDKit

/// The layout grid on one display as widgets use it: `grid.cols` × `grid.rows` lines over the
/// visible frame, the same lines the layout editor draws and regions snap to. A widget keeps
/// its fixed size in points (`HUDWidgetSize.points()`); on each axis whichever of its edges is
/// nearer a line snaps to it, so it can sit flush against a region's edge or the visible
/// frame's. Pure, so it is unit tested.
struct WidgetGrid: Equatable {
    /// A widget's top-left corner as fractions of the visible frame, measured from its top-left
    /// corner (the convention of regions' `FractionRect`).
    struct Position: Equatable {
        var x: Double
        var y: Double
    }

    var visible: CGRect
    var grid: GridSize

    var cols: Int { max(1, grid.cols) }
    var rows: Int { max(1, grid.rows) }

    /// The frame of a widget of `size` whose top-left is at `p`, as stored (not snapped).
    func frame(_ p: Position, _ size: HUDWidgetSize) -> CGRect {
        let s = size.points()
        return CGRect(x: visible.minX + CGFloat(p.x) * visible.width, y: visible.maxY - CGFloat(p.y) * visible.height - s.height,
                      width: s.width, height: s.height)
    }

    /// Where `frame`'s top-left is, as fractions (to six places, which is well under a point).
    func position(of frame: CGRect) -> Position {
        Position(x: Self.fraction(frame.minX - visible.minX, of: visible.width),
                 y: Self.fraction(visible.maxY - frame.maxY, of: visible.height))
    }

    /// The position of grid line `col` across and `row` down.
    func position(col: Double, row: Double) -> Position {
        Position(x: col / Double(cols), y: row / Double(rows))
    }

    /// `p` in grid-line units: whole numbers when the left and top edges sit on lines.
    func lines(_ p: Position) -> (col: Double, row: Double) {
        (Self.tidy(p.x * Double(cols)), Self.tidy(p.y * Double(rows)))
    }

    // MARK: - Snapping

    /// `frame` snapped on each axis by whichever edge is nearer a line, kept inside the visible
    /// frame. Exact (lines fall between points), so a stored position stays on its line.
    func snap(_ frame: CGRect) -> CGRect {
        place(left: Self.snapAxis(frame.minX - visible.minX, length: frame.width, extent: visible.width, lines: cols),
              top: Self.snapAxis(visible.maxY - frame.maxY, length: frame.height, extent: visible.height, lines: rows),
              size: frame.size)
    }

    /// Where a widget at `start` lands when dragged by `delta` (the layout editor's drag and an
    /// app's frame event go through the same snap).
    func dragged(_ start: CGRect, by delta: CGSize) -> CGRect {
        snap(start.offsetBy(dx: delta.width, dy: delta.height))
    }

    /// One axis: `start` is the leading edge's offset into an `extent` cut by `lines` equal
    /// steps. The leading edge goes to its nearest line unless the trailing edge is strictly
    /// nearer to one; then the result is kept inside `0...extent - length` (0 when it is longer
    /// than the extent), which puts it flush against that end.
    static func snapAxis(_ start: CGFloat, length: CGFloat, extent: CGFloat, lines: Int) -> CGFloat {
        let step = extent / CGFloat(max(1, lines))
        guard step > 0 else { return 0 }
        let lead = (start / step).rounded() * step
        let trail = ((start + length) / step).rounded() * step - length
        let snapped = abs(trail - start) < abs(lead - start) ? trail : lead
        return min(max(snapped, 0), max(0, extent - length))
    }

    // MARK: - Free spots

    /// Whether two widgets overlap; touching edges do not.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - 0.5 && b.minX < a.maxX - 0.5 && a.minY < b.maxY - 0.5 && b.minY < a.maxY - 0.5
    }

    /// The free snapped spot for `size` nearest `near` (by top-left corner; ties go left, then
    /// up), or nil when none is free.
    func nearestFree(_ size: HUDWidgetSize, near: CGRect, occupied: [CGRect]) -> CGRect? {
        let anchor = CGPoint(x: near.minX, y: near.maxY)
        var best: (frame: CGRect, distance: CGFloat)?
        for frame in spots(size, trailing: true) where !occupied.contains(where: { Self.overlaps($0, frame) }) {
            let d = hypot(frame.minX - anchor.x, frame.maxY - anchor.y)
            if best == nil || d < best!.distance - 0.001 { best = (frame, d) }
        }
        return best?.frame
    }

    /// The first free spot for `size` with its left and top edges on lines (or flush with the
    /// right and bottom ends), down the first column, then the next; nil when none is free.
    func firstFree(_ size: HUDWidgetSize, occupied: [CGRect]) -> CGRect? {
        spots(size, trailing: false).first { frame in !occupied.contains { Self.overlaps($0, frame) } }
    }

    /// Every snapped spot for `size`, left to right and top to bottom within each column.
    /// `trailing` adds the spots whose right or bottom edge is on a line.
    private func spots(_ size: HUDWidgetSize, trailing: Bool) -> [CGRect] {
        let s = size.points()
        let lefts = Self.stops(length: s.width, extent: visible.width, lines: cols, trailing: trailing)
        let tops = Self.stops(length: s.height, extent: visible.height, lines: rows, trailing: trailing)
        var seen = Set<[CGFloat]>()
        var out: [CGRect] = []
        for left in lefts {
            for top in tops {
                let frame = place(left: left, top: top, size: s)
                if seen.insert([frame.minX, frame.minY]).inserted { out.append(frame) }
            }
        }
        return out
    }

    /// The offsets along one axis a widget of `length` can snap to, ascending.
    private static func stops(length: CGFloat, extent: CGFloat, lines: Int, trailing: Bool) -> [CGFloat] {
        let n = max(1, lines)
        let step = extent / CGFloat(n)
        let room = max(0, extent - length)
        var out: Set<CGFloat> = [room]
        for i in 0...n {
            let line = CGFloat(i) * step
            if line <= room + 0.001 { out.insert(min(line, room)) }
            if trailing, line - length >= -0.001 { out.insert(min(max(line - length, 0), room)) }
        }
        return out.sorted()
    }

    /// A snapped frame as a widget window gets it: its origin on whole points.
    static func aligned(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width, height: frame.height)
    }

    /// Cocoa frame for offsets from the visible frame's top-left, to a thousandth of a point
    /// so float noise cannot tell two spots on the same line apart.
    private func place(left: CGFloat, top: CGFloat, size: CGSize) -> CGRect {
        func clean(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }
        return CGRect(x: clean(visible.minX + left), y: clean(visible.maxY - top - size.height),
                      width: size.width, height: size.height)
    }

    private static func fraction(_ v: CGFloat, of extent: CGFloat) -> Double {
        guard extent > 0 else { return 0 }
        return (Double(v / extent) * 1e6).rounded() / 1e6
    }

    /// Two places, so a line index reads as a whole number.
    private static func tidy(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// Where every widget actually goes on the displays attached now. Records keep the position
/// they were given; each is snapped to its display's grid, a record whose display is missing
/// goes to the main display, and one that would overlap a widget placed before it (in record
/// order) moves to the nearest free spot. Pure, so it is unit tested.
enum WidgetPlacement {
    struct Placed: Equatable {
        /// Index into the screens given.
        var screen: Int
        /// The widget window's frame: `snapped` on whole points.
        var frame: CGRect
        /// Exactly on the grid; collisions and positions are worked out on this.
        var snapped: CGRect
        /// The frame's top-left on its display.
        var position: WidgetGrid.Position
        /// Its display is not attached; it stands in on the main display.
        var screenMissing: Bool
        /// Placed somewhere else than its record says (pulled inside, moved off another, or a
        /// display whose size changed).
        var moved: Bool
        /// No free room for it: it overlaps another widget.
        var overlapping: Bool
    }

    /// The display a record is on: its own when attached, else the main one.
    static func screenIndex(_ ref: ScreenRef?, screens: [WidgetScreen]) -> (index: Int, missing: Bool)? {
        let descriptors = screens.map(\.descriptor)
        if let ref, let i = ref.index(in: descriptors) { return (i, false) }
        guard let main = ScreenRef.main.index(in: descriptors) else { return nil }
        return (main, ref != nil)
    }

    /// `records` resolved on `screens` with the layout grid `grid`; records not in `shown` take
    /// no room (their type is gone, so nothing draws them).
    static func resolve(_ records: [WidgetRecord], screens: [WidgetScreen], grid: GridSize,
                        legacy: WidgetsConfig.LegacyGrid = .standard,
                        shown: (WidgetRecord) -> Bool = { _ in true }) -> [String: Placed] {
        var out: [String: Placed] = [:]
        var occupied: [Int: [CGRect]] = [:]
        for record in records where shown(record) {
            guard let (index, missing) = screenIndex(record.screen, screens: screens) else { continue }
            let g = WidgetGrid(visible: screens[index].visible, grid: grid)
            let stored = record.frame(on: g, legacy: legacy)
            var frame = g.snap(stored)
            var overlapping = false
            let taken = occupied[index, default: []]
            if taken.contains(where: { WidgetGrid.overlaps($0, frame) }) {
                if let free = g.nearestFree(record.size, near: frame, occupied: taken) { frame = free }
                else { overlapping = true }
            }
            occupied[index, default: []].append(frame)
            let moved = abs(frame.minX - stored.minX) > 1 || abs(frame.maxY - stored.maxY) > 1
            out[record.instance] = Placed(screen: index, frame: WidgetGrid.aligned(frame), snapped: frame,
                                          position: g.position(of: frame), screenMissing: missing, moved: moved,
                                          overlapping: overlapping)
        }
        return out
    }
}

/// Converts records saved on the older widget cell grid (`col`/`row` with `widgets.cell`, `gap`
/// and `margin`) to positions on the layout grid, in layouts.json and in every HUD loadout.
/// Run on load, before anything uses the config; the next save writes the new form only.
enum WidgetMigration {
    static func migrate(_ config: Config, screens: [WidgetScreen]) -> Config {
        guard !screens.isEmpty else { return config }
        let legacy = config.widgets?.legacyGrid ?? .standard
        let grid = config.grid ?? .default
        var out = config
        func convert(_ records: [WidgetRecord]) -> [WidgetRecord] {
            records.map { record in
                guard record.legacyCell != nil,
                      let index = WidgetPlacement.screenIndex(record.screen, screens: screens)?.index else { return record }
                let g = WidgetGrid(visible: screens[index].visible, grid: grid)
                var r = record
                r.position = g.position(of: g.snap(record.frame(on: g, legacy: legacy)))
                r.legacyCell = nil
                return r
            }
        }
        if var widgets = out.widgets {
            widgets.instances = convert(widgets.instances)
            if !widgets.instances.contains(where: { $0.legacyCell != nil }) { widgets.legacyGrid = nil }
            out.widgets = widgets
        }
        if let loadouts = out.loadouts {
            out.loadouts = loadouts.map { loadout in
                guard let set = loadout.hud?.widgets else { return loadout }
                var l = loadout
                l.hud?.widgets = convert(set)
                return l
            }
        }
        return out
    }
}
