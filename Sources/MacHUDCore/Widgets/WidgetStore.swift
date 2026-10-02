import AppKit
import HUDKit

/// `"widgets"` in layouts.json: every placed widget. Read leniently: a bad value reads as its
/// default and a widget that does not decode is skipped.
///
/// ```json
/// "widgets": {"instances": [{"instance": "8F0C1E2A", "app": "xyz.machud.widgethud", "type": "clock",
///                            "size": "small", "screen": {"builtin": true}, "x": 0.125, "y": 0.0185,
///                            "layer": "desktop", "settings": {"zone": "Europe/Oslo"}}]}
/// ```
///
/// Widgets sit on the layout grid (`grid` in layouts.json, `WidgetGrid`): a position is the
/// widget's top-left as fractions of its display's visible frame, like a region's, and frames
/// are computed from the display's visible frame.
struct WidgetsConfig: Codable, Equatable {
    /// The older cell grid's measures, read only to convert records that still have `col`/`row`
    /// (`WidgetMigration`), here or in a HUD loadout; the conversion drops them once no such
    /// record is left.
    struct LegacyGrid: Equatable {
        var cell: Double?
        var gap: Double?
        var margin: Double?

        static let standard = LegacyGrid()

        var cellSize: CGFloat { CGFloat(max(40, cell ?? 170)) }
        var gapSize: CGFloat { CGFloat(max(0, gap ?? 16)) }
        var marginSize: CGFloat { CGFloat(max(0, margin ?? 24)) }

        /// Where the older grid put the top-left of cell `at`, in points from the visible
        /// frame's top-left corner.
        func offset(_ at: WidgetRecord.LegacyCell) -> CGPoint {
            let pitch = cellSize + gapSize
            return CGPoint(x: marginSize + CGFloat(at.col) * pitch, y: marginSize + CGFloat(at.row) * pitch)
        }
    }

    var instances: [WidgetRecord]
    var legacyGrid: LegacyGrid?

    init(instances: [WidgetRecord] = []) {
        self.instances = instances
    }

    private enum CodingKeys: String, CodingKey { case instances, cell, gap, margin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instances = (try? c.decodeIfPresent(LossyList<WidgetRecord>.self, forKey: .instances))?.items ?? []
        let legacy = LegacyGrid(cell: try? c.decodeIfPresent(Double.self, forKey: .cell),
                                gap: try? c.decodeIfPresent(Double.self, forKey: .gap),
                                margin: try? c.decodeIfPresent(Double.self, forKey: .margin))
        legacyGrid = legacy == .standard ? nil : legacy
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instances, forKey: .instances)
        guard let legacyGrid else { return }
        try c.encodeIfPresent(legacyGrid.cell, forKey: .cell)
        try c.encodeIfPresent(legacyGrid.gap, forKey: .gap)
        try c.encodeIfPresent(legacyGrid.margin, forKey: .margin)
    }

    func record(_ id: String) -> WidgetRecord? { instances.first { $0.instance == id } }
}

/// A list that skips the entries that do not decode, so one hand-edited bad widget never
/// costs the others (or the whole layouts.json).
struct LossyList<Element: Decodable>: Decodable {
    var items: [Element]

    /// Takes any value without reading it, which moves the container past it.
    private struct Skip: Decodable { init(from decoder: Decoder) {} }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !c.isAtEnd {
            if let item = try? c.decode(Element.self) { items.append(item) } else { _ = try? c.decode(Skip.self) }
        }
        self.items = items
    }
}

/// One placed widget as MacHUD keeps it: which app draws it, where it sits on the layout grid
/// and its own settings. The app gets it as a `HUDWidgetInstance` with a frame.
struct WidgetRecord: Codable, Equatable {
    /// A cell of the older widget grid, kept until `WidgetMigration` converts it.
    struct LegacyCell: Codable, Equatable {
        var col: Int
        var row: Int
    }

    var instance: String
    /// The serving app's bundle id.
    var app: String
    /// The widget type: the id of the app's `kind: widget` panel.
    var type: String
    var size: HUDWidgetSize
    /// The display; nil means the main one.
    var screen: ScreenRef?
    /// The top-left as fractions (0...1) of the display's visible frame from its top-left
    /// corner, as regions measure. Snapped to the layout grid when placed and again when shown.
    var x: Double
    var y: Double
    var layer: HUDWidgetLayer
    var settings: [String: HUDSettingValue]?
    /// Set for a record read with `col`/`row` and no `x`/`y`; `x`/`y` mean nothing until it is converted.
    var legacyCell: LegacyCell?

