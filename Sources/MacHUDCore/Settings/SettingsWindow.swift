import AppKit
import HUDKit
import SwiftUI

/// One tab of the settings window: an app that speaks `settings get/set` over its socket.
struct SettingsSource: Equatable {
    /// "machud" (MacHUD itself) or the app's bundle id.
    var id: String
    var title: String
    var symbol: String
    var socketPath: String
    /// The schema its bundle ships, so a stopped app still shows its settings.
    var bundleSchema: HUDSettingsSchema?
    var isRunning: Bool
    /// MacHUD itself cannot be launched from its own window.
    var canLaunch: Bool
}

/// Loads and saves one app's settings over its socket. Socket I/O runs off the main thread.
@MainActor
final class SettingsTabModel: ObservableObject, Identifiable {
    enum Status: Equatable {
        case loading, ready, notRunning
        case failed(String)

        var text: String {
            switch self {
            case .loading: return "loading"
            case .ready: return "ready"
            case .notRunning: return "notRunning"
            case .failed(let why): return "failed: \(why)"
            }
        }
    }

    @Published private(set) var source: SettingsSource
    @Published private(set) var form = SettingsForm(sections: [])
    @Published private(set) var status: Status = .loading
    @Published var lastError: String?
    /// Where the schema came from: "socket", "bundle" or "none".
    private(set) var schemaOrigin = "none"
    var launch: (() -> Void)?

    nonisolated var id: String { sourceID }
    private nonisolated let sourceID: String

    init(source: SettingsSource) {
        self.source = source
        sourceID = source.id
    }

    func update(_ source: SettingsSource) { self.source = source }

    /// Fetches the schema (over the socket, else the bundle's) and the current values.
    func load(completion: (() -> Void)? = nil) {
        guard source.isRunning else {
            form = SettingsForm.build(schema: source.bundleSchema, values: [:])
            schemaOrigin = source.bundleSchema == nil ? "none" : "bundle"
            status = .notRunning
            completion?()
            return
        }
        status = .loading
        let path = source.socketPath
        DispatchQueue.global(qos: .userInitiated).async {
            var client = HUDSocketClient(path: path, timeout: 3)
            client.timeout = 3
            let schemaReply = try? client.request("settings", args: ["action": "schema"])
            let result: Result<[String: Any], Error> = Result { try client.request("settings", args: ["action": "get"]) }
            let box = UncheckedBox((schemaReply, result))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let (schemaReply, result) = box.value
                    self.finishLoad(schemaReply: schemaReply, result: result)
                    completion?()
                }
            }
        }
    }

    private func finishLoad(schemaReply: [String: Any]?, result: Result<[String: Any], Error>) {
        var schema = source.bundleSchema
        schemaOrigin = schema == nil ? "none" : "bundle"
        if schemaReply?["ok"] as? Bool == true, let s = schemaReply?["schema"].flatMap(HUDSettingsSchema.init(json:)) {
            schema = s
            schemaOrigin = "socket"
        }
        switch result {
        case .success(let reply) where reply["ok"] as? Bool == true:
            form = SettingsForm.build(schema: schema, values: reply["settings"] as? [String: Any] ?? [:])
            status = .ready
        case .success(let reply):
            form = SettingsForm.build(schema: schema, values: [:])
            status = .failed(reply["error"] as? String ?? "settings get failed")
        case .failure(let error):
            form = SettingsForm.build(schema: schema, values: [:])
            status = .failed("\(error)")
        }
    }

    /// Sends one value; the app's reply (its settings after the change) refreshes the form.
    func set(_ row: SettingsForm.Row, _ value: HUDSettingValue) {
        guard let wire = SettingsForm.wireValue(value, for: row) else {
            lastError = "\(row.title): not a valid value"
            return
        }
        guard wire != row.text || row.isDefault else { return }
        let path = source.socketPath
        let key = row.key
        DispatchQueue.global(qos: .userInitiated).async {
            let client = HUDSocketClient(path: path, timeout: 3)
            let result: Result<[String: Any], Error> = Result { try client.request("settings", args: ["action": "set", key: wire]) }
            let box = UncheckedBox(result)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch box.value {
                    case .success(let reply) where reply["ok"] as? Bool == true:
                        self.lastError = nil
                        self.load()
                    case .success(let reply):
                        self.lastError = reply["error"] as? String ?? "settings set failed"
                        self.load()
                    case .failure(let error):
                        self.lastError = "\(error)"
                    }
                }
            }
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["id": source.id, "title": source.title, "status": status.text,
                                "schema": schemaOrigin, "sections": form.json]
        if let lastError { d["lastError"] = lastError }
        return d
    }
}

