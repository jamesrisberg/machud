import AppKit
import HUDKit

/// MacHUD's side of desktop widgets: it owns the placed instances (`WidgetsConfig` in
/// layouts.json), keeps every serving app's widgets in line with them, and turns what the
/// user does to a widget (the apps' `widget` events) into placement on the grid.
///
/// The apps hold their widgets in memory only. On every (re)connect MacHUD sends `widget
/// sync` with the app's whole state; after that each change is a `create`, `update` or
/// `remove` worked out by comparing what the app should show with what it was last sent
/// (`reconcile`). So a change from anywhere (the `widgets` verb, an event, a loadout, a
/// hand edit of layouts.json, a display change) goes through the same path.
@MainActor
final class WidgetLayer {
    /// One widget type an app serves.
    struct WidgetType {
        var app: ExternalApp
        var panel: HUDManifest.Panel
        var id: String { panel.id }
        var spec: HUDWidgetSpec { panel.widget ?? HUDWidgetSpec() }
        var title: String { panel.title }
        var symbol: String { panel.symbol ?? app.manifest.appSymbol }
    }

    /// What one app shows for one instance (or should).
    struct Shown: Equatable {
        var type: String
        var size: HUDWidgetSize
        var frame: CGRect
        var layer: HUDWidgetLayer
        var settings: [String: HUDSettingValue]

        var json: [String: Any] {
            HUDWidgetInstance(id: "", type: type, size: size, frame: frame, layer: layer, settings: settings).json
                .filter { $0.key != "instance" }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    let externals: ExternalPanels
    var supervisor: AppSupervisor { externals.supervisor }
    /// The current `widgets` config and how to persist a changed one.
    var config: () -> WidgetsConfig
    var save: (WidgetsConfig) -> Void
    /// The displays attached now (tests give their own).
    var screens: () -> [WidgetScreen] = { WidgetScreen.attached() }
    /// The layout grid (`grid` in layouts.json) widgets snap to.
    var grid: () -> GridSize = { .default }
    /// A new instance id: eight hex digits.
    var newID: () -> String = { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)) }
    /// Tells the user something went wrong (a toast).
    var notify: (String, String?) -> Void = { Toast.show($0, detail: $1, seconds: 3) }
    /// Shows an instance's settings (the `configure` event, the menu's Settings…).
    var configure: ((WidgetRecord) -> Void)?
    /// Summons a panel by registry id (the `open` event).
    var summon: ((String) -> Void)?
    /// The modes or the instances changed (menus, gallery and overlay redraw).
    var onChange: (() -> Void)?
    /// A type's per-instance settings schema, from its app's bundle.
    var schemaLoader: (ExternalApp, String) -> HUDSettingsSchema? = { app, type in
        HUDSettingsSchema.load(widget: type, manifest: app.manifest, bundleURL: app.bundleURL)
    }

    /// Every app with widgets shows them unlocked, with edit controls.
    private(set) var editing = false
    /// Desktop-layer widgets float above windows for now.
    private(set) var revealed = false
    /// Why an app refused an instance (sync `rejected`, a failed create), by instance id.
    private(set) var problems: [String: String] = [:]
    /// Settings an app dropped from an instance during sync: instance → key → why.
    private(set) var droppedSettings: [String: [String: String]] = [:]
    /// What each app was last sent, per instance id; nil until its sync answered.
    private var sent: [String: [String: Shown]] = [:]
    /// What an app refused to create, per instance id: not offered again until it changes.
    private var refused: [String: Shown] = [:]
    /// Instances a toast already reported, so a reconnect does not repeat it.
    private var reported: Set<String> = []
    /// Set while MacHUD saves its own change, so the config reload it causes is not a second pass.
    private var saving = false

    init(externals: ExternalPanels, config: @escaping () -> WidgetsConfig, save: @escaping (WidgetsConfig) -> Void) {
        self.externals = externals
        self.config = config
        self.save = save
    }

    // MARK: - Types and records

    /// Every widget type of every discovered app, apps by name.
    func types() -> [WidgetType] {
        externals.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { app in app.manifest.widgetPanels.map { WidgetType(app: app, panel: $0) } }
    }

    func type(app: String, type: String) -> WidgetType? {
        guard let app = externals.apps.first(where: { $0.id == app }),
              let panel = app.manifest.widgetPanels.first(where: { $0.id == type }) else { return nil }
        return WidgetType(app: app, panel: panel)
    }

