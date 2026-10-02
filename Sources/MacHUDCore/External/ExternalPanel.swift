import AppKit
import HUDKit

/// A panel another MacHUD-aware app declares in its `machud.json`. Visibility and
/// cooperative placement go over that app's control socket (launching the app first if
/// needed); an app that is not listening is placed through Accessibility instead.
@MainActor
final class ExternalPanel: Panel {
    let app: ExternalApp
    let descriptor: HUDManifest.Panel
    unowned let supervisor: AppSupervisor

    init(app: ExternalApp, descriptor: HUDManifest.Panel, supervisor: AppSupervisor) {
        self.app = app
        self.descriptor = descriptor
        self.supervisor = supervisor
    }

    nonisolated static func id(app: String, panel: String) -> String { "\(app)/\(panel)" }

    var id: String { Self.id(app: app.id, panel: descriptor.id) }
    /// The id the owning app knows the panel by.
    var panelID: String { descriptor.id }
    var appID: String? { app.id }
    var title: String { descriptor.title }
    var symbol: String { descriptor.symbol ?? "app.dashed" }
    var window: NSWindow? { nil }

    /// Last state the app pushed (or that we just asked for).
    var state: HUDPanelState {
        supervisor.record(app.id)?.panels[descriptor.id] ?? HUDPanelState(id: descriptor.id, visible: false)
    }

    var isVisible: Bool { state.visible && health == .running }

    var health: AppSupervisor.Health { supervisor.record(app.id)?.health ?? .notRunning }

    /// Takes `panel frame`: the app is listening and the manifest does not rule the verb out.
    var isCooperative: Bool {
        health == .running && (descriptor.verbs.isEmpty || descriptor.verbs.contains("frame"))
    }

    /// Plain shows (`panel show`, a loadout slot) record a miss quietly: a loadout may place
    /// the panel on a desktop it is visiting. A HUD loadout sends its shows to the app
    /// directly, unverified.
    func show() { visibility("show", assume: true) }
    func hide() { visibility("hide", assume: false) }
    func toggle() { visibility("toggle", assume: !isVisible) }

    /// `panel show` with how to appear: `HUDPanelTransition.options` (`from=`, `anchor=`,
    /// `reason=`), so a panel can slide out of its dock button. `loud` (default: any reason
    /// but `hover`) reports a panel that did not reach the screen (see `verifyShow`).
    func show(_ transition: HUDPanelTransition, loud: Bool? = nil,
              completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        visibility("show", assume: true, loud: loud ?? (transition.reason != .hover), options: transition.options,
                   completion: completion)
    }
    /// `panel hide` with `to=` (and `anchor=`, `reason=`).
    func hide(_ transition: HUDPanelTransition) { visibility("hide", assume: false, options: transition.options) }

    /// A show the app accepted is checked against the window list once it has had time to
    /// appear, since an app can answer `visible: true` for a window on another desktop.
    private func visibility(_ verb: String, assume visible: Bool, loud: Bool = false, options: [String: String] = [:],
                            completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        supervisor.assume(app.id, panel: descriptor.id, visible: visible)
        let appID = app.id, panelID = descriptor.id, supervisor = supervisor
        send("panel", options.merging(["action": verb, "id": panelID]) { _, b in b }) { result in
            if visible, case .success(let reply) = result, reply["ok"] as? Bool != false {
                supervisor.verifyShow(appID, panel: panelID, loud: loud, hint: reply["onActiveSpace"] as? Bool)
            }
            completion?(result)
        }
    }

    /// Takes files dropped on its dock button (`acceptsFileDrop`).
    var acceptsFileDrop: Bool { descriptor.capabilities.contains(HUDDrop.capability) }

    /// `action drop paths=<HUDDrop.encode>` (plus `id=` when the app has several panels),
    /// launching the app first if needed.
    func drop(_ urls: [URL], completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        var args = HUDDrop.args(for: urls, panel: app.manifest.presentedPanels.count > 1 ? descriptor.id : nil)
        args["name"] = HUDDrop.action
        supervisor.send(app.id, command: "action", args: args, completion: completion)
    }

    func setMode(_ mode: HUDPanelMode, edge: HUDEdge? = nil, peek: CGFloat? = nil) {
        var args = ["action": "mode", "id": descriptor.id, "mode": mode.rawValue]
        if let edge { args["edge"] = edge.rawValue }
        if let peek { args["peek"] = "\(Double(peek))" }
        send("panel", args)
    }