@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published var tabs: [SettingsTabModel] = []
    @Published var selection: String = ""
    /// The "Apps" tab (catalog installs), when the catalog is wired up.
    @Published var apps: AppsTabModel?
    /// The "Voice" and "Brain" tabs, when the voice host is wired up.
    @Published var voice: VoiceSettingsModel?

    /// Tab ids MacHUD adds beside the per-app tabs.
    var builtInTabIDs: [String] {
        (voice == nil ? [] : [VoiceSettingsModel.voiceTabID, VoiceSettingsModel.brainTabID])
            + (apps == nil ? [] : [AppsTabModel.tabID])
    }
}

/// The shared settings window (PLAN 3.5): a tab per discovered MacHUD app plus MacHUD's own,
/// each rendering the app's settings schema generically. `settings-window show|hide`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsWindowModel()
    /// The tabs to show, MacHUD first.
    var sources: () -> [SettingsSource] = { [] }
    /// Launches the app with this id (a stopped app's tab offers it).
    var launch: ((String) -> Void)?
    /// Runs each time the window is shown (the Apps tab refreshes from it).
    var onShow: (() -> Void)?
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Rebuilds the tabs, reloads every tab, and brings the window up. `completion` runs
    /// once every tab has loaded.
    func show(select: String? = nil, activate: Bool = true, completion: (() -> Void)? = nil) {
        refreshTabs()
        onShow?()
        if let select, model.builtInTabIDs.contains(select.lowercased()) { model.selection = select.lowercased() }
        else if let select, let tab = tab(matching: select) { model.selection = tab.id }
        if model.selection.isEmpty || !(model.tabs.contains(where: { $0.id == model.selection })
                                         || model.builtInTabIDs.contains(model.selection)) {
            model.selection = model.tabs.first?.id ?? ""
        }
        let window = self.window ?? makeWindow()
        self.window = window
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
        let group = DispatchGroup()
        for tab in model.tabs {
            group.enter()
            tab.load { group.leave() }
        }
        if let voice = model.voice {
            group.enter()
            voice.load { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    func hide() { window?.orderOut(nil) }

    func tab(matching key: String) -> SettingsTabModel? {
        model.tabs.first { $0.id == key }
            ?? model.tabs.first { $0.source.title.caseInsensitiveCompare(key) == .orderedSame }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["visible": isVisible, "selected": model.selection, "tabs": model.tabs.map(\.json)]
        if let apps = model.apps { d["apps"] = apps.json }
        if let voice = model.voice { d["voice"] = voice.json }
        return d
    }

    private func refreshTabs() {
        let sources = self.sources()
        model.tabs = sources.map { source in
            let tab = model.tabs.first { $0.id == source.id } ?? SettingsTabModel(source: source)
            tab.update(source)
            let id = source.id
            tab.launch = source.canLaunch ? { [weak self] in
                self?.launch?(id)
                // Look again once it has had a moment to start listening.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { self?.show(select: id) }
                }
            } : nil
            return tab
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 460),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "MacHUD Settings"
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.minSize = CGSize(width: 480, height: 320)
        w.identifier = NSUserInterfaceItemIdentifier("machud.settings")
        w.delegate = self
        let glass = HUDGlassView(frame: w.contentView!.bounds, style: .plain)
        glass.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: SettingsWindowView(model: model))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        w.contentView = glass
        w.center()
        w.setFrameAutosaveName("MacHUDSettingsWindow")
        return w
    }
}

// MARK: - Views

