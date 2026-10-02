import AppKit
import HUDKit

/// The widget grid on one display: square cells `cell` points wide, `gap` apart, inset
/// `margin` from the visible frame. Column 0 is at the left, row 0 at the top. Pure, so it
/// is unit tested.
struct WidgetGrid: Equatable {
    struct Cell: Hashable, Comparable, CustomStringConvertible {
        var col: Int
        var row: Int

        /// Column-major: down the first column, then the next.
        static func < (a: Cell, b: Cell) -> Bool { (a.col, a.row) < (b.col, b.row) }
        var description: String { "\(col),\(row)" }
    }

    var visible: CGRect
    var cell: CGFloat
    var gap: CGFloat
    var margin: CGFloat

    var pitch: CGFloat { cell + gap }
    var columns: Int { max(0, Int(((visible.width - 2 * margin + gap) / pitch).rounded(.down))) }
    var rows: Int { max(0, Int(((visible.height - 2 * margin + gap) / pitch).rounded(.down))) }

    /// The frame of a widget of `size` whose top-left cell is `at`.
    func frame(_ at: Cell, _ size: HUDWidgetSize) -> CGRect {
        let points = size.points(cell: cell, gap: gap)
        let top = visible.maxY - margin - CGFloat(at.row) * pitch
        return CGRect(x: visible.minX + margin + CGFloat(at.col) * pitch, y: top - points.height,
                      width: points.width, height: points.height)
    }

    /// The frame of one cell (for the edit-mode overlay).
    func cellFrame(_ at: Cell) -> CGRect { frame(at, .small) }

    /// Whether a widget of `size` at `at` lies inside the grid.
    func fits(_ at: Cell, _ size: HUDWidgetSize) -> Bool {
        at.col >= 0 && at.row >= 0 && at.col + size.cells.columns <= columns && at.row + size.cells.rows <= rows
    }

    /// The cells a widget of `size` at `at` covers.
    func cells(_ at: Cell, _ size: HUDWidgetSize) -> Set<Cell> {
        var out: Set<Cell> = []
        for c in 0..<size.cells.columns { for r in 0..<size.cells.rows { out.insert(Cell(col: at.col + c, row: at.row + r)) } }
        return out
    }

    /// `at` moved inside the grid for `size` (nil when the grid cannot hold `size` at all).
    func clamp(_ at: Cell, _ size: HUDWidgetSize) -> Cell? {
        let maxCol = columns - size.cells.columns, maxRow = rows - size.cells.rows
        guard maxCol >= 0, maxRow >= 0 else { return nil }
        return Cell(col: min(max(0, at.col), maxCol), row: min(max(0, at.row), maxRow))
    }

    /// The cell a widget dropped at `frame` snaps to: its top-left corner's nearest cell,
    /// kept inside the grid.
    func snap(_ frame: CGRect, _ size: HUDWidgetSize) -> Cell? {
        let col = Int(((frame.minX - visible.minX - margin) / pitch).rounded())
        let row = Int(((visible.maxY - margin - frame.maxY) / pitch).rounded())
        return clamp(Cell(col: col, row: row), size)
    }

    /// The free position for `size` nearest `near` (by distance between top-left cells, ties
    /// column-major), or nil when none is free.
    func nearestFree(_ size: HUDWidgetSize, near: Cell, occupied: Set<Cell>) -> Cell? {
        var best: (Cell, Int)?
        for at in positions(size) where cells(at, size).isDisjoint(with: occupied) {
            let dc = at.col - near.col, dr = at.row - near.row
            let d = dc * dc + dr * dr
            if best == nil || d < best!.1 { best = (at, d) }
        }
        return best?.0
    }

    /// The first free position for `size`, column-major from the top-left, or nil.
    func firstFree(_ size: HUDWidgetSize, occupied: Set<Cell>) -> Cell? {
        positions(size).first { cells($0, size).isDisjoint(with: occupied) }
    }

    /// Every position `size` fits at, column-major.
    private func positions(_ size: HUDWidgetSize) -> [Cell] {
        let maxCol = columns - size.cells.columns, maxRow = rows - size.cells.rows
        guard maxCol >= 0, maxRow >= 0 else { return [] }
        return (0...maxCol).flatMap { c in (0...maxRow).map { Cell(col: c, row: $0) } }
    }
}

/// Where every widget actually goes on the displays attached now. Records keep the cells
/// they were given; a record whose display is missing goes to the main display, one beyond
/// a smaller grid is pulled inside it, and one that would overlap a widget placed before it
/// (in record order) moves to the nearest free cells. Pure, so it is unit tested.
enum WidgetPlacement {
    struct Placed: Equatable {
        /// Index into the screens given.
        var screen: Int
        var cell: WidgetGrid.Cell
        var frame: CGRect
        /// Its display is not attached; it stands in on the main display.
        var screenMissing: Bool
        /// Placed somewhere else than its record says (pulled inside, or moved off another).
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

    /// `records` resolved on `screens`; records not in `shown` take no room (their type is
    /// gone, so nothing draws them).
    static func resolve(_ records: [WidgetRecord], screens: [WidgetScreen], config: WidgetsConfig,
                        shown: (WidgetRecord) -> Bool = { _ in true }) -> [String: Placed] {
        var out: [String: Placed] = [:]
        var occupied: [Int: Set<WidgetGrid.Cell>] = [:]
        for record in records where shown(record) {
            guard let (index, missing) = screenIndex(record.screen, screens: screens) else { continue }
            let grid = config.grid(on: screens[index].visible)
            var cell = grid.clamp(record.cell, record.size) ?? record.cell
            var overlapping = false
            let taken = occupied[index, default: []]
            if !grid.cells(cell, record.size).isDisjoint(with: taken) {
                if let free = grid.nearestFree(record.size, near: cell, occupied: taken) { cell = free }
                else { overlapping = true }
            }
            occupied[index, default: []].formUnion(grid.cells(cell, record.size))
            out[record.instance] = Placed(screen: index, cell: cell, frame: grid.frame(cell, record.size),
                                          screenMissing: missing, moved: cell != record.cell, overlapping: overlapping)
        }
        return out
    }
}
