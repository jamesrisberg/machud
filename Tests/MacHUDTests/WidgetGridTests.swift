import XCTest
import HUDKit
@testable import MacHUDCore

/// Widgets on the layout grid: snapping, collisions, placement and the conversion of records
/// saved on the older cell grid.
final class WidgetGridTests: XCTestCase {
    // 1440 × 875 visible on the default 96 × 54 grid: lines every 15 pt across and
    // 875 / 54 ≈ 16.2 pt down.
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    var grid: WidgetGrid { WidgetGrid(visible: visible, grid: .default) }
    typealias Position = WidgetGrid.Position

    let main = WidgetScreen(descriptor: ScreenDescriptor(name: "Main", isMain: true, isBuiltin: true), ref: .builtin,
                            visible: CGRect(x: 0, y: 0, width: 1440, height: 875), frame: CGRect(x: 0, y: 0, width: 1440, height: 900))

    // MARK: Snapping

    func testEachAxisSnapsWhicheverEdgeIsNearerALine() {
        // Leading 24 is 6 from line 30; trailing 194 is 1 from line 195: the trailing edge snaps.
        XCTAssertEqual(WidgetGrid.snapAxis(24, length: 170, extent: 1440, lines: 96), 25)
        // Leading 31 is 1 from line 30; trailing 201 is 6 from 195: the leading edge snaps.
        XCTAssertEqual(WidgetGrid.snapAxis(31, length: 170, extent: 1440, lines: 96), 30)
        // Trailing 270 is on a line already.
        XCTAssertEqual(WidgetGrid.snapAxis(100, length: 170, extent: 1440, lines: 96), 100)
        // A tie (5 from line 30, trailing 205 is 5 from 210) keeps the leading edge on its line.
        XCTAssertEqual(WidgetGrid.snapAxis(35, length: 170, extent: 1440, lines: 96), 30)
    }

    func testSnappedWidgetsSitFlushAgainstTheVisibleFrameAndStayInside() {
        let g = grid
        let right = g.snap(CGRect(x: 1290, y: 300, width: 170, height: 170))
        XCTAssertEqual(right.maxX, visible.maxX, "flush with the right edge")
        let left = g.snap(CGRect(x: -40, y: 300, width: 170, height: 170))
        XCTAssertEqual(left.minX, visible.minX, "flush with the left edge")
        let top = g.snap(CGRect(x: 300, y: 720, width: 170, height: 170))
        XCTAssertEqual(top.maxY, visible.maxY, "flush under the menu bar")
        let bottom = g.snap(CGRect(x: 300, y: -500, width: 356, height: 356))
        XCTAssertEqual(bottom.minY, visible.minY, "flush with the bottom (the Dock)")
        XCTAssertTrue(visible.contains(g.snap(CGRect(x: 5000, y: 5000, width: 728, height: 356))), "kept inside")
        XCTAssertEqual(g.snap(CGRect(x: 30, y: 30, width: 2000, height: 170)).minX, 0, "too wide: at the left edge")
    }

    func testPositionsStayExactlyOnTheirLines() {
        let g = grid
        // Line 27 down is 437.5 pt: the window goes on a whole point, the position stays on the line.
        let snapped = g.snap(g.frame(g.position(col: 12, row: 27), .small))
        XCTAssertEqual(g.position(of: snapped), Position(x: 0.125, y: 0.5))
        XCTAssertEqual(WidgetGrid.aligned(snapped), CGRect(x: 180, y: 268, width: 170, height: 170))
    }

