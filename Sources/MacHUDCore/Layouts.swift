import AppKit
import HUDKit

/// A rectangle expressed as fractions (0...1) of the screen's visible area.
/// `x`/`y` are measured from the TOP-LEFT corner of the screen.
struct FractionRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    /// Convert to Cocoa screen coordinates (bottom-left origin) inside `visible`.
    func cocoaRect(in visible: CGRect) -> CGRect {
        let width = w * visible.width
        let height = h * visible.height
        let originX = visible.minX + x * visible.width
        let originY = visible.maxY - y * visible.height - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

/// One drop target. The window is resized to `frame`; the cursor must be inside
/// `hit` (defaults to `frame`) for the region to be selected while dragging.
struct Region: Codable, Equatable {
    /// Stable identity used by loadouts to reference this region. Assigned on load if missing.
    var id: String?
    var name: String?
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var hit: FractionRect?

    var frame: FractionRect { FractionRect(x: x, y: y, w: w, h: h) }
    var hitRect: FractionRect { hit ?? frame }
}

struct Layout: Codable, Equatable {
    var name: String
    var regions: [Region]
    /// true: kept for its loadout only; not offered as the snap layout or in the menus.
    var hidden: Bool? = nil

    func region(id: String) -> Region? { regions.first { $0.id == id } }
    func regionIndex(id: String) -> Int? { regions.firstIndex { $0.id == id } }
}

// MARK: - Loadouts

/// Which browser hosts a `web` occupant.
enum WebHost: String, Codable, Equatable {
    /// Chromium "--app=URL" window: chromeless, real logins/extensions, moved like any window.
    case chromeApp
    /// A new Arc browser window, asked for by Apple events (Arc has no usable app mode).
    case arc
    /// A new Safari window, asked for by Apple events.
    case safari
    /// A WKWebView window owned by MacHUD.
    case builtin
}

/// What lives in a region when a loadout is applied.
enum Occupant: Codable, Equatable {
    /// A third-party app window. `titleMatch` is a case-insensitive regular expression
    /// used to pick one window when the app has several; nil means "any / main window".
    case app(bundleID: String, titleMatch: String?)
    /// A web page in its own window.
    case web(url: String, host: WebHost)
    /// One of MacHUD's own panels (dock, dev servers, ...), by panel id.
    case panel(id: String)

    private enum CodingKeys: String, CodingKey { case kind, bundleID, titleMatch, url, host, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "app":
            self = .app(bundleID: try c.decode(String.self, forKey: .bundleID),
                        titleMatch: try c.decodeIfPresent(String.self, forKey: .titleMatch))
        case "web":
            self = .web(url: try c.decode(String.self, forKey: .url),
                        host: try c.decodeIfPresent(WebHost.self, forKey: .host) ?? .chromeApp)
        case "panel":
            self = .panel(id: try c.decode(String.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown occupant kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let bundleID, let titleMatch):
            try c.encode("app", forKey: .kind)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encodeIfPresent(titleMatch, forKey: .titleMatch)
        case .web(let url, let host):
            try c.encode("web", forKey: .kind)
            try c.encode(url, forKey: .url)
            try c.encode(host, forKey: .host)
        case .panel(let id):
            try c.encode("panel", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }

    /// Short human label for menus and cards.
    var label: String {
        switch self {
        case .app(let bundleID, let title):
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
            return title.map { "\(name) · \($0)" } ?? name
        case .web(let url, _):
            return URL(string: url)?.host ?? url
        case .panel(let id):
            return id
        }
    }
}

/// How a slot's window is placed.
enum SlotMode: String, Codable, Equatable {
    /// In its region (the default).
    case placed
    /// Parked off-screen at `edge`, revealed from the orb. The region is its rest frame.
    case parked
}

/// One region's assignment inside a loadout.
struct Slot: Codable, Equatable {
    var regionID: String
    var occupant: Occupant
    /// 1-based desktop number on the slot's screen. Nil means "whichever
    /// desktop is showing"; a number makes apply switch to it first.
    var space: Int? = nil
    /// Stacking order among overlapping slots: higher is raised later, so it ends up
    /// in front. Absent means 0.
    var z: Int? = nil
    /// Absent means `.placed`.
    var mode: SlotMode? = nil
    /// Screen edge a parked slot hides behind (default left).
    var edge: HUDEdge? = nil
    /// Points of a parked window left showing (default 0).
    var peek: Double? = nil

    var stackOrder: Int { z ?? 0 }
    var isParked: Bool { mode == .parked }
    var parkEdge: HUDEdge { edge ?? .left }
    var parkPeek: CGFloat { CGFloat(max(peek ?? 0, 0)) }
}

/// What apply does with an assignment whose display is not attached.
enum ScreenMissingPolicy: String, Codable, Equatable {
    /// Put it on the main display, on a desktop nothing else is using.
    case desktop
    /// Leave it out and report `screenMissing`.
    case skip
}

/// A layout plus what goes where. Applying it launches/finds each occupant's
/// window and places it in its region.
struct Loadout: Codable, Equatable {
    var name: String
    /// Name of the layout whose regions the slots refer to.
    var layout: String
    var slots: [Slot]
    /// Optional global hotkey that applies this loadout directly.
    var hotkey: HotKey?
    /// Per-display assignments. `layout` + `slots` above stay the one-screen
    /// form, applied to the screen under the mouse.
    var screens: [ScreenAssignment]? = nil
    /// What to do with an assignment whose display is missing (default `desktop`).
    var whenScreenMissing: ScreenMissingPolicy? = nil
    /// The MacHUD side: where the tool dock sits and each sibling app's panels (see
    /// `HUDLoadout`). A loadout may hold only this (empty `layout` and `slots`).
    var hud: HUDLoadout? = nil

    var screenMissingPolicy: ScreenMissingPolicy { whenScreenMissing ?? .desktop }

    func slot(regionID: String) -> Slot? { slots.first { $0.regionID == regionID } }

    /// Every slot in the loadout, one-screen form plus per-display assignments.
    var allSlots: [Slot] { slots + (screens ?? []).flatMap(\.slots) }

    /// Assign (or clear) a region's occupant. Replacing the occupant keeps the slot's
    /// desktop, stacking and parking settings.
    mutating func set(_ occupant: Occupant?, regionID: String) {
        let previous = slots.first { $0.regionID == regionID }
        slots.removeAll { $0.regionID == regionID }
        guard let occupant else { return }
        var slot = previous ?? Slot(regionID: regionID, occupant: occupant)
        slot.occupant = occupant
        slots.append(slot)
    }
}

/// A global hotkey, e.g. {"key": "space", "modifiers": ["control", "option"]}.
/// `key` is a key name: a letter/digit, or one of space, tab, return, escape,
/// f1...f12, up, down, left, right, `, -, =, [, ], \\, ;, ', ",", ., /.
/// A global hotkey (`{"key", "modifiers"}`); see HUDHotKey.
typealias HotKey = HUDHotKey
typealias HotKeyCenter = HUDHotKeyCenter

struct Hotkeys: Codable, Equatable {
    /// Hold to show the radial loadout menu; drag toward a loadout; release to apply.
    var loadoutMenu: HotKey?
    /// Show or hide the tool dock (⌃⌥D).
    var dock: HotKey?
    /// Collapse/expand the menu bar's hidden items. `menuBar.hotkey` wins over it; with
    /// neither set it is ⌃⌥B (see `MenuBarConfig.defaultHotkey`).
    var menuBar: HotKey? = nil
    /// Reveal the desktop widgets; press again or Esc lowers them. Absent means ⌃⌥W; an
    /// empty `key` turns it off.
    var widgets: HotKey? = nil

    static let defaultWidgets = HotKey(key: "w", modifiers: ["control", "option"])

    /// The widget reveal hotkey in effect.
    var widgetsReveal: HotKey? {
        let hk = widgets ?? Self.defaultWidgets
        return hk.key.isEmpty ? nil : hk
    }

    static let defaults = Hotkeys(
        loadoutMenu: HotKey(key: "space", modifiers: ["control", "option"]),
        dock: HotKey(key: "d", modifiers: ["control", "option"]))
}

/// `menuBar` in layouts.json. Every field is optional so older configs (no `menuBar` at
/// all) and hand-written partial ones decode unchanged.
struct MenuBarConfig: Codable, Equatable {
    /// Default false: the separator and expander only appear once this is on.
    var enabled: Bool?
    /// Collapse this long after expanding with the mouse out of the menu bar. 0 = never.
    var autoCollapseSeconds: Double?
    /// Toggle collapse/expand. Absent falls back to `hotkeys.menuBar`, then ⌃⌥B.
    var hotkey: HotKey?
    /// Default true: host the sibling apps' status menus in MacHUD's own ("Apps") and let
    /// them hide their icons (`host.json` says `hostsMenus`). Independent of `enabled`.
    var consumeSiblings: Bool?

    static let defaultAutoCollapse: Double = 10
    static let defaultHotkey = HotKey(key: "b", modifiers: ["control", "option"])

    var isEnabled: Bool { enabled ?? false }
    var consumesSiblings: Bool { consumeSiblings ?? true }
    var autoCollapse: Double { max(0, autoCollapseSeconds ?? Self.defaultAutoCollapse) }

    /// The hotkey in effect: `menuBar.hotkey`, else the `hotkeys.menuBar` of the existing
    /// hotkey block, else ⌃⌥B. An empty `key` turns it off.
    func effectiveHotkey(hotkeys: Hotkeys?) -> HotKey? {
        let hk = hotkey ?? hotkeys?.menuBar ?? Self.defaultHotkey
        return hk.key.isEmpty ? nil : hk
    }
}

/// `toolDock` in layouts.json. Every field is optional; absent means the default.
struct ToolDockConfig: Codable, Equatable {
    /// Default true: the tool dock is MacHUD's main affordance.
    var enabled: Bool?
    /// One of the eight snap positions (default bottom): an edge is a single row or
    /// column centred on it, a corner an L. Replaces the older `edge` + `offset`: a file
    /// with only `edge` reads as that edge's position.
    var position: HUDDockPosition?
    /// Slide off past the edge until the pointer touches it, like the Dock (default false).
    var autoHide: Bool?
    /// Icon side in points (default 44, 24...96).
    var iconSize: Double?
    /// Grow the icon under the pointer a little (default true).
    var magnify: Bool?
    /// Display name the dock is on; absent or not attached means the main display.
    var screen: String?

    static let defaultIconSize: Double = 44
    static let iconSizeRange: ClosedRange<Double> = 24...96

    init(enabled: Bool? = nil, position: HUDDockPosition? = nil, autoHide: Bool? = nil, iconSize: Double? = nil,
         magnify: Bool? = nil, screen: String? = nil) {
        self.enabled = enabled
        self.position = position
        self.autoHide = autoHide
        self.iconSize = iconSize
        self.magnify = magnify
        self.screen = screen
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, position, autoHide, iconSize, magnify, screen
        /// Read (and migrated) but never written.
        case edge, offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        position = (try? c.decodeIfPresent(HUDDockPosition.self, forKey: .position))
            ?? (try? c.decodeIfPresent(HUDEdge.self, forKey: .edge)).flatMap { $0.map(HUDDockPosition.init(edge:)) }
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide)
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize)
        magnify = try c.decodeIfPresent(Bool.self, forKey: .magnify)
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(autoHide, forKey: .autoHide)
        try c.encodeIfPresent(iconSize, forKey: .iconSize)
        try c.encodeIfPresent(magnify, forKey: .magnify)
        try c.encodeIfPresent(screen, forKey: .screen)
    }

    var isEnabled: Bool { enabled ?? true }
    var dockPosition: HUDDockPosition { position ?? .bottom }
    var isAutoHide: Bool { autoHide ?? false }
    var icon: Double { min(max(iconSize ?? Self.defaultIconSize, Self.iconSizeRange.lowerBound), Self.iconSizeRange.upperBound) }
    var isMagnified: Bool { magnify ?? true }
}

/// Which modifier must be held while dragging for snapping to kick in.
enum Trigger: String, Codable, CaseIterable {
    case shift, option, control, command, always

    var title: String {
        switch self {
        case .shift: return "Shift (⇧)"
        case .option: return "Option (⌥)"
        case .control: return "Control (⌃)"
        case .command: return "Command (⌘)"
        case .always: return "Always"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        case .always: return ""
        }
    }

    func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .shift: return flags.contains(.shift)
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .command: return flags.contains(.command)
        case .always: return true
        }
    }
}

