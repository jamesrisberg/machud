import Foundation
import HUDKit

/// `tooldock`, `summon` and `dismiss` on the control socket.
extension ToolDock {
    func registerControl(_ control: HUDSocketServer) {
        control.register("tooldock") { [weak self] args, done in
            done(self?.handle(args) ?? ["ok": false, "error": "tool dock gone"])
        }
        control.register("summon") { [weak self] args, done in
            done(self?.handleSummon(args, summon: true) ?? ["ok": false, "error": "tool dock gone"])
        }
        control.register("dismiss") { [weak self] args, done in
            done(self?.handleSummon(args, summon: false) ?? ["ok": false, "error": "tool dock gone"])
        }
    }

    static let actions = ["state", "show", "hide", "toggle", "position", "autohide", "magnify", "click", "drop", "pointer", "mouse", "snapshot"]

    /// `tooldock [state|show|hide|toggle|position|autohide|magnify|click|drop|pointer|mouse|snapshot]`. `position`
    /// takes `position=` (one of the eight; `edge=` is accepted as the position of that
    /// edge), `screen=` (display name, empty for the main one) and `iconSize=`;
    /// `autohide`/`magnify` take `value=on|off` (default: flip); `click` takes `id=` (a
    /// button id: app bundle id or name, `parked`); `drop` takes `id=` and `paths=` (as
    /// `HUDDrop.encode`, or comma-separated plain paths) and drops them on that button;
    /// `pointer x= y=` makes the hover logic see the pointer there (`clear=1` follows the
    /// mouse again), for scripted checks; `mouse phase=move|down|drag|up x= y=` also sends the
    /// strip a synthesized mouse event there (tile hover for `move`, a press, its drag and its
    /// release through the window), so click-vs-drag can be checked without posting real
    /// events; `snapshot path=` writes the strip as a PNG (its glass
    /// drawn as a dark stand-in, as `HUDDockStripView.snapshot` does).
    func handle(_ args: [String: String]) -> [String: Any] {
        let action = args["action"] ?? args["_"] ?? Self.actions.first { args[$0] != nil } ?? "state"
        switch action {
        case "state":
            break
        case "show": setEnabled(true)
        case "hide": setEnabled(false)
        case "toggle": setEnabled(!config().isEnabled)
        case "position":
            var position: HUDDockPosition?
            if let raw = args["position"] ?? args["to"] {
                guard let p = Self.position(raw) else {
                    return ["ok": false, "error": "position must be one of \(HUDDockPosition.allCases.map(\.rawValue).joined(separator: ", "))"]
                }
                position = p
            } else if let raw = args["edge"] {
                guard let e = HUDEdge(rawValue: raw.lowercased()) else {
                    return ["ok": false, "error": "edge must be bottom, left, right or top"]
                }
                position = HUDDockPosition(edge: e)
            }
            if args["offset"] != nil {
                return ["ok": false, "error": "offset was removed: the dock is centred on its edge; use position= (8 positions)"]
            }
            var iconSize: Double?
            if let raw = args["iconSize"] ?? args["icon"] {
                guard let s = Double(raw), ToolDockConfig.iconSizeRange.contains(s) else {
                    return ["ok": false, "error": "iconSize must be from 24 to 96"]
                }
                iconSize = s
            }
            if position == nil, iconSize == nil, args["screen"] == nil {
                return ["ok": false, "error": "position takes position=, edge=, screen= or iconSize="]
            }
            self.position(position, screen: args["screen"], iconSize: iconSize)
        case "autohide", "magnify":
            let current = action == "autohide" ? config().isAutoHide : config().isMagnified
            guard let on = Self.flag(args["value"] ?? args["on"], default: !current) else {
                return ["ok": false, "error": "value must be on or off"]
            }
            if action == "autohide" { setAutoHide(on) } else { setMagnify(on) }
        case "click":
            guard let key = args["id"], let item = item(matching: key) else {
                return ["ok": false, "error": "id=<button id> required; see tooldock state"]
            }
            click(item, anchor: nil)
        case "snapshot":
            guard let path = args["path"], !path.isEmpty else { return ["ok": false, "error": "snapshot takes path=<png>"] }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard writeSnapshot(to: url) else { return ["ok": false, "error": "no dock on screen to snapshot"] }
            return ["ok": true, "path": url.path]
        case "pointer":
            if let x = args["x"].flatMap(Double.init), let y = args["y"].flatMap(Double.init) {
                pointerOverride = CGPoint(x: x, y: y)
            } else if args["clear"] != nil || args["value"] == "off" {
                pointerOverride = nil
            } else {
                return ["ok": false, "error": "pointer takes x= y= (screen points, origin bottom-left) or clear=1"]
            }
        case "mouse":
            guard let phase = args["phase"] ?? args["value"], let x = args["x"].flatMap(Double.init),
                  let y = args["y"].flatMap(Double.init) else {
                return ["ok": false, "error": "mouse takes phase=move|down|drag|up x= y= (Cocoa screen points)"]
            }
            if let error = simulateMouse(phase, at: CGPoint(x: x, y: y)) { return ["ok": false, "error": error] }
        case "drop":
            guard let key = args["id"], let item = item(matching: key) else {
                return ["ok": false, "error": "id=<button id> required; see tooldock state"]
            }
            let raw = args[HUDDrop.pathsKey] ?? ""
            let urls = raw.contains("|") || raw.contains("%") ? HUDDrop.decode(raw)
                : raw.split(separator: ",").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
            guard !urls.isEmpty else { return ["ok": false, "error": "paths= required"] }
            guard drop(urls, on: item.id) else { return ["ok": false, "error": "\(item.title) does not take files"] }
        default:
            return ["ok": false, "error": "tooldock action must be one of \(Self.actions.joined(separator: ", "))"]
        }
        return ["ok": true].merging(json) { a, _ in a }
    }

    /// `summon id=` / `dismiss id=`: a panel id (full or short) or an app's bundle id or
    /// name (its first panel).
    func handleSummon(_ args: [String: String], summon: Bool) -> [String: Any] {
        guard let key = args["id"] ?? args["name"], let panel = panel(matching: key) else {
            return ["ok": false, "error": "id=<panel id, app bundle id or name> required"]
        }
        let frame = summon ? self.summon(panel) : dismiss(panel)
        var d: [String: Any] = ["ok": true, "id": panel.id, "action": summon ? "summon" : "dismiss"]
        if let frame { d["frame"] = Self.rect(frame) }
        if let remembered = memory.frames[panel.id] { d["remembered"] = Self.rect(remembered) }
        return d
    }

    func panel(matching key: String) -> Panel? {
        if let panel = registry.panel(id: key) { return panel }
        guard let app = externals.app(matching: key), let first = app.manifest.panels.first else { return nil }
        return registry.panel(id: ExternalPanel.id(app: app.id, panel: first.id))
    }

    func item(matching key: String) -> ToolDockItem? {
        if let item = items.first(where: { $0.id == key }) { return item }
        if let app = externals.app(matching: key) { return items.first { $0.id == app.id } }
        return items.first { $0.title.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// A position name, case-insensitive, with or without a separator (`top-left`, `topleft`).
    static func position(_ raw: String) -> HUDDockPosition? {
        let key = raw.lowercased().filter { $0.isLetter }
        return HUDDockPosition.allCases.first { $0.rawValue.lowercased() == key }
    }

    static func flag(_ raw: String?, default value: Bool) -> Bool? {
        guard let raw else { return value }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}