    func testFramesAndPositionsUseTheRegionConvention() {
        let g = grid
        // Top-left based fractions, like regions; the size is the type's fixed points.
        XCTAssertEqual(g.frame(Position(x: 0, y: 0), .small), CGRect(x: 0, y: 705, width: 170, height: 170))
        XCTAssertEqual(g.frame(Position(x: 0.5, y: 0), .medium), CGRect(x: 720, y: 705, width: 356, height: 170))
        XCTAssertEqual(g.position(of: CGRect(x: 720, y: 705, width: 356, height: 170)), Position(x: 0.5, y: 0))
        XCTAssertEqual(g.position(col: 12, row: 27), Position(x: 0.125, y: 0.5))
        XCTAssertEqual(g.lines(Position(x: 0.125, y: 0.5)).col, 12)
        XCTAssertEqual(g.lines(Position(x: 0.125, y: 0.5)).row, 27)
        // On a display somewhere else in the global space.
        let side = WidgetGrid(visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055), grid: .default)
        XCTAssertEqual(side.frame(Position(x: 0, y: 0), .small), CGRect(x: 1440, y: 885, width: 170, height: 170))
    }

    func testSnappingIsStableForAPlacedWidget() {
        let g = grid
        let cases: [(CGRect, HUDWidgetSize)] = [(CGRect(x: 24, y: 600, width: 170, height: 170), .small),
                                                 (CGRect(x: 1203, y: 41, width: 356, height: 356), .large),
                                                 (CGRect(x: 611, y: 333, width: 728, height: 356), .extraLarge)]
        for (raw, size) in cases {
            let once = g.snap(raw)
            XCTAssertEqual(g.snap(g.frame(g.position(of: once), size)), once, "\(raw)")
        }
    }

    // MARK: Collisions

    func testWidgetsMayTouchButNotOverlap() {
        XCTAssertFalse(WidgetGrid.overlaps(CGRect(x: 0, y: 0, width: 170, height: 170), CGRect(x: 170, y: 0, width: 170, height: 170)))
        XCTAssertTrue(WidgetGrid.overlaps(CGRect(x: 0, y: 0, width: 170, height: 170), CGRect(x: 160, y: 100, width: 170, height: 170)))
    }

    func testFirstFreeFillsDownTheFirstColumnOnGridLines() throws {
        let g = grid
        let first = try XCTUnwrap(g.firstFree(.medium, occupied: []))
        XCTAssertEqual(first, CGRect(x: 0, y: 705, width: 356, height: 170), "top-left, flush")
        // Next: the first line below it (line 11, 178.2 pt down).
        XCTAssertEqual(g.firstFree(.small, occupied: [first]).map(WidgetGrid.aligned), CGRect(x: 0, y: 527, width: 170, height: 170))
        let column = (0..<5).map { CGRect(x: 0, y: 875 - 175 * CGFloat($0 + 1), width: 170, height: 170) }
        XCTAssertEqual(g.firstFree(.small, occupied: column)?.minX, 180, "a full column: the next line across")
    }

    func testNearestFreeIsTheClosestSnappedSpot() throws {
        let g = grid
        let taken = [CGRect(x: 0, y: 705, width: 170, height: 170)]
        // Dropped onto the taken one, a little to the right: beside it, its right edge on line 23
        // (345) and its bottom edge on line 11.
        let near = try XCTUnwrap(g.nearestFree(.small, near: CGRect(x: 30, y: 700, width: 170, height: 170), occupied: taken))
        XCTAssertFalse(taken.contains { WidgetGrid.overlaps($0, near) })
        XCTAssertEqual(WidgetGrid.aligned(near), CGRect(x: 175, y: 697, width: 170, height: 170))
        XCTAssertEqual(g.snap(near), near, "a free spot is a snapped spot")
        let full = [visible]
        XCTAssertNil(g.nearestFree(.small, near: near, occupied: full))
    }

    // MARK: Placement

    func testPlacementSnapsFallsBackAndResolvesOverlaps() {
        let records = [
            WidgetRecord(instance: "A", app: "x", type: "clock", size: .medium, x: 0, y: 0),
            WidgetRecord(instance: "B", app: "x", type: "clock", size: .small, x: 0.05, y: 0.01),
            WidgetRecord(instance: "C", app: "x", type: "clock", size: .small, screen: .name("Gone"), x: 0.99, y: 0.99),
        ]
        let placed = WidgetPlacement.resolve(records, screens: [main], grid: .default)
        XCTAssertEqual(placed["A"]?.frame, CGRect(x: 0, y: 705, width: 356, height: 170))
        XCTAssertEqual(placed["A"]?.moved, false)
        let b = placed["B"]?.frame ?? .null
        XCTAssertFalse(WidgetGrid.overlaps(b, placed["A"]?.frame ?? .null), "moved off A")
        XCTAssertEqual(placed["B"]?.moved, true)
        XCTAssertEqual(placed["C"]?.screenMissing, true)
        XCTAssertEqual(placed["C"]?.frame, CGRect(x: 1270, y: 0, width: 170, height: 170), "pulled inside the main display")
    }

    // MARK: Records saved on the older cell grid

    func testOldColRowRecordsConvertOnLoad() throws {
        let json = #"""
        {"widgets": {"cell": 170, "gap": 16, "margin": 24,
                     "instances": [{"instance": "A", "app": "x", "type": "clock", "size": "small", "col": 1, "row": 0},
                                   {"instance": "N", "app": "x", "type": "clock", "x": 0.5, "y": 0.25}]},
         "loadouts": [{"name": "Desk", "layout": "", "slots": [],
                       "hud": {"widgets": [{"instance": "L", "app": "x", "type": "clock", "col": 0, "row": 1}]}}]}
        """#
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.widgets?.instances.first?.legacyCell, WidgetRecord.LegacyCell(col: 1, row: 0))
        let config = WidgetMigration.migrate(decoded, screens: [main])
        let w = try XCTUnwrap(config.widgets)
        XCTAssertNil(w.instances[0].legacyCell)
        // The old cell (1, 0) sat at x 210, 24 pt under the top: 210 is a line; the bottom edge
        // (194 pt down) is nearer line 12 than the top is to line 1.
        let a = grid.frame(w.instances[0].position, .small)
        XCTAssertEqual(WidgetGrid.aligned(grid.snap(a)), CGRect(x: 210, y: 681, width: 170, height: 170))
        XCTAssertEqual(w.instances[1].position, Position(x: 0.5, y: 0.25), "new records are left alone")
        let l = try XCTUnwrap(config.loadouts?.first?.hud?.widgets?.first)
        XCTAssertNil(l.legacyCell, "loadouts convert too")
        XCTAssertEqual(grid.snap(grid.frame(l.position, .small)).minX, 25)

        let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        for gone in [#""col""#, #""row""#, #""cell""#, #""gap""#, #""margin""#] {
            XCTAssertFalse(text.contains(gone), "\(gone) is no longer written")
        }
        let again = try JSONDecoder().decode(Config.self, from: Data(text.utf8))
        XCTAssertEqual(again.widgets, w)
        XCTAssertEqual(WidgetMigration.migrate(again, screens: [main]), again, "nothing left to convert")
    }

    func testConversionResolvesCollisionsOnACoarseGrid() throws {
        // On 24 × 12 the small widget at old cell (0, 1) snaps down and the large one at (0, 2)
        // snaps up: converted one by one they would be saved overlapping.
        let json = #"""
        {"grid": {"cols": 24, "rows": 12},
         "widgets": {"instances": [{"instance": "A", "app": "x", "type": "clock", "size": "small", "col": 0, "row": 1},
                                   {"instance": "B", "app": "x", "type": "clock", "size": "large", "col": 0, "row": 2}]}}
        """#
        let config = WidgetMigration.migrate(try JSONDecoder().decode(Config.self, from: Data(json.utf8)), screens: [main])
        let records = try XCTUnwrap(config.widgets?.instances)
        let g = WidgetGrid(visible: visible, grid: GridSize(cols: 24, rows: 12))
        let a = g.snap(g.frame(records[0].position, .small)), b = g.snap(g.frame(records[1].position, .large))
        XCTAssertFalse(WidgetGrid.overlaps(a, b), "\(a) \(b)")
        XCTAssertEqual(WidgetPlacement.resolve(records, screens: [main], grid: GridSize(cols: 24, rows: 12))["B"]?.moved, false,
                       "saved where it is shown")
    }

    func testARecordWhoseDisplayIsMissingWaitsForIt() throws {
        let json = #"""
        {"widgets": {"cell": 150, "instances": [{"instance": "A", "app": "x", "type": "clock", "col": 1, "row": 0,
                                                 "screen": {"name": "Gone"}}]},
         "loadouts": [{"name": "Desk", "layout": "", "slots": [],
                       "hud": {"widgets": [{"instance": "L", "app": "x", "type": "clock", "col": 2, "row": 0}]}}]}
        """#
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let config = WidgetMigration.migrate(decoded, screens: [main])
        let a = try XCTUnwrap(config.widgets?.instances.first)
        XCTAssertEqual(a.legacyCell, WidgetRecord.LegacyCell(col: 1, row: 0), "not converted on another display's measures")
        XCTAssertNil(config.loadouts?.first?.hud?.widgets?.first?.legacyCell)
        // Meanwhile it is shown by its cell on the main display, and the old measures are kept.
        let placed = WidgetPlacement.resolve([a], screens: [main], grid: .default, legacy: try XCTUnwrap(config.widgets?.legacyGrid))
        XCTAssertEqual(placed["A"]?.screenMissing, true)
        let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertTrue(text.contains(#""cell":150"#), text)
        // Back: it converts by its own display.
        let gone = WidgetScreen(descriptor: ScreenDescriptor(name: "Gone", isMain: false, isBuiltin: false), ref: .name("Gone"),
                                visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055), frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let later = WidgetMigration.migrate(config, screens: [main, gone])
        XCTAssertNil(later.widgets?.instances.first?.legacyCell)
        XCTAssertNil(later.widgets?.legacyGrid)
    }

    func testOldMeasuresAreKeptWhileALoadoutStillHasACell() throws {
        // Every placed widget is converted; a loadout's widget waits for its display.
        let json = #"""
        {"widgets": {"cell": 150, "instances": [{"instance": "A", "app": "x", "type": "clock", "col": 1, "row": 0}]},
         "loadouts": [{"name": "Desk", "layout": "", "slots": [],
                       "hud": {"widgets": [{"instance": "L", "app": "x", "type": "clock", "col": 2, "row": 0,
                                            "screen": {"name": "Gone"}}]}}]}
        """#
        let config = WidgetMigration.migrate(try JSONDecoder().decode(Config.self, from: Data(json.utf8)), screens: [main])
        XCTAssertNil(config.widgets?.instances.first?.legacyCell)
        XCTAssertNotNil(config.loadouts?.first?.hud?.widgets?.first?.legacyCell)
        let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertTrue(text.contains(#""cell":150"#), "the loadout's cell still needs them: \(text)")
        let again = try JSONDecoder().decode(Config.self, from: Data(text.utf8))
        XCTAssertEqual(again.widgets?.legacyGrid?.cell, 150)
    }

    func testAnUnconvertedRecordKeepsItsCellWhenWritten() throws {
        let record = try JSONDecoder().decode(WidgetRecord.self, from: Data(#"{"instance": "A", "app": "x", "type": "t", "col": 2, "row": 3}"#.utf8))
        let again = try JSONDecoder().decode(WidgetRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(again.legacyCell, WidgetRecord.LegacyCell(col: 2, row: 3), "nothing is lost before the conversion")
    }

    func testRecordsReadLeniently() throws {
        let json = #"{"widgets": {"instances": [{"instance": "A", "app": "x", "type": "clock", "size": "huge", "x": 2, "y": "top", "#
            + #""layer": "float", "screen": {"builtin": true}, "settings": {"zone": "UTC", "seconds": true}}, "#
            + #"{"instance": "B", "app": "x"}, 7, {"instance": "C", "app": "x", "type": "clock"}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let w = try XCTUnwrap(config.widgets)
        XCTAssertEqual(w.instances.map(\.instance), ["A", "C"], "entries that do not decode are skipped")
        XCTAssertEqual(w.instances.first?.size, .small, "an unknown size reads as small")
        XCTAssertEqual(w.instances.first?.x, 1, "kept inside 0...1")
        XCTAssertEqual(w.instances.first?.y, 0, "a bad value reads as 0")
        XCTAssertEqual(w.instances.first?.layer, .float)
        XCTAssertEqual(w.instances.first?.screen, .builtin)
        XCTAssertEqual(w.instances.first?.settings, ["zone": .string("UTC"), "seconds": .bool(true)])
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.widgets, w)
        let hud = try JSONDecoder().decode(HUDLoadout.self, from: Data(#"{"widgets": [{"instance": "A", "app": "x", "type": "t"}, "bad"]}"#.utf8))
        XCTAssertEqual(hud.widgets?.map(\.instance), ["A"])
    }

    // MARK: The layout editor's drag

    func testEditorDragSnapsLikeEveryOtherMove() {
        let g = grid
        let start = CGRect(x: 0, y: 705, width: 170, height: 170)
        // Dragged 92 pt right: the left edge is 2 from line 90, the right edge (262) 7 from line 255.
        XCTAssertEqual(g.dragged(start, by: CGSize(width: 92, height: -40)).minX, 90)
        // 97 pt: the left edge is 7 from line 90, the right edge (267) 3 from line 270.
        XCTAssertEqual(g.dragged(start, by: CGSize(width: 97, height: -40)).minX, 100)
        XCTAssertEqual(g.dragged(start, by: CGSize(width: 97, height: -40)), g.snap(start.offsetBy(dx: 97, dy: -40)))
        XCTAssertEqual(g.dragged(start, by: CGSize(width: 5000, height: 0)).maxX, 1440, "dragged off: flush with the edge")
    }
}
