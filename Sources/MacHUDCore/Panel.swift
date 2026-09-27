import AppKit
import HUDKit

/// A tool MacHUD can show, hide and place. Most panels are windows MacHUD owns
/// (dock, dev servers, web pages); `ExternalPanel` is one declared by another
/// MacHUD-aware app's `machud.json` and driven over that app's control socket.
@MainActor
protocol Panel: AnyObject {
    /// Stable id used by `Occupant.panel(id:)` and the control socket. External panels
    /// use `<app bundle id>/<panel id>`.
    var id: String { get }
    var title: String { get }
    /// SF Symbol for menus.
    var symbol: String { get }
    /// The window, created lazily on first show. nil while never shown, and always nil
    /// for a panel that lives in another process.
    var window: NSWindow? { get }
    var isVisible: Bool { get }
    /// Bundle id of the app that owns the panel; nil for MacHUD's own panels.
    var appID: String? { get }

    func show()
    func hide()
    func toggle()
    /// Panel-specific menu items for the status bar submenu.
    func menuItems() -> [NSMenuItem]
}

extension Panel {
    var isVisible: Bool { window?.isVisible ?? false }
    var appID: String? { nil }
    func toggle() { isVisible ? hide() : show() }
    func menuItems() -> [NSMenuItem] { [] }
}

@MainActor
final class PanelRegistry {
    private(set) var panels: [Panel] = []

    /// Called (coalesced, on the main thread) whenever any panel's visibility changes,
    /// however it changed: socket, hotkey, menu, the window's close button, or an
    /// external app's pushed state. The app publishes a `state` event from it.
    var onStateChange: (() -> Void)?

    /// Reports whether one of MacHUD's own panels is parked (set by the HUD host), so a
    /// park or unpark reaches subscribers like a visibility change.
    var modeProvider: ((Panel) -> HUDPanelMode)?

    private var lastSnapshot: [String: String] = [:]
    private var refreshScheduled = false
    private var observers: [NSObjectProtocol] = []

    init() {
        // orderFront/orderOut/close/miniaturize all change a window's occlusion state,
        // which is the one notification every visibility change of our own windows posts.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow,
                          self.panels.contains(where: { $0.window === window }) else { return }
                    self.noteChange()
                }
            })
        }
    }

    func register(_ panel: Panel) {
        panels.removeAll { $0.id == panel.id }
        panels.append(panel)
        noteChange()
    }

    func unregister(where predicate: (Panel) -> Bool) {
        let before = panels.count
        panels.removeAll(where: predicate)
        if panels.count != before { noteChange() }
    }

    /// Exact id first; otherwise an external panel's short id (`portal` for
    /// `xyz.viawormhole.wormhole/portal`) when exactly one app declares it.
    func panel(id: String) -> Panel? {
        if let exact = panels.first(where: { $0.id == id }) { return exact }
        let short = panels.compactMap { $0 as? ExternalPanel }.filter { $0.panelID == id }
        return short.count == 1 ? short[0] : nil
    }

    /// Bundle ids of the apps whose panels are registered.
    var externalAppIDs: Set<String> { Set(panels.compactMap(\.appID)) }

    // MARK: - Visibility

    @discardableResult
    func show(_ id: String) -> Bool { act(id) { $0.show() } }
    @discardableResult
    func hide(_ id: String) -> Bool { act(id) { $0.hide() } }
    @discardableResult
    func toggle(_ id: String) -> Bool { act(id) { $0.toggle() } }

    private func act(_ id: String, _ body: (Panel) -> Void) -> Bool {
        guard let panel = panel(id: id) else { return false }
        body(panel)
        noteChange()
        return true
    }

    /// Schedules a visibility check for the next run-loop turn; repeated calls coalesce.
    func noteChange() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refreshState()
            }
        }
    }

    /// Fires `onStateChange` if any panel's state differs from the last check.
    func refreshState() {
        let snapshot = Dictionary(panels.map { ($0.id, stateKey($0)) }, uniquingKeysWith: { a, _ in a })
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onStateChange?()
    }

    /// Visibility, plus mode/badge/status for external panels (they report those too).
    private func stateKey(_ panel: Panel) -> String {
        guard let external = panel as? ExternalPanel else {
            return "\(panel.isVisible ? 1 : 0)|\(modeProvider?(panel).rawValue ?? "full")"
        }
        let s = external.state
        return "\(s.visible ? 1 : 0)|\(s.mode.rawValue)|\(s.badge ?? "")|\(s.status ?? "")"
    }
}