/// Snap grid used by the visual editor.
struct GridSize: Codable, Equatable {
    var cols: Int
    var rows: Int
    static let `default` = GridSize(cols: 96, rows: 54)
}

/// Off-by-default behaviour that relies on private system interfaces.
struct Experimental: Codable, Equatable {
    /// Move an existing window to another desktop with SkyLight's private
    /// `CGSMoveWindowsToManagedSpace`, instead of reporting `onOtherSpace`.
    var spacesPrivateAPI: Bool?
}

struct Config: Codable, Equatable {
    /// Points of empty space to leave between regions and screen edges.
    var gap: Double?
    /// Modifier that must be held while dragging (default: shift).
    var trigger: Trigger?
    /// Editor snap grid (default 96 x 54).
    var grid: GridSize?
    var layouts: [Layout]
    var loadouts: [Loadout]?
    var hotkeys: Hotkeys?
    /// Bundle id of the browser used for web occupants. A Chromium gets an app-mode
    /// window; Arc and Safari get an ordinary browser window. Unset means "whatever
    /// handles http on this machine".
    var browser: String?
    var experimental: Experimental?
    /// MacHUD-aware sibling apps: extra search paths and which to keep running.
    var apps: AppsConfig?
    /// Menu bar management (hide status items left of a separator). Off when absent.
    var menuBar: MenuBarConfig? = nil
    /// The Dock-like strip of tool buttons. On when absent.
    var toolDock: ToolDockConfig? = nil
    /// What apply does with windows on desktops that are not showing (default `bring`).
    var spaces: SpacesConfig? = nil
    /// Name of a loadout applied about two seconds after launch, once the sibling apps it
    /// names are reachable (typically one saved with "Save Current HUD as Loadout…").
    var startupLoadout: String? = nil
    /// The app catalog (Settings → Apps): its URL and the install directory.
    var catalog: CatalogConfig? = nil
    /// Desktop widgets: the grid and every placed widget.
    var widgets: WidgetsConfig? = nil