    func schema(_ type: WidgetType) -> HUDSettingsSchema? { schemaLoader(type.app, type.id) }

    var records: [WidgetRecord] { config().instances }

    func record(_ id: String) -> WidgetRecord? { config().record(id) }

    /// The record's type is not (or no longer) served: it is kept but not shown.
    func isMissingType(_ record: WidgetRecord) -> Bool { type(app: record.app, type: record.type) == nil }

    /// Apps with instances: MacHUD keeps them running like `autoLaunch` apps.
    var appsWithInstances: Set<String> { Set(records.filter { !isMissingType($0) }.map(\.app)) }

    /// Apps serving widget types; they get `edit` and `reveal`.
    var servingApps: [ExternalApp] { externals.apps.filter { !$0.manifest.widgetPanels.isEmpty } }

    func placements() -> [String: WidgetPlacement.Placed] {
        WidgetPlacement.resolve(records, screens: screens(), grid: grid(), legacy: config().legacyGrid ?? .standard) { [unowned self] in
            !isMissingType($0)
        }
    }

    /// The layout grid on display `index`.
    func widgetGrid(on index: Int, grid: GridSize? = nil) -> WidgetGrid? {
        let screens = screens()
        guard screens.indices.contains(index) else { return nil }
        return WidgetGrid(visible: screens[index].visible, grid: grid ?? self.grid())
    }

    /// The frames of an app's placed widgets (show verification leaves those windows out).
    func frames(app: String) -> [CGRect] {
        let placed = placements()
        return records.filter { $0.app == app }.compactMap { placed[$0.instance]?.frame }
    }

    /// Whether a window at `frame` is one of the widgets MacHUD placed (any app's).
    func isWidgetFrame(_ frame: CGRect) -> Bool {
        placements().values.contains { WindowPresence.sameFrame($0.frame, frame) }
    }

    /// What `app` should show now, in record order.
    func desired(_ app: String) -> [(id: String, shown: Shown)] {
        let placed = placements()
        return records.filter { $0.app == app }.compactMap { r in
            placed[r.instance].map { (r.instance, Shown(type: r.type, size: r.size, frame: $0.frame, layer: r.layer,
                                                        settings: r.settings ?? [:])) }
        }
    }

    // MARK: - Persisting

    /// Saves a changed config and brings the affected apps in line. `done` gets the apps'
    /// failures by instance id.
    func commit(_ next: WidgetsConfig, apps: Set<String>? = nil, done: @escaping ([String: String]) -> Void = { _ in }) {
        let before = Set(config().instances.map(\.app))
        saving = true
        save(next)
        saving = false
        externals.refreshKeepRunning()
        onChange?()
        let touched = apps ?? before.union(next.instances.map(\.app))
        reconcile(Array(touched).sorted(), done: done)
    }

    /// layouts.json changed (a hand edit, a reload) or the displays did: bring every app in line.
    func configChanged() {
        guard !saving else { return }
        externals.refreshKeepRunning()
        onChange?()
        reconcile(servingApps.map(\.id))
    }

    // MARK: - Talking to apps

    /// An app connected (or reconnected): send it its whole state.
    func appConnected(_ id: String) {
        guard let app = externals.apps.first(where: { $0.id == id }), !app.manifest.widgetPanels.isEmpty else { return }
        sync(id)
    }

