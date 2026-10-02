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

    /// `widgets [list]`, `widgets types`, `widgets add [app=] type= [size=] [screen=] [x= y= | col= row=]
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
                let position = try Self.position(args, grid: grid())
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
                add(app: args["app"], type: type, size: size, screen: screen, position: position, layer: layer, settings: settings) { [weak self] result in
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
                guard let position = try Self.position(args, grid: grid()) else { throw Failure("widgets move needs x= y= or col= row=") }
                let screen = try args["screen"].map { raw -> ScreenRef in
                    guard let ref = ScreenRef.parse(raw) else { throw Failure("screen must be main, builtin, a number or a name") }
                    return ref
                }
                let note = try move(id, to: position, screen: screen)
                var r: [String: Any] = ["ok": true, "instance": instanceJSON(id)]
                if let note { r["note"] = note }
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

    /// The layout grid widgets snap to.
    var gridJSON: [String: Any] {
        let g = grid()
        return ["cols": g.cols, "rows": g.rows]
    }

    /// `x`, `y` and the same in grid-line units (`col`, `row`).
    func positionJSON(_ p: WidgetGrid.Position) -> [String: Any] {
        let lines = WidgetGrid(visible: .zero, grid: grid()).lines(p)
        return ["x": p.x, "y": p.y, "col": Self.jsonNumber(lines.col), "row": Self.jsonNumber(lines.row)]
    }

    /// A whole number as an int, so `col` reads as `12`, not `12.0`.
    static func jsonNumber(_ d: Double) -> Any { d == d.rounded() && abs(d) < 1e9 ? Int(d) : d }

    /// One instance as `widgets list` shows it.
    func json(_ record: WidgetRecord, placed: WidgetPlacement.Placed? = nil, screens: [WidgetScreen]? = nil) -> [String: Any] {
        let screens = screens ?? self.screens()
        let placed = placed ?? placements()[record.instance]
        var d: [String: Any] = ["instance": record.instance, "app": record.app, "type": record.type,
                                "size": record.size.rawValue, "layer": record.layer.rawValue, "settings": record.settingsJSON]
        if record.legacyCell == nil { d.merge(positionJSON(record.position)) { a, _ in a } }
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
            if placed.moved { d["placedAt"] = positionJSON(placed.position) }
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

    /// A widget's top-left: `x= y=` as fractions (0 to 1) of the display's visible frame from
    /// its top-left corner, or `col= row=` as line indices of the layout grid (`grid` in
    /// layouts.json; col 0 to cols, row 0 to rows); nil for neither. Snapped and kept inside
    /// the display when placed.
    static func position(_ args: [String: String], grid: GridSize) throws -> WidgetGrid.Position? {
        let fractions = (args["x"], args["y"]), lines = (args["col"], args["row"])
        if fractions != (nil, nil), lines != (nil, nil) { throw Failure("give x= y= or col= row=, not both") }
        switch fractions {
        case (nil, nil): break
        case (let x?, let y?):
            guard let fx = Double(x), let fy = Double(y), (0...1).contains(fx), (0...1).contains(fy) else {
                throw Failure("x and y must be numbers from 0 to 1")
            }
            return WidgetGrid.Position(x: fx, y: fy)
        default: throw Failure("give both x= and y=")
        }
        switch lines {
        case (nil, nil): return nil
        case (let c?, let r?):
            let g = WidgetGrid(visible: .zero, grid: grid)
            guard let col = Double(c), let row = Double(r), col >= 0, row >= 0, col <= Double(g.cols), row <= Double(g.rows) else {
                throw Failure("col must be a grid line from 0 to \(g.cols) and row one from 0 to \(g.rows)")
            }
            return g.position(col: col, row: row)
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