    /// Blank by default: the editor opens on first trigger so you draw your own.
    static let defaults = Config(gap: 0, trigger: .shift, grid: .default, layouts: [], loadouts: [],
                                 hotkeys: .defaults, browser: nil)

    init(gap: Double? = nil, trigger: Trigger? = nil, grid: GridSize? = nil, layouts: [Layout] = [],
         loadouts: [Loadout]? = nil, hotkeys: Hotkeys? = nil, browser: String? = nil,
         experimental: Experimental? = nil, apps: AppsConfig? = nil, menuBar: MenuBarConfig? = nil,
         toolDock: ToolDockConfig? = nil, startupLoadout: String? = nil) {
        self.gap = gap; self.trigger = trigger; self.grid = grid; self.layouts = layouts
        self.loadouts = loadouts; self.hotkeys = hotkeys; self.browser = browser
        self.experimental = experimental; self.apps = apps; self.menuBar = menuBar; self.toolDock = toolDock
        self.startupLoadout = startupLoadout
    }

    /// Every key is optional so a minimal file such as `{"apps": {...}}` is a valid config
    /// instead of silently falling back to the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gap = try c.decodeIfPresent(Double.self, forKey: .gap)
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger)
        grid = try c.decodeIfPresent(GridSize.self, forKey: .grid)
        layouts = try c.decodeIfPresent([Layout].self, forKey: .layouts) ?? []
        loadouts = try c.decodeIfPresent([Loadout].self, forKey: .loadouts)
        hotkeys = try c.decodeIfPresent(Hotkeys.self, forKey: .hotkeys)
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        experimental = try c.decodeIfPresent(Experimental.self, forKey: .experimental)
        apps = try c.decodeIfPresent(AppsConfig.self, forKey: .apps)
        menuBar = try c.decodeIfPresent(MenuBarConfig.self, forKey: .menuBar)
        toolDock = try c.decodeIfPresent(ToolDockConfig.self, forKey: .toolDock)
        spaces = try c.decodeIfPresent(SpacesConfig.self, forKey: .spaces)
        startupLoadout = try c.decodeIfPresent(String.self, forKey: .startupLoadout)
        catalog = try c.decodeIfPresent(CatalogConfig.self, forKey: .catalog)
        widgets = try c.decodeIfPresent(WidgetsConfig.self, forKey: .widgets)
    }
}