    /// `widget sync` with every instance the app should show and the current modes.
    func sync(_ id: String, done: (() -> Void)? = nil) {
        sent[id] = nil
        let want = desired(id)
        let list = want.map { item -> [String: Any] in
            var d = item.shown.json
            d["instance"] = item.id
            return d
        }
        let modes = (editing: editing, revealed: revealed)
        let args = ["action": "sync", "instances": Self.jsonText(list), "editing": modes.editing ? "on" : "off",
                    "revealed": modes.revealed ? "on" : "off"]
        supervisor.send(id, command: "widget", args: args) { [weak self] result in
            guard let self else { return }
            defer { done?() }
            guard case .success(let reply) = result, reply["ok"] as? Bool != false else {
                let why: String
                switch result {
                case .success(let reply): why = reply["error"] as? String ?? "sync failed"
                case .failure(let error): why = "\(error)"
                }
                NSLog("MacHUD: widget sync with %@ failed: %@", id, why)
                return
            }
            var rejected: [String: String] = [:]
            for r in reply["rejected"] as? [[String: Any]] ?? [] {
                guard let instance = r["instance"] as? String else { continue }
                rejected[instance] = r["error"] as? String ?? "rejected"
            }
            var dropped: [String: [String: String]] = [:]
            for d in reply["droppedSettings"] as? [[String: Any]] ?? [] {
                guard let instance = d["instance"] as? String, let key = d["key"] as? String else { continue }
                dropped[instance, default: [:]][key] = d["error"] as? String ?? "dropped"
            }
            var accepted: [String: Shown] = [:]
            for item in want {
                self.droppedSettings[item.id] = dropped[item.id]
                if let why = rejected[item.id] {
                    self.problems[item.id] = why
                    self.refused[item.id] = item.shown
                } else {
                    self.problems[item.id] = nil
                    self.refused[item.id] = nil
                    // Settings it dropped count as sent: resending them would only fail again.
                    accepted[item.id] = item.shown
                }
            }
            self.sent[id] = accepted
            // A mode that changed while the sync was on its way skipped this app (not synced yet).
            if self.editing != modes.editing {
                self.supervisor.send(id, command: "widget", args: ["action": "edit", "state": self.editing ? "on" : "off"])
            }
            if self.revealed != modes.revealed {
                self.supervisor.send(id, command: "widget", args: ["action": "reveal", "state": self.revealed ? "on" : "off"])
            }
            self.report(app: id, rejected: rejected, dropped: dropped)
            self.onChange?()
            // Anything that changed while the sync was on its way.
            self.reconcile([id])
        }
    }

    /// Sends each connected app in `apps` the creates, updates and removes that bring it from
    /// what it was sent to what it should show. Apps not connected (or not yet synced) are
    /// skipped: their next sync carries everything. `done` gets the failures by instance id.
    func reconcile(_ apps: [String], done: @escaping ([String: String]) -> Void = { _ in }) {
        var commands: [(app: String, id: String, args: [String: String], after: Shown?, before: Shown?)] = []
        for app in apps {
            guard supervisor.record(app)?.health == .running, let known = sent[app] else { continue }
            let want = desired(app)
            let wanted = Set(want.map(\.id))
            for id in known.keys.sorted() where !wanted.contains(id) {
                commands.append((app, id, ["action": "remove", "instance": id], nil, known[id]))
            }
            for (id, shown) in want {
                guard let was = known[id] else {
                    if refused[id] == shown { continue }
                    var args = ["action": "create", "instance": id, "type": shown.type, "size": shown.size.rawValue,
                                "frame": Self.frameText(shown.frame), "layer": shown.layer.rawValue]
                    if !shown.settings.isEmpty { args["settings"] = Self.jsonText(HUDWidgetInstance.settingsJSON(shown.settings)) }
                    commands.append((app, id, args, shown, nil))
                    continue
                }
                if was.type != shown.type {
                    // A record reused for another type: replace the window.
                    commands.append((app, id, ["action": "remove", "instance": id], nil, was))
                    var args = ["action": "create", "instance": id, "type": shown.type, "size": shown.size.rawValue,
                                "frame": Self.frameText(shown.frame), "layer": shown.layer.rawValue]
                    if !shown.settings.isEmpty { args["settings"] = Self.jsonText(HUDWidgetInstance.settingsJSON(shown.settings)) }
                    commands.append((app, id, args, shown, nil))
                    continue
                }
                var args = ["action": "update", "instance": id]
                if was.size != shown.size { args["size"] = shown.size.rawValue }
                if !Self.sameFrame(was.frame, shown.frame) || was.size != shown.size { args["frame"] = Self.frameText(shown.frame) }
                if was.layer != shown.layer { args["layer"] = shown.layer.rawValue }
                if !Self.sameSettings(was.settings, shown.settings) { args["settings"] = Self.jsonText(HUDWidgetInstance.settingsJSON(shown.settings)) }
                if args.count > 2 { commands.append((app, id, args, shown, was)) }
            }
        }
        guard !commands.isEmpty else { done([:]); return }
        var failures: [String: String] = [:]
        var left = commands.count
        for command in commands {
            // Recorded as sent now, so a second pass before the reply does not repeat it.
            sent[command.app]?[command.id] = command.after
            supervisor.send(command.app, command: "widget", args: command.args) { [weak self] result in
                guard let self else { return }
                var error: String?
                switch result {
                case .success(let reply) where reply["ok"] as? Bool == false: error = reply["error"] as? String ?? "refused"
                case .failure(let e): error = "\(e)"
                default: break
                }
                if let error {
                    failures[command.id] = error
                    if command.args["action"] == "create", let after = command.after {
                        self.problems[command.id] = error
                        self.refused[command.id] = after
                    }
                    // It did not change; what the app has is what it had.
                    if self.sent[command.app] != nil { self.sent[command.app]?[command.id] = command.before }
                    NSLog("MacHUD: widget %@ %@ on %@ failed: %@", command.args["action"] ?? "", command.id, command.app, error)
                } else if command.args["action"] == "create" {
                    self.problems[command.id] = nil
                    self.refused[command.id] = nil
                }
                left -= 1
                if left == 0 {
                    if !failures.isEmpty { self.onChange?() }
                    done(failures)
                }
            }
        }
    }

