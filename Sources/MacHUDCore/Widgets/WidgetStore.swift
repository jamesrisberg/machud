import AppKit
import HUDKit

/// `"widgets"` in layouts.json: the grid desktop widgets snap to and every placed widget. Read
/// leniently: a bad value reads as its default and a widget that does not decode is skipped.
///
/// ```json
/// "widgets": {"cell": 170, "gap": 16, "margin": 24,
///             "instances": [{"instance": "8F0C1E2A", "app": "xyz.machud.widgethud", "type": "clock",
///                            "size": "small", "screen": {"builtin": true}, "col": 0, "row": 0,
///                            "layer": "desktop", "settings": {"zone": "Europe/Oslo"}}]}
/// ```
///
/// Positions are grid cells per display, so they survive resolution changes; frames are
/// computed from the display's visible frame (`WidgetGrid`).
struct WidgetsConfig: Codable, Equatable {
    /// Cell side in points (default 170).
    var cell: Double?
    /// Space between cells (default 16).
    var gap: Double?
    /// Space between the grid and the edges of the display's visible frame (default 24).
    var margin: Double?
    var instances: [WidgetRecord]

    static let defaultCell: Double = 170
    static let defaultGap: Double = 16
    static let defaultMargin: Double = 24

    init(cell: Double? = nil, gap: Double? = nil, margin: Double? = nil, instances: [WidgetRecord] = []) {
        self.cell = cell
        self.gap = gap
        self.margin = margin
        self.instances = instances
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cell = try? c.decodeIfPresent(Double.self, forKey: .cell)
        gap = try? c.decodeIfPresent(Double.self, forKey: .gap)
        margin = try? c.decodeIfPresent(Double.self, forKey: .margin)
        instances = (try? c.decodeIfPresent(LossyList<WidgetRecord>.self, forKey: .instances))?.items ?? []
    }

    var cellSize: CGFloat { CGFloat(max(40, cell ?? Self.defaultCell)) }
    var gapSize: CGFloat { CGFloat(max(0, gap ?? Self.defaultGap)) }
    var marginSize: CGFloat { CGFloat(max(0, margin ?? Self.defaultMargin)) }

    func grid(on visible: CGRect) -> WidgetGrid {
        WidgetGrid(visible: visible, cell: cellSize, gap: gapSize, margin: marginSize)
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

/// One placed widget as MacHUD keeps it: which app draws it, where it sits on the grid and
/// its own settings. The app gets it as a `HUDWidgetInstance` with a frame.
struct WidgetRecord: Codable, Equatable {
    var instance: String
    /// The serving app's bundle id.
    var app: String
    /// The widget type: the id of the app's `kind: widget` panel.
    var type: String
    var size: HUDWidgetSize
    /// The display; nil means the main one.
    var screen: ScreenRef?
    var col: Int
    var row: Int
    var layer: HUDWidgetLayer
    var settings: [String: HUDSettingValue]?

    init(instance: String, app: String, type: String, size: HUDWidgetSize, screen: ScreenRef? = nil,
         col: Int, row: Int, layer: HUDWidgetLayer = .desktop, settings: [String: HUDSettingValue]? = nil) {
        self.instance = instance
        self.app = app
        self.type = type
        self.size = size
        self.screen = screen
        self.col = col
        self.row = row
        self.layer = layer
        self.settings = settings
    }

    /// Lenient past the identity keys: a hand-edited bad value reads as its default rather
    /// than failing the whole layouts.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decode(String.self, forKey: .instance)
        app = try c.decode(String.self, forKey: .app)
        type = try c.decode(String.self, forKey: .type)
        size = (try? c.decodeIfPresent(HUDWidgetSize.self, forKey: .size)) ?? .small
        screen = try? c.decodeIfPresent(ScreenRef.self, forKey: .screen)
        col = max(0, (try? c.decodeIfPresent(Int.self, forKey: .col)) ?? 0)
        row = max(0, (try? c.decodeIfPresent(Int.self, forKey: .row)) ?? 0)
        layer = (try? c.decodeIfPresent(HUDWidgetLayer.self, forKey: .layer)) ?? .desktop
        settings = try? c.decodeIfPresent([String: HUDSettingValue].self, forKey: .settings)
    }

    var cell: WidgetGrid.Cell {
        get { WidgetGrid.Cell(col: col, row: row) }
        set { col = newValue.col; row = newValue.row }
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

    @MainActor
    static func attached() -> [WidgetScreen] {
        NSScreen.screens.map { WidgetScreen(descriptor: $0.descriptor, ref: $0.ref, visible: $0.visibleFrame, frame: $0.frame) }
    }
}