/// Owns the config file, the active layout selection and the enabled flag.
final class LayoutStore {
    /// Config directory under the home folder; `state/` (parking) lives inside it.
    static let configSubpath = ".config/machud"
    static let configURL: URL = Env.configURL ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(configSubpath).appendingPathComponent("layouts.json")
    static let configDirectory = configURL.deletingLastPathComponent()

    private(set) var config: Config = .defaults
    private(set) var loadError: String?
    var onChange: (() -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled"); onChange?() }
    }

    private(set) var activeIndex: Int {
        get { UserDefaults.standard.integer(forKey: "activeLayout") }
        set { UserDefaults.standard.set(newValue, forKey: "activeLayout") }
    }

    var layouts: [Layout] { config.layouts }
    var gap: CGFloat { CGFloat(config.gap ?? 0) }
    var trigger: Trigger { config.trigger ?? .shift }
    var grid: GridSize { config.grid ?? .default }
    var loadouts: [Loadout] { config.loadouts ?? [] }
    var hotkeys: Hotkeys { config.hotkeys ?? .defaults }
    var menuBar: MenuBarConfig { config.menuBar ?? MenuBarConfig() }
    var toolDock: ToolDockConfig { config.toolDock ?? ToolDockConfig() }
    var spacesPolicy: SpacesPolicy { config.spaces?.effectivePolicy ?? .bring }

