import AppKit
import HUDKit

/// The `widgets` socket verb and the JSON it answers with.
extension WidgetLayer {
    static let actions = ["list", "types", "add", "remove", "move", "resize", "layer", "settings", "edit", "reveal"]

    func registerControl(_ control: HUDSocketServer) {
        control.register("widgets") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            self.handle(args, done: done)
        }
    }

    /// `widgets [list]`, `widgets types`, `widgets add [app=] type= [size=] [screen=] [col= row=]
    /// [layer=] [settings=]`, `widgets remove|move|resize|layer|settings instance= …`,
    /// `widgets edit|reveal on|off|toggle`. A bare `widgets` lists; arguments without a sub-verb
    /// are an error, so a change that lost its sub-verb cannot pass for a list.
    func handle(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        func fail(_ error: Any) { done(["ok": false, "error": "\(error)"]) }
        let named = args["action"] ?? args["_"].flatMap { Self.actions.contains($0) ? $0 : nil }
        guard let action = named ?? (args.isEmpty ? "list" : nil) else {
            fail("widgets action must be one of \(Self.actions.joined(separator: ", "))")
            return
        }
        // The CLI's bare sub-verb arrives as `<word>=1`; it is not a value.
        var args = args
        if let word = args["_"], Self.actions.contains(word), args[word] == "1" { args[word] = nil }
        func instanceID() throws -> String {
            guard let id = args["instance"] ?? args["id"], !id.isEmpty else { throw Failure("widgets \(action) needs instance=") }
            guard record(id) != nil else { throw Failure("no such widget \(id)") }
            return id
        }
        do {
            switch action {
            case "list":
                done(["ok": true, "editing": editing, "revealed": revealed, "grid": gridJSON, "instances": listJSON()])
            case "types":
                done(["ok": true, "types": typesJSON()])
            case "add":
                guard let type = args["type"], !type.isEmpty else { throw Failure("widgets add needs type=") }
                let size = try args["size"].map(Self.size)
                let screen = try args["screen"].map { raw -> ScreenRef in
                    guard let ref = ScreenRef.parse(raw) else { throw Failure("screen must be main, builtin, a number or a name") }
                    return ref
                }
                let cell = try Self.cell(args)
                let layer = try args["layer"].map(Self.layer) ?? .desktop
                var settings: [String: HUDSettingValue] = [:]
                if let raw = args["settings"] {
                    let t = try findType(app: args["app"], type: type)
                    let s = schema(t)
                    for (key, value) in try Self.settingsObject(raw) {
                        guard let value else { continue }
                        settings[key] = try Self.checked(key, value, schema: s)
                    }
                }
                add(app: args["app"], type: type, size: size, screen: screen, cell: cell, layer: layer, settings: settings) { [weak self] result in
                    switch result {
                    case .failure(let error): fail(error)
                    case .success(let (record, note)):
                        var r: [String: Any] = ["ok": true, "instance": self?.json(record) ?? [:]]
                        if let note { r["note"] = note }
                        done(r)
                    }
                }
            case "remove":
                let id = try instanceID()
                try remove(id)
                done(["ok": true, "removed": id])
            case "move":
                let id = try instanceID()
                guard let cell = try Self.cell(args) else { throw Failure("widgets move needs col= and row=") }
                let screen = try args["screen"].map { raw -> ScreenRef in
                    guard let ref = ScreenRef.parse(raw) else { throw Failure("screen must be main, builtin, a number or a name") }
                    return ref
                }
                let (at, name) = try move(id, to: cell, screen: screen)
                var r: [String: Any] = ["ok": true, "instance": instanceJSON(id)]
                if at != cell { r["note"] = "\(cell) is taken; placed at \(at) on \(name)" }
                done(r)
            case "resize":
                let id = try instanceID()
                guard let raw = args["size"] else { throw Failure("widgets resize needs size=") }
                try resize(id, to: Self.size(raw))
                done(["ok": true, "instance": instanceJSON(id)])
            case "layer":
                let id = try instanceID()
                let raw = ["desktop", "float"].first { args[$0] != nil } ?? args["layer"] ?? args["state"]
                guard let raw else { throw Failure("widgets layer needs desktop or float") }
                try setLayer(id, Self.layer(raw))
                done(["ok": true, "instance": instanceJSON(id)])
            case "settings":
                let id = try instanceID()
                var values: [String: HUDSettingValue?] = [:]
                if let raw = args["settings"] { values = try Self.settingsObject(raw) }
                for (key, value) in args where !Self.reservedKeys.contains(key) && args["_"] != key { values[key] = .string(value) }
                guard !values.isEmpty else { done(["ok": true, "instance": instanceJSON(id)]); return }
                try setSettings(id, values) { [weak self] failure in
                    if let failure { fail(failure); return }
                    done(["ok": true, "instance": self?.instanceJSON(id) ?? [:]])
                }
            case "edit", "reveal":
                let current = action == "edit" ? editing : revealed
                let raw = args["state"] ?? ["on", "off", "toggle"].first { args[$0] != nil } ?? "toggle"
                let on: Bool
                switch raw.lowercased() {
                case "on", "true", "1", "yes": on = true
                case "off", "false", "0", "no": on = false
                case "toggle": on = !current
                default: throw Failure("widgets \(action) needs on, off or toggle")
                }
                if action == "edit" { setEditing(on) } else { setRevealed(on) }
                done(["ok": true, "editing": editing, "revealed": revealed])
            default:
                throw Failure("widgets action must be one of \(Self.actions.joined(separator: ", "))")
            }
        } catch {
            fail(error)
        }
    }

    /// Keys of `widgets settings` that are not settings.
    static let reservedKeys: Set<String> = ["action", "_", "instance", "id", "settings"]

    // MARK: - JSON

    var gridJSON: [String: Any] {
        let c = config()
        return ["cell": Double(c.cellSize), "gap": Double(c.gapSize), "margin": Double(c.marginSize)]
    }

    /// One instance as `widgets list` shows it.
    func json(_ record: WidgetRecord, placed: WidgetPlacement.Placed? = nil, screens: [WidgetScreen]? = nil) -> [String: Any] {
        let screens = screens ?? self.screens()
        let placed = placed ?? placements()[record.instance]
        var d: [String: Any] = ["instance": record.instance, "app": record.app, "type": record.type,
                                "size": record.size.rawValue, "layer": record.layer.rawValue,
                                "col": record.col, "row": record.row, "settings": record.settingsJSON]
        if let app = externals.app(matching: record.app) {
            d["appName"] = app.name
            d["health"] = supervisor.record(app.id)?.health.rawValue ?? "notRunning"
        } else {
            d["health"] = "notInstalled"
        }
        if let t = type(app: record.app, type: record.type) { d["title"] = t.title } else { d["missingType"] = true }
        if let screen = record.screen { d["screen"] = screen.label }
        if let placed {
            d["frame"] = HUDWidgetInstance.frameJSON(placed.frame)
            if screens.indices.contains(placed.screen) { d["display"] = screens[placed.screen].name }
            if placed.screenMissing { d["screenMissing"] = true }
            if placed.moved { d["placedAt"] = ["col": placed.cell.col, "row": placed.cell.row] }
            if placed.overlapping { d["overlapping"] = true }
        }
        if let problem = problems[record.instance] { d["problem"] = problem }
        if let dropped = droppedSettings[record.instance], !dropped.isEmpty { d["droppedSettings"] = dropped }
        return d
    }

    /// The instance by id as `widgets list` shows it; empty when it is gone.
    func instanceJSON(_ id: String) -> [String: Any] { record(id).map { json($0) } ?? [:] }

    func listJSON() -> [[String: Any]] {
        let placed = placements(), screens = screens()
        return records.map { json($0, placed: placed[$0.instance], screens: screens) }
    }

    func typesJSON() -> [[String: Any]] {
        types().map { t in
            var d: [String: Any] = ["app": t.app.id, "appName": t.app.name, "type": t.id, "title": t.title,
                                    "symbol": t.symbol, "sizes": t.spec.sizes.map(\.rawValue),
                                    "defaultSize": t.spec.defaultSize.rawValue, "multiple": t.spec.multiple,
                                    "placed": records.filter { $0.app == t.app.id && $0.type == t.id }.count]
            if let refresh = t.spec.refresh { d["refresh"] = refresh }
            if let schema = schema(t), let data = try? schema.encoded(),
               let object = try? JSONSerialization.jsonObject(with: data) { d["settingsSchema"] = object }
            return d
        }
    }

    // MARK: - Argument parsing

    static func size(_ raw: String) throws -> HUDWidgetSize {
        guard let size = HUDWidgetSize(rawValue: raw) else {
            throw Failure("size must be \(HUDWidgetSize.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return size
    }

    static func layer(_ raw: String) throws -> HUDWidgetLayer {
        guard let layer = HUDWidgetLayer(rawValue: raw.lowercased()) else { throw Failure("layer must be desktop or float") }
        return layer
    }

    /// `col=` and `row=` together, or neither.
    static func cell(_ args: [String: String]) throws -> WidgetGrid.Cell? {
        switch (args["col"], args["row"]) {
        case (nil, nil): return nil
        case (let c?, let r?):
            guard let col = Int(c), let row = Int(r), col >= 0, row >= 0 else { throw Failure("col and row must be whole numbers from 0") }
            return WidgetGrid.Cell(col: col, row: row)
        default: throw Failure("give both col= and row=")
        }
    }

    /// A JSON object of settings (`null` removes a key).
    static func settingsObject(_ raw: String) throws -> [String: HUDSettingValue?] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw Failure("settings must be a JSON object")
        }
        var out: [String: HUDSettingValue?] = [:]
        for (key, value) in object {
            if value is NSNull { out[key] = .some(nil); continue }
            guard let v = HUDSettingValue(any: value) else { throw Failure("\(key) must be a string, number or true/false") }
            out[key] = v
        }
        return out
    }
}
