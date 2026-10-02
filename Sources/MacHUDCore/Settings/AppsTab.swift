import AppKit
import SwiftUI

/// The settings window's "Apps" tab: the catalog against what is installed, with
/// Install / Update / Remove / Open per app and "Install bundled tools".
@MainActor
final class AppsTabModel: ObservableObject {
    static let tabID = "apps"

    struct Row: Identifiable, Equatable {
        var status: CatalogAppStatus
        var iconURL: URL?
        var phase: AppInstaller.Phase?
        var id: String { status.entry.id }
        var entry: CatalogEntry { status.entry }
        var busy: Bool { phase?.isBusy ?? false }
    }

    struct SelfUpdate: Equatable {
        var available: String
        var current: String
        var page: URL?
    }

    @Published var rows: [Row] = []
    @Published var selfUpdate: SelfUpdate?
    @Published var selected: Set<String> = []
    @Published var catalogNote = ""
    @Published var catalogError: String?
    @Published var refreshing = false

    var install: (String) -> Void = { _ in }
    var update: (String) -> Void = { _ in }
    var remove: (String) -> Void = { _ in }
    var open: (String) -> Void = { _ in }
    var refresh: () -> Void = {}
    var installBundled: () -> Void = {}
    var installSelected: () -> Void = {}

    var bundledToInstall: [Row] { rows.filter { $0.entry.isBundled && $0.status.state == .notInstalled } }
    var selectedToInstall: [Row] { rows.filter { selected.contains($0.id) && $0.status.state == .notInstalled } }

    var json: [String: Any] {
        var d: [String: Any] = ["rows": rows.map { row -> [String: Any] in
            var r = ["id": row.id, "state": row.status.state.rawValue, "version": row.entry.version] as [String: Any]
            if let v = row.status.installed?.version { r["installed"] = v }
            if let p = row.phase { r["phase"] = p.text }
            return r
        }, "selected": selected.sorted(), "note": catalogNote]
        if let selfUpdate { d["selfUpdate"] = ["available": selfUpdate.available, "current": selfUpdate.current] }
        if let catalogError { d["error"] = catalogError }
        return d
    }
}

struct AppsTabView: View {
    @ObservedObject var model: AppsTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.catalogNote).font(.callout).foregroundStyle(.secondary)
                if let error = model.catalogError {
                    Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refresh() }.disabled(model.refreshing)
            }
            if let update = model.selfUpdate {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text("MacHUD \(update.available) is available (you have \(update.current)).")
                    Spacer()
                    Button("Download") { if let page = update.page { NSWorkspace.shared.open(page) } }
                        .disabled(update.page == nil)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            }
            if model.rows.isEmpty {
                Spacer()
                Text(model.refreshing ? "Loading the catalog…" : "No apps in the catalog yet.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.rows) { row in AppsRowView(row: row, model: model) }
                    }
                }
            }
            HStack {
                let bundled = model.bundledToInstall
                Button(bundled.isEmpty ? "Bundled tools installed" : "Install bundled tools (\(bundled.count))") {
                    model.installBundled()
                }
                .disabled(bundled.isEmpty)
                let selected = model.selectedToInstall
                if !selected.isEmpty {
                    Button("Install selected (\(selected.count))") { model.installSelected() }
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
        }
        .padding(8)
    }
}

struct AppsRowView: View {
    let row: AppsTabModel.Row
    @ObservedObject var model: AppsTabModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if row.status.state == .notInstalled {
                Toggle("", isOn: Binding(get: { model.selected.contains(row.id) },
                                         set: { if $0 { model.selected.insert(row.id) } else { model.selected.remove(row.id) } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(row.busy)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
            }
            icon.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.entry.name).font(.headline)
                    Text(row.entry.kindLabel).font(.caption2.weight(.semibold)).textCase(.uppercase)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    if row.entry.isBundled { Text("bundled").font(.caption2).foregroundStyle(.secondary) }
                }
                if let summary = row.entry.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(versionText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let phase = row.phase {
                if phase.isBusy {
                    if case .downloading(let f) = phase, f > 0 {
                        ProgressView(value: f).frame(width: 70)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(phase.text).font(.caption)
                    .foregroundStyle({ if case .failed = phase { return Color.red } else { return Color.secondary } }())
                    .lineLimit(3).frame(maxWidth: 180, alignment: .trailing)
            }
            buttons.disabled(row.busy)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var versionText: String {
        let available = "v\(row.entry.version)"
        switch row.status.state {
        case .notInstalled: return available
        case .installed: return "Installed \(row.status.installed?.version ?? "?")"
        case .updateAvailable: return "Installed \(row.status.installed?.version ?? "?") · \(available) available"
        case .newerInstalled: return "Installed \(row.status.installed?.version ?? "?") (catalog has \(available))"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch row.status.state {
        case .notInstalled:
            Button("Install") { model.install(row.id) }
        case .updateAvailable:
            Button("Update") { model.update(row.id) }
            Button("Open") { model.open(row.id) }
            Button("Remove") { model.remove(row.id) }
        case .installed, .newerInstalled:
            Button("Open") { model.open(row.id) }
            Button("Remove") { model.remove(row.id) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = row.status.installed?.bundleURL.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else if let url = row.iconURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}