    /// One toast per app for instances it could not restore or settings it dropped, once per instance.
    private func report(app: String, rejected: [String: String], dropped: [String: [String: String]]) {
        let fresh = Set(rejected.keys).union(dropped.keys).subtracting(reported)
        guard !fresh.isEmpty else { return }
        reported.formUnion(fresh)
        let name = externals.app(matching: app)?.name ?? app
        let lost = rejected.keys.filter(fresh.contains).count
        let text = lost > 0 ? "\(name) could not restore \(lost) widget\(lost == 1 ? "" : "s")"
                            : "\(name) dropped settings from \(fresh.count) widget\(fresh.count == 1 ? "" : "s")"
        let detail = rejected.values.sorted().first ?? dropped.values.flatMap { $0.map { "\($0.key) \($0.value)" } }.sorted().first
        NSLog("MacHUD: %@: rejected %@, dropped %@", text, "\(rejected)", "\(dropped)")
        notify(text, detail)
    }

    // MARK: - Modes

    /// Edit mode on every serving app (unlocked, with remove, settings and resize controls).
    func setEditing(_ on: Bool) {
        guard on != editing else { return }
        editing = on
        broadcast("edit", on)
    }

    /// Desktop-layer widgets float above windows while on.
    func setRevealed(_ on: Bool) {
        guard on != revealed else { return }
        revealed = on
        broadcast("reveal", on)
    }

    private func broadcast(_ action: String, _ on: Bool) {
        for app in servingApps where supervisor.record(app.id)?.health == .running && sent[app.id] != nil {
            supervisor.send(app.id, command: "widget", args: ["action": action, "state": on ? "on" : "off"])
        }
        onChange?()
    }

    // MARK: - Events from apps

    /// A `widget` event: what the user did to a widget in the app.
    func handle(event: [String: Any], from app: String) {
        guard let id = event["instance"] as? String, let record = record(id), record.app == app,
              let change = event["change"] as? String else { return }
        switch change {
        case "frame":
            guard let frame = AppSupervisor.frame(event["frame"]) else { return }
            // The app moved its window already.
            sent[app]?[id]?.frame = frame
            if let error = drop(id, at: frame) { notify(error, nil) }
        case "size":
            guard let size = (event["size"] as? String).flatMap(HUDWidgetSize.init(rawValue:)) else { return }
            do { try resize(id, to: size) } catch { notify("\(error)", nil) }
        case "remove":
            try? remove(id)
        case "configure":
            configure?(record)
        case "settings":
            guard let raw = event["settings"] as? [String: Any] else { return }
            let settings = raw.compactMapValues(HUDSettingValue.init(any:))
            sent[app]?[id]?.settings = settings
            var c = config()
            guard let i = c.instances.firstIndex(where: { $0.instance == id }) else { return }
            c.instances[i].settings = settings.isEmpty ? nil : settings
            commit(c, apps: [app])
        case "open":
            guard let app = externals.app(matching: app), let panel = app.manifest.presentedPanels.first else { return }
            summon?(ExternalPanel.id(app: app.id, panel: panel.id))
        default:
            break
        }
    }

    /// A widget the user dropped at `frame` (an app's frame event, the layout editor): snapped
    /// to the nearest free spot on the layout grid of the display under its centre (`grid`, the
    /// one in layouts.json unless the editor is showing another). Returns why it could not be
    /// placed, else nil.
    @discardableResult
    func drop(_ id: String, at frame: CGRect, grid: GridSize? = nil) -> String? {
        if case .failure(let error) = place(id, at: frame, grid: grid) { return error.description }
        return nil
    }

