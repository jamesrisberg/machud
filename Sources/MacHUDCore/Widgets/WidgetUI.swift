import AppKit
import HUDKit
import SwiftUI

/// What the user sees of the widget layer in MacHUD itself: the gallery and the layout grid
/// while editing, an instance's settings, and the reveal hotkey (⌃⌥W) with Esc to lower or
/// leave edit mode.
@MainActor
final class WidgetUI {
    let layer: WidgetLayer
    let gallery = WidgetGalleryModel()
    private var galleryWindow: NSWindow?
    private var overlays: [NSWindow] = []
    private var settingsWindow: NSWindow?
    private var settingsModel: WidgetSettingsModel?
    private var revealHotkeyID: UInt32?
    private var revealHotkey: HotKey?
    private var escapeID: UInt32?
    /// Off in an isolated instance (`MACHUD_NO_HOTKEYS`).
    var hotkeysEnabled = !Env.noHotkeys
    /// The active layout's regions on a display (Cocoa coordinates), drawn faintly under the
    /// grid while editing so widgets can be lined up with them.
    var regions: (WidgetScreen) -> [CGRect] = { _ in [] }

    init(layer: WidgetLayer) {
        self.layer = layer
        gallery.add = { [weak self] app, type, size in self?.add(app: app, type: type, size: size) }
        gallery.done = { [weak layer] in layer?.setEditing(false) }
        layer.configure = { [weak self] record in self?.showSettings(record.instance) }
    }

    /// The modes or the instances changed.
    func refresh() {
        gallery.reload(layer)
        if layer.editing { showEditing() } else { hideEditing() }
        settingsModel?.reload()
        updateEscape()
    }

    // MARK: - Hotkeys

    /// Registers the reveal hotkey (nil or an empty key turns it off).
    func registerHotkey(_ hotkey: HotKey?) {
        guard hotkeysEnabled, hotkey != revealHotkey else { return }
        if let id = revealHotkeyID { HotKeyCenter.shared.unregister(id) }
        revealHotkeyID = nil
        revealHotkey = hotkey
        guard let hotkey else { return }
        revealHotkeyID = HotKeyCenter.shared.register(hotkey, onPress: { [weak self] in
            MainActor.assumeIsolated { self?.layer.setRevealed(!(self?.layer.revealed ?? true)) }
        })
    }