    init(instance: String, app: String, type: String, size: HUDWidgetSize, screen: ScreenRef? = nil,
         x: Double, y: Double, layer: HUDWidgetLayer = .desktop, settings: [String: HUDSettingValue]? = nil) {
        self.instance = instance
        self.app = app
        self.type = type
        self.size = size
        self.screen = screen
        self.x = x
        self.y = y
        self.layer = layer
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case instance, app, type, size, screen, x, y, col, row, layer, settings }

    /// Lenient past the identity keys: a hand-edited bad value reads as its default rather
    /// than failing the whole layouts.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decode(String.self, forKey: .instance)
        app = try c.decode(String.self, forKey: .app)
        type = try c.decode(String.self, forKey: .type)
        size = (try? c.decodeIfPresent(HUDWidgetSize.self, forKey: .size)) ?? .small
        screen = try? c.decodeIfPresent(ScreenRef.self, forKey: .screen)
        let fx = try? c.decodeIfPresent(Double.self, forKey: .x), fy = try? c.decodeIfPresent(Double.self, forKey: .y)
        x = min(max(fx ?? 0, 0), 1)
        y = min(max(fy ?? 0, 0), 1)
        let col = try? c.decodeIfPresent(Int.self, forKey: .col), row = try? c.decodeIfPresent(Int.self, forKey: .row)
        if c.contains(.col) || c.contains(.row), !c.contains(.x), !c.contains(.y) {
            legacyCell = LegacyCell(col: max(0, col ?? 0), row: max(0, row ?? 0))
        }
        layer = (try? c.decodeIfPresent(HUDWidgetLayer.self, forKey: .layer)) ?? .desktop
        settings = try? c.decodeIfPresent([String: HUDSettingValue].self, forKey: .settings)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instance, forKey: .instance)
        try c.encode(app, forKey: .app)
        try c.encode(type, forKey: .type)
        try c.encode(size, forKey: .size)
        try c.encodeIfPresent(screen, forKey: .screen)
        if let legacyCell {
            // Not converted yet (no display to convert on): keep what it said.
            try c.encode(legacyCell.col, forKey: .col)
            try c.encode(legacyCell.row, forKey: .row)
        } else {
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        }
        try c.encode(layer, forKey: .layer)
        try c.encodeIfPresent(settings, forKey: .settings)
    }

    var position: WidgetGrid.Position {
        get { WidgetGrid.Position(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    /// Its frame on `grid` as stored, before snapping; a record still in cells is placed by
    /// the older grid's measures.
    func frame(on grid: WidgetGrid, legacy: WidgetsConfig.LegacyGrid = .standard) -> CGRect {
        guard let legacyCell else { return grid.frame(position, size) }
        let offset = legacy.offset(legacyCell)
        let s = size.points()
        return CGRect(x: grid.visible.minX + offset.x, y: grid.visible.maxY - offset.y - s.height, width: s.width, height: s.height)
    }

    /// The same widget at the same place: same app, type and display, and the same position.
    func samePlace(as other: WidgetRecord) -> Bool {
        app == other.app && type == other.type && screen == other.screen && legacyCell == other.legacyCell
            && abs(x - other.x) < 1e-4 && abs(y - other.y) < 1e-4
    }

    var settingsJSON: [String: Any] { (settings ?? [:]).mapValues(\.jsonValue) }
}

/// A display widgets can sit on, reduced to what placement needs (tests make their own).
struct WidgetScreen: Equatable {
    var descriptor: ScreenDescriptor
    /// How a record pins itself to this display.
    var ref: ScreenRef
    /// Cocoa coordinates, menu bar and Dock excluded.
    var visible: CGRect
    var frame: CGRect

    var name: String { descriptor.name }

    static func attached() -> [WidgetScreen] {
        NSScreen.screens.map { WidgetScreen(descriptor: $0.descriptor, ref: $0.ref, visible: $0.visibleFrame, frame: $0.frame) }
    }
}