    /// `drop`, saying where the widget went: `wanted` is `frame` snapped, `at` the free spot
    /// nearest it.
    func place(_ id: String, at frame: CGRect, grid: GridSize? = nil) -> Result<(wanted: CGRect, at: CGRect), Failure> {
        var c = config()
        guard let i = c.instances.firstIndex(where: { $0.instance == id }) else { return .failure(Failure("no such widget \(id)")) }
        let screens = screens()
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        guard let index = screens.firstIndex(where: { $0.frame.contains(centre) })
                ?? WidgetPlacement.screenIndex(c.instances[i].screen, screens: screens)?.index,
              let g = widgetGrid(on: index, grid: grid) else { return .failure(Failure("no display")) }
        let size = c.instances[i].size
        let s = size.points()
        let wanted = g.snap(CGRect(x: frame.minX, y: frame.maxY - s.height, width: s.width, height: s.height))
        guard let at = g.nearestFree(size, near: wanted, occupied: occupied(on: index, except: id)) else {
            commit(c)          // puts it back where it was
            return .failure(Failure("No room for it there"))
        }
        c.instances[i].screen = screens[index].ref
        c.instances[i].position = g.position(of: at)
        c.instances[i].legacyCell = nil
        commit(c)
        return .success((wanted, at))
    }

    /// The frames taken on display `index` by every placed widget but `except`.
    func occupied(on index: Int, except: String? = nil) -> [CGRect] {
        placements().filter { $0.key != except && $0.value.screen == index }.map(\.value.snapped)
    }

    /// A placement as `col,row` in grid-line units, for notes.
    func describe(_ frame: CGRect, on g: WidgetGrid) -> String {
        let lines = g.lines(g.position(of: frame))
        return "\(Self.number(lines.col)),\(Self.number(lines.row))"
    }

    // MARK: - Changes

    /// Places a new widget. `position` nil: the first free spot; else the free spot nearest it
    /// once snapped. `done` gets the instance's record and a note (moved to a free spot, app
    /// launching), or why not.
    func add(app key: String?, type typeID: String, size: HUDWidgetSize? = nil, screen ref: ScreenRef? = nil,
             position: WidgetGrid.Position? = nil, layer: HUDWidgetLayer = .desktop, settings: [String: HUDSettingValue] = [:],
             done: @escaping (Result<(WidgetRecord, String?), Failure>) -> Void) {
        let type: WidgetType
        do { type = try findType(app: key, type: typeID) } catch let e as Failure { done(.failure(e)); return } catch { return }
        let spec = type.spec
        let size = size ?? spec.defaultSize
        guard spec.sizes.contains(size) else {
            done(.failure(Failure("\(type.id) size must be one of \(spec.sizes.map(\.rawValue).joined(separator: ", "))"))); return
        }
        if !spec.multiple, records.contains(where: { $0.app == type.app.id && $0.type == type.id }) {
            done(.failure(Failure("\(type.id) allows one instance"))); return
        }
        let screens = screens()
        guard let index = WidgetPlacement.screenIndex(ref, screens: screens)?.index else { done(.failure(Failure("no display"))); return }
        if let ref, ref.index(in: screens.map(\.descriptor)) == nil { done(.failure(Failure("no display \(ref.label)"))); return }
        guard let g = widgetGrid(on: index) else { done(.failure(Failure("no display"))); return }
        let taken = occupied(on: index)
        let wanted = position.map { g.snap(g.frame($0, size)) }
        let at = wanted.map { g.nearestFree(size, near: $0, occupied: taken) } ?? g.firstFree(size, occupied: taken)
        guard let at else { done(.failure(Failure("no room for a \(size.rawValue) widget on \(screens[index].name)"))); return }
        var note: String?
        if let wanted, wanted != at { note = "\(describe(wanted, on: g)) is taken; placed at \(describe(at, on: g))" }
        let p = g.position(of: at)
        let record = WidgetRecord(instance: uniqueID(), app: type.app.id, type: type.id, size: size,
                                  screen: ref == nil ? nil : screens[index].ref, x: p.x, y: p.y, layer: layer,
                                  settings: settings.isEmpty ? nil : settings)
        var c = config()
        c.instances.append(record)
        guard supervisor.record(type.app.id)?.health == .running else {
            // Its sync on connecting carries the new widget.
            commit(c, apps: [type.app.id])
            let launch = supervisor.launch(type.app.id).map { "\(type.app.name): \($0)" } ?? "launching \(type.app.name)"
            done(.success((record, [note, launch].compactMap { $0 }.joined(separator: "; "))))
            return
        }
        commit(c, apps: [type.app.id]) { [weak self] failures in
            guard let self else { return }
            if let why = failures[record.instance] {
                var c = self.config()
                c.instances.removeAll { $0.instance == record.instance }
                self.problems[record.instance] = nil
                self.refused[record.instance] = nil
                self.commit(c, apps: [type.app.id])
                done(.failure(Failure("\(type.app.name) refused it: \(why)")))
                return
            }
            done(.success((record, note)))
        }
    }