    /// Esc lowers revealed widgets and leaves edit mode; it is taken only while one is on.
    private func updateEscape() {
        let wanted = hotkeysEnabled && (layer.revealed || layer.editing)
        if wanted, escapeID == nil {
            escapeID = HotKeyCenter.shared.register(HotKey(key: "escape", modifiers: []), onPress: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.layer.editing { self.layer.setEditing(false) }
                    self.layer.setRevealed(false)
                }
            })
        } else if !wanted, let id = escapeID {
            HotKeyCenter.shared.unregister(id)
            escapeID = nil
        }
    }

    // MARK: - Adding

    private func add(app: String, type: String, size: HUDWidgetSize) {
        layer.add(app: app, type: type, size: size) { [weak self] result in
            switch result {
            case .success(let (_, note)): self?.gallery.message = note
            case .failure(let error):
                self?.gallery.message = error.description
                if self?.galleryWindow?.isVisible != true { Toast.show("Could not add the widget", detail: error.description) }
            }
        }
    }

    /// The menu's commands.
    func perform(_ command: WidgetMenuModel.Command) {
        do {
            switch command {
            case .reveal: layer.setRevealed(!layer.revealed)
            case .edit: layer.setEditing(!layer.editing)
            case .add(let app, let type, let size): add(app: app, type: type, size: size)
            case .remove(let id): try layer.remove(id)
            case .layer(let id, let l): try layer.setLayer(id, l)
            case .settings(let id): showSettings(id)
            }
        } catch {
            Toast.show("Widgets", detail: "\(error)")
        }
    }

    // MARK: - Edit mode

    private func showEditing() {
        let window = galleryWindow ?? makeGallery()
        galleryWindow = window
        if !window.isVisible, let screen = NSScreen.main {
            let size = window.frame.size
            window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24))
        }
        window.orderFrontRegardless()
        let screens = layer.screens()
        while overlays.count < screens.count { overlays.append(makeOverlay()) }
        for (i, overlay) in overlays.enumerated() {
            guard screens.indices.contains(i) else { overlay.orderOut(nil); continue }
            let screen = screens[i]
            overlay.setFrame(screen.frame, display: false)
            if let view = overlay.contentView as? WidgetGridView {
                let local = { (r: CGRect) in r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
                view.show(visible: local(screen.visible), grid: layer.grid(), regions: regions(screen).map(local))
            }
            overlay.orderFrontRegardless()
        }
    }

    private func hideEditing() {
        galleryWindow?.orderOut(nil)
        gallery.message = nil
        for overlay in overlays { overlay.orderOut(nil) }
    }

    private func makeGallery() -> NSWindow {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 380), keyable: false, level: .floating)
        // Above the widgets, which float while editing.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        w.isMovableByWindowBackground = true
        w.identifier = NSUserInterfaceItemIdentifier("machud.widgets.gallery")
        let glass = HUDGlassView(frame: w.contentView?.bounds ?? .zero, style: .panel)
        glass.autoresizingMask = [.width, .height]
        let host = FirstMouseHostingView(rootView: WidgetGalleryView(model: gallery))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        w.contentView = glass
        return w
    }

    private func makeOverlay() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // Over app windows, under the widgets being edited.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("machud.widgets.grid")
        w.contentView = WidgetGridView()
        return w
    }

    // MARK: - Instance settings

    /// The instance's settings, from its type's schema, in a window of their own.
    func showSettings(_ id: String) {
        guard let record = layer.record(id), let type = layer.type(app: record.app, type: record.type) else { return }
        let model = WidgetSettingsModel(layer: layer, instance: id, title: "\(type.title) Settings", schema: layer.schema(type))
        settingsModel = model
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.title = model.title
        let glass = HUDGlassView(frame: window.contentView?.bounds ?? .zero, style: .plain)
        glass.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: WidgetSettingsView(model: model))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        window.contentView = glass
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 360),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        w.identifier = NSUserInterfaceItemIdentifier("machud.widgets.settings")
        w.center()
        return w
    }
}

/// Clicks reach the gallery's buttons without first activating MacHUD.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The layout grid on one display while editing widgets, drawn as the layout editor draws it,
/// with the active layout's regions faintly under it.
final class WidgetGridView: NSView {
    private(set) var visible: CGRect = .zero
    private(set) var grid: GridSize = .default
    private(set) var regions: [CGRect] = []

    func show(visible: CGRect, grid: GridSize, regions: [CGRect]) {
        guard visible != self.visible || grid != self.grid || regions != self.regions else { return }
        self.visible = visible
        self.grid = grid
        self.regions = regions
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        GridDrawing.backdrop(bounds, visible: visible)
        GridDrawing.lines(grid, in: visible)
        for r in regions { GridDrawing.faintRegion(r) }
    }
}

// MARK: - Gallery

/// Every widget type grouped by app, with an Add button per size.
@MainActor
final class WidgetGalleryModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var app: String
        var type: String
        var title: String
        var symbol: String
        var sizes: [HUDWidgetSize]
        var canAdd: Bool
        var placed: Int
        var id: String { "\(app)/\(type)" }
    }

    struct Group: Identifiable, Equatable {
        var app: String
        var name: String
        var rows: [Row]
        var id: String { app }
    }

    @Published var groups: [Group] = []
    @Published var message: String?
    var add: (String, String, HUDWidgetSize) -> Void = { _, _, _ in }
    var done: () -> Void = {}

    func reload(_ layer: WidgetLayer) {
        let records = layer.records
        var out: [Group] = []
        for t in layer.types() {
            let placed = records.filter { $0.app == t.app.id && $0.type == t.id }.count
            let row = Row(app: t.app.id, type: t.id, title: t.title, symbol: t.symbol, sizes: t.spec.sizes,
                          canAdd: t.spec.multiple || placed == 0, placed: placed)
            if let i = out.firstIndex(where: { $0.app == t.app.id }) { out[i].rows.append(row) }
            else { out.append(Group(app: t.app.id, name: t.app.name, rows: [row])) }
        }
        if out != groups { groups = out }
    }
}