    /// Cooperative apps get `panel frame` (Cocoa coordinates); anything else is moved by
    /// Accessibility. False when neither route is available right now.
    @discardableResult
    func place(in rect: CGRect) -> Bool {
        if isCooperative {
            send("panel", Self.frameArgs(panelID: descriptor.id, rect))
            return true
        }
        guard let window = axWindow() else { return false }
        if window.isMinimized { window.isMinimized = false }
        window.setCocoaFrame(rect)
        return true
    }

    /// `panel frame` over the socket whatever the app's state: queued until it listens,
    /// launching it if needed (the tool dock positions a panel before showing it).
    func requestFrame(_ rect: CGRect) {
        send("panel", Self.frameArgs(panelID: descriptor.id, rect))
    }

    static func frameArgs(panelID: String, _ rect: CGRect) -> [String: String] {
        ["action": "frame", "id": panelID, "x": "\(Double(rect.minX))", "y": "\(Double(rect.minY))",
         "w": "\(Double(rect.width))", "h": "\(Double(rect.height))"]
    }

    /// Where the panel's window is now: through Accessibility when allowed, else the
    /// largest on-screen window of the app. nil when neither finds one.
    var currentFrame: CGRect? {
        if Accessibility.isTrusted, let frame = axWindow()?.cocoaFrame { return frame }
        return windowFrames.first
    }

    /// The app's on-screen windows, largest first, minus its widgets MacHUD placed.
    var windowFrames: [CGRect] {
        let widgets = supervisor.widgetFrames(app.id)
        return WindowList.frames(pids: Set(supervisor.livePIDs(app.id)))
            .filter { frame in !widgets.contains { WindowPresence.sameFrame($0, frame) } }
    }

    private func send(_ command: String, _ args: [String: String],
                      completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        let id = self.id
        supervisor.send(app.id, command: command, args: args) { result in
            if case .failure(let error) = result { NSLog("MacHUD: %@ %@ failed: %@", id, command, "\(error)") }
            completion?(result)
        }
    }

    /// Launch the owning app without showing anything yet.
    func launchApp() { supervisor.launch(app.id) }

    /// The app's window for this panel: one titled like the panel, else its best window.
    func axWindow() -> AXWindow? {
        let widgets = supervisor.widgetFrames(app.id)
        for pid in supervisor.workspace.runningPIDs(bundleID: app.id) {
            let windows = AXWindow.all(pid: pid).filter { w in
                guard w.exists, w.isPlaceable else { return false }
                guard let frame = w.cocoaFrame else { return true }
                return !widgets.contains { WindowPresence.sameFrame($0, frame) }
            }
            if let titled = windows.first(where: { $0.title.caseInsensitiveCompare(descriptor.title) == .orderedSame }) {
                return titled
            }
            if let i = WindowMatch.choose(windows.map(\.candidate), titleMatch: nil) { return windows[i] }
        }
        return nil
    }

    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "visible": isVisible, "app": app.id,
                                "panel": descriptor.id, "mode": state.mode.rawValue, "health": health.rawValue,
                                "cooperative": isCooperative]
        if let badge = state.badge { d["badge"] = badge }
        if let status = state.status { d["status"] = status }
        if isVisible, let check = supervisor.record(app.id)?.showChecks[descriptor.id] {
            d["onScreen"] = check.isOnScreen
            if case .elsewhere(let place) = check { d["elsewhere"] = place }
        }
        let frames = windowFrames
        if !frames.isEmpty {
            d["frames"] = frames.map { ["x": Int($0.minX), "y": Int($0.minY), "w": Int($0.width), "h": Int($0.height)] }
        }
        return d
    }
}

/// How a loadout slot reaches an external panel. Pure, so it is unit tested.
enum ExternalPlacement: Equatable {
    /// `panel show` + `panel frame` over the socket.
    case socket
    /// Move the app's window by Accessibility.
    case ax
    /// Launch the app, then look again.
    case launch
    case wait
    case failed(String)

    /// - Parameters:
    ///   - socketGraceOver: the app has been up long enough that a missing socket means it
    ///     is not MacHUD-aware at runtime (or broken), so fall back to Accessibility.
    static func route(installed: Bool, health: AppSupervisor.Health, cooperative: Bool,
                      hasAXWindow: Bool, socketGraceOver: Bool) -> ExternalPlacement {
        switch health {
        case .notInstalled: return .failed("not installed")
        case .notRunning: return installed ? .launch : .failed("not installed")
        case .launching: return .wait
        case .running:
            if cooperative { return .socket }
            return hasAXWindow ? .ax : .wait
        case .socketUnreachable:
            return socketGraceOver && hasAXWindow ? .ax : .wait
        }
    }
}