    /// Removes a widget.
    func remove(_ id: String) throws {
        var c = config()
        guard let record = c.record(id) else { throw Failure("no such widget \(id)") }
        c.instances.removeAll { $0.instance == id }
        problems[id] = nil
        refused[id] = nil
        droppedSettings[id] = nil
        commit(c, apps: [record.app])
    }

    /// Moves a widget to the free spot nearest `position` once snapped (on `screen`, else its
    /// own display). Returns a note when it went elsewhere than asked.
    @discardableResult
    func move(_ id: String, to position: WidgetGrid.Position, screen ref: ScreenRef? = nil) throws -> String? {
        var c = config()
        guard let i = c.instances.firstIndex(where: { $0.instance == id }) else { throw Failure("no such widget \(id)") }
        let screens = screens()
        let index: Int
        if let ref {
            guard let i = ref.index(in: screens.map(\.descriptor)) else { throw Failure("no display \(ref.label)") }
            index = i
        } else {
            guard let own = WidgetPlacement.screenIndex(c.instances[i].screen, screens: screens) else { throw Failure("no display") }
            index = own.index
        }
        guard let g = widgetGrid(on: index) else { throw Failure("no display") }
        let size = c.instances[i].size
        let wanted = g.snap(g.frame(position, size))
        guard let at = g.nearestFree(size, near: wanted, occupied: occupied(on: index, except: id)) else {
            throw Failure("no room for it on \(screens[index].name)")
        }
        if ref != nil || c.instances[i].screen != nil { c.instances[i].screen = screens[index].ref }
        c.instances[i].position = g.position(of: at)
        c.instances[i].legacyCell = nil
        commit(c, apps: [c.instances[i].app])
        return at == wanted ? nil : "\(describe(wanted, on: g)) is taken; placed at \(describe(at, on: g)) on \(screens[index].name)"
    }

    /// Changes a widget's size: in place when it fits, else at the nearest free spot.
    func resize(_ id: String, to size: HUDWidgetSize) throws {
        var c = config()
        guard let i = c.instances.firstIndex(where: { $0.instance == id }) else { throw Failure("no such widget \(id)") }
        let record = c.instances[i]
        guard let type = type(app: record.app, type: record.type) else { throw Failure("\(record.type) is no longer served") }
        guard type.spec.sizes.contains(size) else {
            throw Failure("\(type.id) size must be one of \(type.spec.sizes.map(\.rawValue).joined(separator: ", "))")
        }
        guard size != record.size else { return }
        let placed = placements()[id]
        let screens = screens()
        guard let index = placed?.screen ?? WidgetPlacement.screenIndex(record.screen, screens: screens)?.index else {
            throw Failure("no display")
        }
        guard let g = widgetGrid(on: index) else { throw Failure("no display") }
        // The same top-left, at the new size, snapped again.
        let topLeft = placed?.snapped ?? record.frame(on: g, legacy: config().legacyGrid ?? .standard)
        let s = size.points()
        let here = g.snap(CGRect(x: topLeft.minX, y: topLeft.maxY - s.height, width: s.width, height: s.height))
        guard let at = g.nearestFree(size, near: here, occupied: occupied(on: index, except: id)) else {
            throw Failure("No room for a \(size.rawValue) \(type.title) on \(screens[index].name)")
        }
        c.instances[i].size = size
        c.instances[i].position = g.position(of: at)
        c.instances[i].legacyCell = nil
        commit(c, apps: [record.app])
    }

    func setLayer(_ id: String, _ layer: HUDWidgetLayer) throws {
        var c = config()
        guard let i = c.instances.firstIndex(where: { $0.instance == id }) else { throw Failure("no such widget \(id)") }
        guard c.instances[i].layer != layer else { return }
        c.instances[i].layer = layer
        commit(c, apps: [c.instances[i].app])
    }