struct SettingsWindowView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        TabView(selection: $model.selection) {
            // MacHUD, then its built-in voice host, then the sibling apps.
            ForEach(model.tabs.prefix(1)) { appTab($0) }
            if let voice = model.voice {
                VoiceTabView(model: voice)
                    .tabItem { Label("Voice", systemImage: "mic") }
                    .tag(VoiceSettingsModel.voiceTabID)
                BrainTabView(model: voice)
                    .tabItem { Label("Brain", systemImage: "brain") }
                    .tag(VoiceSettingsModel.brainTabID)
            }
            ForEach(model.tabs.dropFirst()) { appTab($0) }
            if let apps = model.apps {
                AppsTabView(model: apps)
                    .tabItem { Label("Apps", systemImage: "square.and.arrow.down") }
                    .tag(AppsTabModel.tabID)
            }
        }
        .padding(.top, 28)
        .padding([.horizontal, .bottom], 12)
    }

    private func appTab(_ tab: SettingsTabModel) -> some View {
        SettingsTabView(model: tab)
            .tabItem { Label(tab.source.title, systemImage: tab.source.symbol) }
            .tag(tab.id)
    }
}

struct SettingsTabView: View {
    @ObservedObject var model: SettingsTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.form.sections.isEmpty {
                Spacer()
                Text(model.status == .loading ? "Loading…" : "\(model.source.title) has no settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Form {
                    ForEach(model.form.sections) { section in
                        Section(section.title ?? model.source.title) {
                            ForEach(section.rows) { row in
                                SettingsRowView(row: row, editable: model.status == .ready) { model.set(row, $0) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private var header: some View {
        HStack {
            switch model.status {
            case .notRunning:
                Text("\(model.source.title) is not running; showing its defaults.").foregroundStyle(.secondary)
                if let launch = model.launch { Button("Launch", action: launch) }
            case .failed(let why):
                Text(why).foregroundStyle(.red).lineLimit(2)
                Button("Retry") { model.load() }
            case .loading, .ready:
                EmptyView()
            }
            Spacer()
            if let error = model.lastError { Text(error).foregroundStyle(.red).lineLimit(2) }
        }
        .font(.callout)
        .padding(.horizontal, 8)
    }
}

struct SettingsRowView: View {
    let row: SettingsForm.Row
    let editable: Bool
    let commit: (HUDSettingValue) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            control
            if let help = row.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(!editable)
        .onAppear { draft = row.text }
        .onChange(of: row.text) { _, new in draft = new }
    }

    @ViewBuilder private var control: some View {
        switch row.control {
        case .toggle:
            Toggle(row.title, isOn: Binding(get: { row.isOn }, set: { commit(.bool($0)) }))
        case .choice(let options):
            Picker(row.title, selection: Binding(get: { row.text }, set: { commit(.string($0)) })) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
        case .readOnly:
            LabeledContent(row.title) { Text(row.text).foregroundStyle(.secondary).lineLimit(3) }
        case .number(let spec):
            LabeledContent(row.title) {
                HStack {
                    TextField(row.title, text: $draft, prompt: Text(row.isDefault ? "default" : ""))
                        .labelsHidden()
                        .onSubmit {
                            // Invalid text goes back to the current value; out of range is clamped.
                            guard let value = spec.parse(draft) else { draft = row.text; return }
                            draft = spec.format(value)
                            commit(.string(draft))
                        }
                    Stepper(row.title, onIncrement: { stepNumber(spec, by: 1) }, onDecrement: { stepNumber(spec, by: -1) })
                        .labelsHidden()
                }
            }
        case .text, .path:
            LabeledContent(row.title) {
                HStack {
                    TextField(row.title, text: $draft, prompt: Text(row.isDefault ? "default" : ""))
                        .labelsHidden()
                        .onSubmit { commit(.string(draft)) }
                    if row.control == .path {
                        Button("Choose…") { choosePath() }
                    }
                }
            }
        }
    }

    private func stepNumber(_ spec: NumberSpec, by direction: Int) {
        let current = spec.parse(draft) ?? row.value?.doubleValue
        draft = spec.format(spec.stepped(current, by: direction))
        commit(.string(draft))
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !draft.isEmpty { panel.directoryURL = URL(fileURLWithPath: (draft as NSString).expandingTildeInPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = url.path
        commit(.string(url.path))
    }
}