    func layout(named name: String) -> Layout? { layouts.first { $0.name == name } }
    func loadout(named name: String) -> Loadout? { loadouts.first { $0.name == name } }

    /// Insert or replace a loadout by name and persist.
    func upsert(_ loadout: Loadout) {
        var c = config
        var list = c.loadouts ?? []
        if let i = list.firstIndex(where: { $0.name == loadout.name }) { list[i] = loadout } else { list.append(loadout) }
        c.loadouts = list
        save(c)
    }

    var activeLayout: Layout? {
        guard !layouts.isEmpty else { return nil }
        return layouts[min(activeIndex, layouts.count - 1)]
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    init() {
        load()
        watchDirectory()
    }

    func select(index: Int) {
        guard layouts.indices.contains(index) else { return }
        activeIndex = index
        onChange?()
    }

    func cycle() {
        guard !layouts.isEmpty else { return }
        activeIndex = (min(activeIndex, layouts.count - 1) + 1) % layouts.count
        onChange?()
    }

    /// Persist a new config (also applied immediately).
    func save(_ newConfig: Config) {
        config = Self.withRegionIDs(newConfig)
        loadError = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            try encoder.encode(config).write(to: Self.configURL, options: .atomic)
        } catch {
            loadError = "\(error)"
            NSLog("MacHUD: failed to save %@: %@", Self.configURL.path, "\(error)")
        }
        onChange?()
    }

    func setTrigger(_ t: Trigger) {
        var c = config
        c.trigger = t
        save(c)
    }

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.configURL.path) {
            try? fm.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(Config.defaults) {
                try? data.write(to: Self.configURL)
            }
        }
        do {
            let data = try Data(contentsOf: Self.configURL)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            let withIDs = DisplayPinning.migrate(Self.withRegionIDs(decoded), screens: NSScreen.screens.map(\.descriptor))
            config = withIDs
            loadError = nil
            if withIDs != decoded {
                // Regions written by hand get stable ids so loadouts can reference them, and
                // displays named in loadouts get pinned to the physical display.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? encoder.encode(withIDs).write(to: Self.configURL, options: .atomic)
            }
        } catch {
            loadError = "\(error)"
            NSLog("MacHUD: failed to load %@: %@", Self.configURL.path, "\(error)")
        }
        onChange?()
    }

    static func withRegionIDs(_ c: Config) -> Config {
        var c = c
        for li in c.layouts.indices {
            for ri in c.layouts[li].regions.indices where c.layouts[li].regions[ri].id == nil {
                c.layouts[li].regions[ri].id = UUID().uuidString.lowercased()
            }
        }
        return c
    }

    /// Watch the config directory so atomic saves (write a temp file, rename it over)
    /// are seen, and the file itself so in-place writes (`>`, `json.dump`, many scripts)
    /// are too: those change the file without touching the directory.
    private func watchDirectory() {
        let fd = open(Self.configDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchFile()
    }

    /// Re-armed after every reload: an atomic save replaces the inode being watched.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(Self.configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.load()
            self?.watchFile()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