struct WidgetGalleryView: View {
    @ObservedObject var model: WidgetGalleryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Widgets").font(.headline)
                Spacer()
                Text("Drag widgets to move them · Esc").font(.caption).foregroundStyle(.secondary)
                Button("Done") { model.done() }.keyboardShortcut(.defaultAction)
            }
            if model.groups.isEmpty {
                Spacer()
                Text("No app serves widgets yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.name).font(.subheadline).foregroundStyle(.secondary)
                                ForEach(group.rows) { row in rowView(row) }
                            }
                        }
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16)
        .preferredColorScheme(.dark)
    }

    private func rowView(_ row: WidgetGalleryModel.Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                if row.placed > 0 { Text("\(row.placed) placed").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            ForEach(row.sizes, id: \.self) { size in
                Button { model.add(row.app, row.type, size) } label: {
                    HStack(spacing: 4) {
                        WidgetSizeGlyph(size: size)
                        Text(WidgetMenuModel.title(size))
                    }
                }
                .disabled(!row.canAdd)
                .help("Add a \(WidgetMenuModel.title(size).lowercased()) \(row.title)")
            }
        }
    }
}

/// A tiny picture of a size's cells.
struct WidgetSizeGlyph: View {
    let size: HUDWidgetSize

    var body: some View {
        let cells = size.cells
        let unit: CGFloat = 4
        RoundedRectangle(cornerRadius: 1.5)
            .stroke(lineWidth: 1)
            .frame(width: CGFloat(cells.columns) * unit + 2, height: CGFloat(cells.rows) * unit + 2)
    }
}

// MARK: - Instance settings

/// One instance's settings form: its type's schema, its own values.
@MainActor
final class WidgetSettingsModel: ObservableObject {
    let layer: WidgetLayer
    let instance: String
    let title: String
    let schema: HUDSettingsSchema?
    @Published private(set) var form = SettingsForm(sections: [])
    @Published var lastError: String?

    init(layer: WidgetLayer, instance: String, title: String, schema: HUDSettingsSchema?) {
        self.layer = layer
        self.instance = instance
        self.title = title
        self.schema = schema
        reload()
    }

    func reload() {
        let values = layer.record(instance)?.settingsJSON ?? [:]
        form = SettingsForm.build(schema: schema, values: values)
    }

    func set(_ row: SettingsForm.Row, _ value: HUDSettingValue) {
        guard let wire = SettingsForm.wireValue(value, for: row) else {
            lastError = "\(row.title): not a valid value"
            return
        }
        do {
            try layer.setSettings(instance, [row.key: .string(wire)]) { [weak self] failure in
                self?.lastError = failure?.description
                self?.reload()
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        reload()
    }
}

struct WidgetSettingsView: View {
    @ObservedObject var model: WidgetSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.form.sections.isEmpty {
                Spacer()
                Text("This widget has no settings.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                Form {
                    ForEach(model.form.sections) { section in
                        Section(section.title ?? model.title) {
                            ForEach(section.rows) { row in
                                SettingsRowView(row: row, editable: true) { model.set(row, $0) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            if let error = model.lastError { Text(error).foregroundStyle(.red).font(.callout).lineLimit(2) }
        }
        .padding(.top, 28)
        .padding([.horizontal, .bottom], 12)
    }
}