    /// Merges `values` into a widget's settings (a nil value removes the key), checked
    /// against its type's schema. `done` gets the app's refusal, if any.
    func setSettings(_ id: String, _ values: [String: HUDSettingValue?], done: @escaping (Failure?) -> Void = { _ in }) throws {
        var c = config()
        guard let i = c.instances.firstIndex(where: { $0.instance == id }) else { throw Failure("no such widget \(id)") }
        let record = c.instances[i]
        let schema = type(app: record.app, type: record.type).flatMap(schema)
        var settings = record.settings ?? [:]
        for (key, value) in values {
            guard let value else { settings[key] = nil; continue }
            settings[key] = try Self.checked(key, value, schema: schema)
        }
        c.instances[i].settings = settings.isEmpty ? nil : settings
        commit(c, apps: [record.app]) { [weak self] failures in
            guard let self, let why = failures[id] else { done(nil); return }
            // The app refused: back to what it has.
            var c = self.config()
            if let j = c.instances.firstIndex(where: { $0.instance == id }) { c.instances[j].settings = record.settings }
            self.commit(c, apps: [record.app])
            done(Failure(why))
        }
    }

    /// A value typed and checked by the schema's field for `key`; kept as given when the
    /// schema does not list it.
    static func checked(_ key: String, _ value: HUDSettingValue, schema: HUDSettingsSchema?) throws -> HUDSettingValue {
        guard let field = schema?.field(key) else { return value }
        do { return try field.parse(value.wireString) } catch { throw Failure("\(error)") }
    }

    // MARK: - Loadouts

    /// The instances for a HUD loadout.
    func capture() -> [WidgetRecord] { records }

    /// Replaces every instance with `set` (a HUD loadout's). An instance of the same app and
    /// type at the same place keeps its id, so its window stays.
    func replace(with set: [WidgetRecord]) {
        var c = config()
        var current = c.instances
        var ids = Set<String>()
        var next: [WidgetRecord] = []
        for var record in set {
            if let i = current.firstIndex(where: { $0.samePlace(as: record) }) {
                record.instance = current.remove(at: i).instance
            }
            if ids.contains(record.instance) { record.instance = uniqueID(avoiding: ids) }
            ids.insert(record.instance)
            next.append(record)
        }
        c.instances = next
        commit(c)
    }

    // MARK: - Helpers

    private func uniqueID(avoiding extra: Set<String> = []) -> String {
        let taken = Set(records.map(\.instance)).union(extra)
        var id = newID()
        while taken.contains(id) { id = newID() }
        return id
    }

    /// A type by app (bundle id or name) and type id; without an app, the one app serving it.
    func findType(app key: String?, type typeID: String) throws -> WidgetType {
        if let key {
            guard let app = externals.app(matching: key) else { throw Failure("no app \(key)") }
            guard let t = type(app: app.id, type: typeID) else {
                let served = app.manifest.widgetPanels.map(\.id)
                throw Failure(served.isEmpty ? "\(app.name) serves no widgets"
                                             : "no widget type \(typeID) in \(app.name) (\(served.joined(separator: ", ")))")
            }
            return t
        }
        let matches = types().filter { $0.id == typeID }
        guard let first = matches.first else {
            throw Failure("no widget type \(typeID) (\(types().map(\.id).joined(separator: ", ")))")
        }
        guard matches.count == 1 else {
            throw Failure("\(typeID) is served by \(matches.map(\.app.name).joined(separator: " and ")); say app=")
        }
        return first
    }

    static func frameText(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { Self.number(Double($0)) }.joined(separator: ",")
    }

    static func number(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    /// Equal, counting a whole-number double and the same int as equal (`1.0` is saved as `1`
    /// and reads back as an int).
    static func sameSettings(_ a: [String: HUDSettingValue], _ b: [String: HUDSettingValue]) -> Bool {
        guard a.count == b.count else { return false }
        return a.allSatisfy { key, value in
            guard let other = b[key] else { return false }
            if value == other { return true }
            switch (value, other) {
            case (.int, .double), (.double, .int): return value.doubleValue == other.doubleValue
            default: return false
            }
        }
    }

    /// Within half a point: frames come back from the window server rounded.
    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    static func jsonText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
