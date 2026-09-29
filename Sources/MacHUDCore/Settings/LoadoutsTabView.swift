import AppKit
import HUDKit
import SwiftUI

/// The Loadouts tab: the list on the left, the selected loadout on the right.
struct LoadoutsTabView: View {
    @ObservedObject var model: LoadoutsTabModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            sidebar.frame(width: 224)
            Divider().opacity(0.4)
            if let item = model.selected {
                LoadoutDetailView(model: model, item: item)
            } else {
                empty
            }
        }
        .padding(8)
        .onAppear { model.reload() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loadouts").font(.headline)
                Spacer()
                Menu {
                    Button("Capture Current Windows…") { model.capture() }
                    Button("Draw a New Layout…") { model.drawNew() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Capture the windows on screen as a loadout, or draw a layout from scratch")
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.items) { item in
                        LoadoutCardView(item: item, selected: item.id == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(item.id) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.3.group").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No loadouts yet").font(.title3.weight(.semibold))
            Text("Arrange your windows, then capture them; or draw a layout and assign apps to its regions.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            HStack {
                Button("Capture Current Windows…") { model.capture() }.buttonStyle(.borderedProminent)
                Button("Draw a New Layout…") { model.drawNew() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One row of the list: thumbnail, name, what it holds.
struct LoadoutCardView: View {
    let item: LoadoutsTabModel.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            LoadoutSketchView(sketch: item.sketch, desktop: item.sketch.desktops.first ?? nil, style: .thumbnail)
                .frame(width: 72, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if item.isStartup {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                            .help("Applied when MacHUD starts")
                    }
                    if item.isActive {
                        Circle().fill(Color.green).frame(width: 6, height: 6).help("Applied last")
                    }
                }
                Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.26) : Color.white.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// The selected loadout: header, actions, the large preview, its desktops and HUD part.
struct LoadoutDetailView: View {
    @ObservedObject var model: LoadoutsTabModel
    let item: LoadoutsTabModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 8) {
                Button { model.apply() } label: { Label("Apply", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .help("Put every window in its region now")
                Button { model.preview() } label: { Label("Preview", systemImage: "eye") }
                    .help("Draw what Apply would do over your displays first")
                    .disabled(item.isHUDOnly)
                Button { model.edit() } label: { Label("Edit Layout", systemImage: "square.and.pencil") }
                    .help("Open the layout editor on this loadout: move, resize and draw regions")
                    .disabled(item.isHUDOnly)
                Spacer()
            }
            preview
            if item.sketch.desktops.count > 1 { desktopStrip }
            if item.sketch.dock != nil || !item.sketch.hudPanels.isEmpty { hudRow }
            ForEach(item.sketch.notes, id: \.self) { note in
                Label(note, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(item.sketch.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if model.confirmingDelete == item.id { deleteBar } else { footer }
        }
    }

    @ViewBuilder private var header: some View {
        if let draft = model.renameDraft {
            HStack {
                TextField("Name", text: Binding(get: { draft }, set: { model.renameDraft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { model.commitRename() }
                Button("Cancel") { model.cancelRename() }
                Button("Rename") { model.commitRename() }.buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name).font(.title2.weight(.semibold)).lineLimit(1)
                    if item.isStartup { badge("At startup", symbol: "star.fill", color: .yellow) }
                    if item.isActive { badge("Applied", symbol: "checkmark", color: .green) }
                    if let hotkey = item.loadout.hotkey { badge(hotkey.display, symbol: "keyboard", color: .secondary) }
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts = [item.summary]
        let layouts = item.loadout.layoutNames
        if !layouts.isEmpty, item.ownedLayouts.count < layouts.count {
            parts.append("layout " + layouts.filter { !item.ownedLayouts.contains($0) }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var preview: some View {
        LoadoutSketchView(sketch: item.sketch, desktop: model.desktop, style: .large)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .overlay {
                if item.isHUDOnly {
                    Text("Only the HUD: where the tool dock sits and which app panels show")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.sketch.desktops.count > 1 {
                    Text(Self.desktopTitle(model.desktop)).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .padding(8)
                }
            }
    }

    static func desktopTitle(_ desktop: Int?) -> String { desktop.map { "Desktop \($0)" } ?? "Showing desktop" }

    private var desktopStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(item.sketch.desktops, id: \.self) { desktop in
                    let selected = desktop == model.desktop
                    VStack(spacing: 4) {
                        LoadoutSketchView(sketch: item.sketch, desktop: desktop, style: .thumbnail)
                            .frame(width: 96, height: 50)
                        Text(Self.desktopTitle(desktop) + " · \(item.sketch.regions(on: desktop).count)")
                            .font(.caption2.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.desktop = desktop }
                }
            }
        }
    }

    private var hudRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "dock.rectangle").foregroundStyle(.secondary)
            if let dock = item.sketch.dock {
                Text("Tool dock \(Self.positionTitle(dock))").font(.caption)
            }
            let apps = Dictionary(grouping: item.sketch.hudPanels, by: \.app).keys.sorted()
            ForEach(apps, id: \.self) { app in
                let shown = item.sketch.hudPanels.contains { $0.app == app && $0.visible }
                HStack(spacing: 3) {
                    Image(nsImage: OccupantStyle.appIcon(app)).resizable().frame(width: 12, height: 12)
                    Text(OccupantStyle.appName(app) ?? app).font(.caption)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(shown ? 0.12 : 0.05)))
                .opacity(shown ? 1 : 0.6)
                .help(shown ? "Shown" : "Hidden")
            }
            Spacer()
        }
    }

    static func positionTitle(_ position: HUDDockPosition) -> String {
        switch position {
        case .top: return "at the top"
        case .bottom: return "at the bottom"
        case .left: return "on the left"
        case .right: return "on the right"
        case .topLeft: return "top left"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomRight: return "bottom right"
        }
    }

    /// Labelled buttons, or icons alone when the window is too narrow for the words.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(labels: true)
            footerRow(labels: false)
        }
        .controlSize(.small)
    }

    private func footerRow(labels: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                Button { model.beginRename() } label: { Label("Rename", systemImage: "pencil") }
                    .help("Rename this loadout (and the layouts captured for it)")
                Button { model.duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .help("Copy this loadout and its captured layouts")
            }
            .labelStyle(FooterLabelStyle(showsTitle: labels))
            Toggle(isOn: Binding(get: { item.isStartup }, set: { _ in model.toggleStartup() })) {
                Text(labels ? "Apply at startup" : "At startup")
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Apply this loadout about two seconds after MacHUD starts")
            Spacer(minLength: 8)
            Button(role: .destructive) { model.requestDelete() } label: { Label("Delete", systemImage: "trash") }
                .labelStyle(FooterLabelStyle(showsTitle: labels))
                .help("Delete this loadout")
        }
    }

    private struct FooterLabelStyle: LabelStyle {
        let showsTitle: Bool
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon
                if showsTitle { configuration.title.fixedSize() }
            }
        }
    }

    private var deleteBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").foregroundStyle(.red)
            let question = LoadoutLibrary.deleteQuestion(item.name, ownedLayouts: item.ownedLayouts)
            VStack(alignment: .leading, spacing: 2) {
                Text(question.title).font(.callout.weight(.semibold))
                if let detail = question.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Cancel") { model.cancelDelete() }.keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) { model.confirmDelete() }
                .buttonStyle(.borderedProminent).tint(.red)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.14)))
        .controlSize(.small)
    }
}

/// A loadout's displays, arranged as they are attached, with one desktop's regions on them:
/// each region in its app's colour with its icon and name, parked ones dashed, the HUD's
/// panels outlined and the tool dock drawn where it sits.
struct LoadoutSketchView: View {
    enum Style { case thumbnail, large }

    let sketch: LoadoutSketch
    let desktop: Int?
    let style: Style

    var body: some View {
        GeometryReader { geo in
            // The large style writes each display's name under it.
            let caption: CGFloat = style == .large ? 18 : 0
            let map = Mapping(bounds: sketch.bounds,
                              size: CGSize(width: geo.size.width, height: max(geo.size.height - caption, 1)))
            ZStack(alignment: .topLeading) {
                ForEach(Array(sketch.displays.enumerated()), id: \.offset) { index, display in
                    displayView(index: index, display: display, map: map)
                    if style == .large { displayCaption(index: index, display: display, map: map) }
                }
            }
        }
    }

    /// Cocoa screen coordinates → view coordinates (top-left origin), fitting `bounds` into
    /// `size` and centring it.
    struct Mapping {
        var bounds: CGRect
        var scale: CGFloat
        var offset: CGPoint

        init(bounds: CGRect, size: CGSize) {
            self.bounds = bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
            scale = min(size.width / max(self.bounds.width, 1), size.height / max(self.bounds.height, 1))
            offset = CGPoint(x: (size.width - self.bounds.width * scale) / 2, y: (size.height - self.bounds.height * scale) / 2)
        }

        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: offset.x + (r.minX - bounds.minX) * scale, y: offset.y + (bounds.maxY - r.maxY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
    }

    private func displayView(index: Int, display: LoadoutSketch.Display, map: Mapping) -> some View {
        let inset: CGFloat = sketch.displays.count > 1 ? (style == .large ? 4 : 1.5) : 0
        let frame = map.rect(display.frame).insetBy(dx: inset, dy: inset)
        let regions = sketch.regions(on: desktop).filter { $0.display == index }
        let used = !regions.isEmpty
        let radius: CGFloat = style == .large ? 6 : 3
        let menuBar = max(0, (display.frame.maxY - display.visible.maxY) * map.scale)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            if style == .large {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: max(menuBar, 3))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius))
            }
            ForEach(regions) { region in
                regionView(region, in: frame, map: map, inset: inset)
            }
            if style == .large {
                ForEach(sketch.hudPanels.filter { $0.visible && $0.frame != nil }) { panel in
                    hudPanelView(panel, display: display, in: frame, map: map, inset: inset)
                }
            }
            if let dock = sketch.dock, display.descriptor.isMain {
                dockView(dock, size: frame.size)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.white.opacity(used ? 0.35 : 0.18), lineWidth: style == .large ? 1.2 : 0.8))
        .opacity(used || style == .thumbnail ? 1 : 0.7)
        .offset(x: frame.minX, y: frame.minY)
    }

    private func displayCaption(index: Int, display: LoadoutSketch.Display, map: Mapping) -> some View {
        let frame = map.rect(display.frame)
        let used = sketch.regions(on: desktop).contains { $0.display == index }
        return HStack(spacing: 4) {
            Image(systemName: display.descriptor.isBuiltin ? "laptopcomputer" : "display")
            Text(display.name).lineLimit(1).truncationMode(.tail)
            if display.descriptor.isMain { Text("· main").foregroundStyle(.white.opacity(0.45)) }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(used ? 0.8 : 0.45))
        .frame(width: max(frame.width, 1))
        .offset(x: frame.minX, y: frame.maxY + 4)
    }

    private func regionView(_ region: LoadoutSketch.Region, in display: CGRect, map: Mapping, inset: CGFloat) -> some View {
        let r = map.rect(region.rect).offsetBy(dx: -display.minX - inset, dy: -display.minY - inset)
            .insetBy(dx: style == .large ? 2 : 0.75, dy: style == .large ? 2 : 0.75)
        let color = Color(nsColor: OccupantStyle.color(region.occupant))
        let parked = region.parked != nil
        let radius: CGFloat = style == .large ? 5 : 1.5
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color.opacity(parked ? 0.12 : (style == .large ? 0.3 : 0.55)))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color.opacity(0.95),
                              style: StrokeStyle(lineWidth: style == .large ? 1.5 : 0.75, dash: parked ? [4, 3] : []))
            if style == .large { regionLabel(region, size: r.size) }
            else if r.width >= 14, r.height >= 14 {
                Image(nsImage: OccupantStyle.icon(region.occupant)).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: min(r.width, r.height) * 0.55)
            }
        }
        .frame(width: max(r.width, 1), height: max(r.height, 1))
        .offset(x: r.minX, y: r.minY)
    }

    @ViewBuilder private func regionLabel(_ region: LoadoutSketch.Region, size: CGSize) -> some View {
        let icon = min(28, max(12, min(size.width, size.height) * 0.36))
        if size.width >= 54, size.height >= 44 {
            VStack(spacing: 3) {
                Image(nsImage: OccupantStyle.icon(region.occupant)).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: icon, height: icon)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                Text(OccupantStyle.title(region.occupant))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if size.height >= 74, let sub = subtitle(region) {
                    Text(sub).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .padding(4)
        } else if size.width >= 14, size.height >= 14 {
            Image(nsImage: OccupantStyle.icon(region.occupant)).resizable().aspectRatio(contentMode: .fit)
                .frame(width: min(icon, size.width - 4, size.height - 4))
        }
    }

    private func subtitle(_ region: LoadoutSketch.Region) -> String? {
        if let edge = region.parked { return "parked · \(edge.rawValue)" }
        if let from = region.redirectedFrom { return "from \(from)" }
        return OccupantStyle.kind(region.occupant)
    }

    private func hudPanelView(_ panel: LoadoutSketch.HUDPanel, display: LoadoutSketch.Display, in frame: CGRect,
                              map: Mapping, inset: CGFloat) -> some View {
        let panelFrame = panel.frame ?? .zero
        let onThis = display.frame.intersects(panelFrame)
        let r = map.rect(panelFrame.intersection(display.frame)).offsetBy(dx: -frame.minX - inset, dy: -frame.minY - inset)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            Text(OccupantStyle.title(.panel(id: panel.id)))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(3)
        }
        .frame(width: max(r.width, 1), height: max(r.height, 1))
        .offset(x: r.minX, y: r.minY)
        .opacity(onThis ? 1 : 0)
    }

    /// The tool dock as a short bar on its edge, or an L in its corner.
    private func dockView(_ position: HUDDockPosition, size: CGSize) -> some View {
        let thick: CGFloat = style == .large ? 5 : 2
        let long = min(size.width, size.height) * 0.28
        let pad: CGFloat = style == .large ? 4 : 1.5
        return ZStack(alignment: .topLeading) {
            ForEach(position.edges, id: \.self) { edge in
                let horizontal = edge == .top || edge == .bottom
                let w = horizontal ? (position.isCorner ? long : size.width * 0.34) : thick
                let h = horizontal ? thick : (position.isCorner ? long : size.height * 0.34)
                let x: CGFloat = {
                    switch edge {
                    case .left: return pad
                    case .right: return size.width - w - pad
                    default:
                        if position.edges.contains(.left) { return pad }
                        if position.edges.contains(.right) { return size.width - w - pad }
                        return (size.width - w) / 2
                    }
                }()
                let y: CGFloat = {
                    switch edge {
                    case .top: return pad
                    case .bottom: return size.height - h - pad
                    default:
                        if position.edges.contains(.top) { return pad }
                        if position.edges.contains(.bottom) { return size.height - h - pad }
                        return (size.height - h) / 2
                    }
                }()
                Capsule().fill(Color.white.opacity(0.85)).frame(width: w, height: h).offset(x: x, y: y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Snapshots

/// Renders the settings window on its Loadouts tab offscreen, for review: in a window that is
/// never ordered on screen, over a dark backdrop standing in for the glass (the live blur
/// cannot render offscreen).
@MainActor
enum LoadoutsSnapshot {
    nonisolated static let size = CGSize(width: 820, height: 560)

    static func render(_ window: SettingsWindowModel, size: CGSize = size) -> NSBitmapImageRep? {
        let host = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: SettingsWindowView(model: window))
        view.frame = root.bounds
        root.addSubview(view)
        host.contentView = root
        for _ in 0..<4 {
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        host.contentView = nil
        host.close()
        return rep
    }

    @discardableResult
    static func write(_ window: SettingsWindowModel, to url: URL, size: CGSize = size) throws -> URL {
        guard let rep = render(window, size: size), let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
