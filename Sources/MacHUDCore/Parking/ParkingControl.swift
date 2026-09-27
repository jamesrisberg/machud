import AppKit
import HUDKit

/// Socket commands for parking and the orb:
///
/// | command | args |
/// |---|---|
/// | `park` | `id=<slot region id/name/index or window number>` or `window=<number>` or `app=<bundle id or name> [title=<regex>]`, plus `edge=left/right/top/bottom` and `peek=<points>` |
/// | `park list` | parked windows and orbs |
/// | `park restore` | put every parked window back |
/// | `park reveal [edge=] [pin=1]` / `park conceal [edge=]` | what hovering / leaving the orb does |
/// | `unpark [id=]` | un-park one (or every) window for good |
/// | `orb show/hide` / `orb position x= y= [edge=]` / `orb` | orb visibility, placement, state |
extension LoadoutEngine {
    func registerParkingControl(_ control: ControlServer) {
        control.register("park") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            self.handlePark(args, done: done)
        }
        control.register("unpark") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            done(["ok": true, "unparked": self.parking.unpark(id: args["id"])])
        }
        control.register("orb") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            self.handleOrb(args, done: done)
        }
    }

    private func handlePark(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        let edge = args["edge"].flatMap(HUDEdge.init(rawValue:))
        if args["edge"] != nil, edge == nil { done(["ok": false, "error": "edge must be left, right, top or bottom"]); return }
        if args["list"] != nil {
            done(["ok": true, "parked": parking.parked.map(\.json), "orbs": parking.orbJSON(),
                  "orbsHidden": parking.orbsHidden])
            return
        }
        if args["restore"] != nil { done(["ok": true, "restored": parking.restoreAll(animated: true)]); return }
        if args["reveal"] != nil {
            let pin = ["1", "true", "yes"].contains((args["pin"] ?? "0").lowercased())
            done(["ok": true, "revealed": parking.reveal(edge: edge, pin: pin)]); return
        }
        if args["conceal"] != nil { done(["ok": true, "concealed": parking.conceal(edge: edge)]); return }

        switch parkTarget(args) {
        case .failure(let message):
            done(["ok": false, "error": message.text])
        case .success(let found):
            let rest = found.rest
            let screen = NSScreen.screens.max { $0.frame.intersection(rest).area < $1.frame.intersection(rest).area }
            let foreign: Bool
            if case .ax = found.target { foreign = true } else { foreign = false }
            let chosenEdge = edge ?? found.slot?.edge
                ?? ParkGeometry.nearestEdge(for: rest, in: screen?.frame ?? rest, allowTop: !foreign)
            let peek = args["peek"].flatMap(Double.init).map { CGFloat($0) } ?? found.slot?.parkPeek ?? 0
            let entry = parking.park(found.target, id: found.id, label: found.label, rest: rest, edge: chosenEdge,
                                     peek: peek, screen: screen)
            // Answer once the slide is over, so the reply shows where the window ended up.
            DispatchQueue.main.asyncAfter(deadline: .now() + HUDAnimation.concealDuration + 0.15) {
                MainActor.assumeIsolated { done(["ok": true, "parked": entry.json]) }
            }
        }
    }

    struct Message: Error { var text: String }

    private struct ParkTarget {
        var target: ParkingController.Target
        var id: String
        var label: String
        var rest: CGRect
        var slot: Slot?
    }

    private func parkTarget(_ args: [String: String]) -> Result<ParkTarget, Message> {
        if let id = args["id"], Int(id) == nil {
            return slotTarget(id)
        }
        if let number = (args["id"] ?? args["window"]).flatMap({ Int($0) }) {
            guard let info = windows().first(where: { $0.windowNumber == number }) else {
                return .failure(Message(text: "no window \(number)"))
            }
            return windowTarget(info)
        }
        if let app = args["app"] {
            let pattern = args["title"].flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
            let info = windows().first { w in
                guard w.bundleID?.caseInsensitiveCompare(app) == .orderedSame
                        || w.appName.caseInsensitiveCompare(app) == .orderedSame else { return false }
                guard let pattern else { return true }
                return pattern.firstMatch(in: w.title, range: NSRange(w.title.startIndex..., in: w.title)) != nil
            }
            guard let info else { return .failure(Message(text: "no window of \(app)")) }
            return windowTarget(info)
        }
        return .failure(Message(text: "park needs id=, window= or app= (or list, restore, reveal, conceal)"))
    }

    /// A slot of the active layout: the window sitting in its region, resting there.
    private func slotTarget(_ key: String) -> Result<ParkTarget, Message> {
        guard let regionID = regionID(matching: key) else { return .failure(Message(text: "no region \(key)")) }
        guard let region = status().first(where: { $0.regionID == regionID }) else {
            return .failure(Message(text: "no region \(key)"))
        }
        let slot = activeLoadout.flatMap { store.loadout(named: $0) }?.allSlots.first { $0.regionID == regionID }
        // A HUDKit app's panel parks itself; it may not even show up as a window we can see.
        if case .panel(let panelID)? = slot?.occupant, let target = parking.cooperativeTarget(panelID) {
            return .success(ParkTarget(target: target, id: regionID, label: panels.panel(id: panelID)?.title ?? panelID,
                                       rest: region.frame, slot: slot))
        }
        guard let info = region.window else { return .failure(Message(text: "nothing in region \(key)")) }
        switch windowTarget(info) {
        case .success(var found):
            found.id = regionID
            found.rest = region.frame
            found.slot = slot
            return .success(found)
        case .failure(let message):
            return .failure(message)
        }
    }

    private func windowTarget(_ info: WindowInfo) -> Result<ParkTarget, Message> {
        let label = info.title.isEmpty ? info.appName : "\(info.appName) · \(info.title)"
        let id = "w\(info.windowNumber)"
        if info.pid == getpid() {
            guard let window = panels.panels.first(where: { $0.window?.windowNumber == info.windowNumber })?.window else {
                return .failure(Message(text: "window is not placeable"))
            }
            return .success(ParkTarget(target: .own(window), id: id, label: label, rest: window.frame))
        }
        guard let window = axWindow(for: info) else { return .failure(Message(text: "window is not placeable")) }
        return .success(ParkTarget(target: .ax(window), id: id, label: label, rest: window.cocoaFrame ?? info.frame))
    }

    /// The radial menu's park wedge: the frontmost app's focused window goes to its
    /// nearest edge. Returns why it could not, if it could not.
    /// The frontmost app's focused window: what the Park wedge parks.
    func focusedWindow() -> (app: NSRunningApplication, window: AXWindow)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard let focused = element.elementAttribute(kAXFocusedWindowAttribute) else { return nil }
        return (app, AXWindow(element: focused, pid: app.processIdentifier))
    }

    /// "Safari · Page title", or nil when there is nothing Park could park.
    func focusedWindowLabel() -> String? {
        guard let (app, window) = focusedWindow(), window.isPlaceable else { return nil }
        let title = window.title
        let name = app.localizedName ?? "window"
        return title.isEmpty ? name : "\(name) · \(title)"
    }

    func parkFocusedWindow() -> String? {
        guard let (app, window) = focusedWindow() else { return "no focused window" }
        guard window.isPlaceable, let rest = window.cocoaFrame else { return "window is not placeable" }
        let screen = NSScreen.screens.max { $0.frame.intersection(rest).area < $1.frame.intersection(rest).area }
        let number = WindowList.onScreen().first {
            $0.pid == app.processIdentifier && Geometry.matches($0.frame, rest, tolerance: 3)
        }?.number
        let title = window.title
        parking.park(.ax(window), id: number.map { "w\($0)" } ?? "w-\(app.processIdentifier)-\(title)",
                     label: title.isEmpty ? (app.localizedName ?? "window") : "\(app.localizedName ?? "") · \(title)",
                     rest: rest, edge: ParkGeometry.nearestEdge(for: rest, in: screen?.frame ?? rest, allowTop: false),
                     peek: 0, screen: screen)
        return nil
    }

    private func handleOrb(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        if args["show"] != nil { parking.setOrbsHidden(false) }
        if args["hide"] != nil { parking.setOrbsHidden(true) }
        if args["position"] != nil || args["x"] != nil {
            guard let x = args["x"].flatMap(Double.init), let y = args["y"].flatMap(Double.init) else {
                done(["ok": false, "error": "orb position needs x= y="]); return
            }
            let edge = args["edge"].flatMap(HUDEdge.init(rawValue:))
            let edges = edge.map { [$0] } ?? parking.parked.map(\.record.edge)
            guard let first = edges.first else { done(["ok": false, "error": "no orb (nothing parked); pass edge="]); return }
            parking.setOrbOrigin(CGPoint(x: x, y: y), edge: first)
        }
        done(["ok": true, "hidden": parking.orbsHidden, "orbs": parking.orbJSON()])
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
