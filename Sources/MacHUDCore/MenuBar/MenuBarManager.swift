import AppKit
import HUDKit

/// The two status items menu bar management owns: an expander (click to toggle, hover to
/// peek) and a separator to its left. Collapsing stretches the separator so every item left
/// of it is pushed off the menu bar. Abstracted so tests never touch the real menu bar.
@MainActor
protocol MenuBarItems: AnyObject {
    var isInstalled: Bool { get }
    func install()
    func remove()
    /// true stretches the separator (items left of it leave the menu bar).
    func setHidden(_ hidden: Bool)
    /// false when the user dragged the separator right of the expander: stretching it then
    /// would push the expander off too, with no way back but the hotkey or socket.
    var separatorIsLeftOfExpander: Bool { get }
    /// The expander's frame in screen coordinates, once laid out.
    var expanderFrame: CGRect? { get }
    /// Click on the expander; `true` for a right (or control) click.
    var onExpanderClick: ((Bool) -> Void)? { get set }
    func popUpMenu(_ menu: NSMenu)
    /// Where the items are, for `menubar state` (diagnostics only).
    var diagnostics: [String: Any] { get }
}

/// Where the mouse is and whether a menu is open, read by the poll.
@MainActor
protocol MenuBarProbe {
    var mouse: CGPoint { get }
    func isInMenuBar(_ point: CGPoint) -> Bool
    /// Any app's menu is showing (a status item's menu, an app menu, MacHUD's own).
    func anyMenuOpen() -> Bool
}

/// A repeating poll the manager can stop.
@MainActor
protocol MenuBarTicker: AnyObject { func invalidate() }
extension Timer: MenuBarTicker {}

/// Menu bar management (the Hidden Bar approach, public API only): owns the state machine,
/// the status items, the hotkey, the `menubar` socket verb, the status-menu submenu and the
/// `menubar` panel (compact = collapsed, full = expanded, visible = enabled).
@MainActor
final class MenuBarManager: NSObject {
    static let panelID = "menubar"
    /// A socket `peek` without `seconds=` stays up at least this long.
    nonisolated static let defaultPeekHold: TimeInterval = 3
    static let autoCollapseChoices: [Double] = [0, 5, 10, 30, 60]
    private static let pollInterval: TimeInterval = 1.0 / 20
    private static let menuProbeInterval: TimeInterval = 0.25

    private(set) var state = MenuBarState()
    private(set) var config = MenuBarConfig()
    private var hotkeys: Hotkeys?
    private let items: MenuBarItems
    private let probe: MenuBarProbe
    private let now: () -> TimeInterval
    private let makeTicker: (@escaping @MainActor () -> Void) -> MenuBarTicker
    private var ticker: MenuBarTicker?
    private var lastMenuProbe = -Double.infinity
    private var otherMenuOpen = false

    /// Registers a hotkey and returns an id for `unregisterHotkey`; nil = no hotkeys.
    var registerHotkey: ((HotKey, @escaping () -> Void) -> UInt32?)?
    var unregisterHotkey: ((UInt32) -> Void)?
    private var hotkeyRegistration: (key: HotKey, id: UInt32)?
    /// Saves a changed config (the app writes layouts.json, which calls `configure` back).
    var persist: ((MenuBarConfig) -> Void)?
    /// Enabled, mode or visibility changed (the app publishes panel state from it).
    var onChange: (() -> Void)?

    init(items: MenuBarItems, probe: MenuBarProbe,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeTicker: ((@escaping @MainActor () -> Void) -> MenuBarTicker)? = nil) {
        self.items = items
        self.probe = probe
        self.now = now
        self.makeTicker = makeTicker ?? { tick in
            let t = Timer(timeInterval: MenuBarManager.pollInterval, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            // .common so it keeps running while a menu is tracking.
            RunLoop.main.add(t, forMode: .common)
            return t
        }
        super.init()
        items.onExpanderClick = { [weak self] right in self?.expanderClicked(rightClick: right) }
    }

    var isEnabled: Bool { config.isEnabled }
    /// The `menubar` panel's mode.
    var panelMode: HUDPanelMode { state.mode == .collapsed ? .compact : .full }

    // MARK: - Config

    /// Applies a (re)loaded config: installs or removes the items, updates the hotkey.
    func configure(_ config: MenuBarConfig, hotkeys: Hotkeys?) {
        let wasEnabled = isEnabled
        self.config = config
        self.hotkeys = hotkeys
        state.autoCollapseSeconds = config.autoCollapse
        if config.isEnabled, !wasEnabled || !items.isInstalled {
            if !items.isInstalled { items.install() }
            state = MenuBarState(mode: .expanded, autoCollapseSeconds: config.autoCollapse)
            _ = state.expand(now: now())
            items.setHidden(false)
            startPolling()
        } else if !config.isEnabled, wasEnabled || items.isInstalled {
            // Never leave items stranded off the menu bar.
            items.setHidden(false)
            items.remove()
            stopPolling()
            state = MenuBarState(mode: .expanded, autoCollapseSeconds: config.autoCollapse)
        }
        updateHotkey()
        if wasEnabled != isEnabled { onChange?() }
    }

    func setEnabled(_ on: Bool) { update { $0.enabled = on } }
    func setAutoCollapse(_ seconds: Double) { update { $0.autoCollapseSeconds = max(0, seconds) } }

    private func update(_ change: (inout MenuBarConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        configure(c, hotkeys: hotkeys)
        persist?(c)
    }

    private func updateHotkey() {
        let wanted = isEnabled ? config.effectiveHotkey(hotkeys: hotkeys) : nil
        if hotkeyRegistration?.key == wanted { return }
        if let reg = hotkeyRegistration { unregisterHotkey?(reg.id) }
        hotkeyRegistration = nil
        guard let wanted, let register = registerHotkey,
              let id = register(wanted, { [weak self] in
                  MainActor.assumeIsolated { self?.hotkeyPressed() }
              }) else { return }
        hotkeyRegistration = (wanted, id)
    }

    /// The hotkey currently registered, if any.
    var activeHotkey: HotKey? { hotkeyRegistration?.key }

    // MARK: - Commands

    enum Failure: Error, CustomStringConvertible {
        case disabled, separatorMisplaced
        var description: String {
            switch self {
            case .disabled:
                return "menu bar management is off (settings set menuBar.enabled=1, or menubar enable)"
            case .separatorMisplaced:
                return "the separator is right of the expander; ⌘-drag it to the left of the expander first"
            }
        }
    }

    func expand() throws {
        guard isEnabled else { throw Failure.disabled }
        apply(state.expand(now: now()))
    }

    func collapse(onExpander: Bool = false) throws {
        guard isEnabled else { throw Failure.disabled }
        guard items.separatorIsLeftOfExpander else { throw Failure.separatorMisplaced }
        apply(state.collapse(now: now(), onExpander: onExpander))
    }

    func toggle(onExpander: Bool = false) throws {
        if state.mode == .expanded { try collapse(onExpander: onExpander) } else { try expand() }
    }

    func peek(hold: TimeInterval = MenuBarManager.defaultPeekHold) throws {
        guard isEnabled else { throw Failure.disabled }
        apply(state.peek(now: now(), hold: hold))
    }

    func hotkeyPressed() { try? toggle() }

    private func expanderClicked(rightClick: Bool) {
        if rightClick || NSApp?.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            for item in submenuItems() { menu.addItem(item) }
            items.popUpMenu(menu)
            return
        }
        do { try toggle(onExpander: true) } catch {
            Toast.show("Menu bar", detail: "\(error)")
        }
    }

    private func apply(_ effect: MenuBarState.Effect?) {
        guard let effect else { return }
        items.setHidden(effect == .hide)
        onChange?()
    }

    // MARK: - Poll

    private func startPolling() {
        guard ticker == nil else { return }
        ticker = makeTicker { [weak self] in self?.tick() }
    }

    private func stopPolling() {
        ticker?.invalidate()
        ticker = nil
    }

    /// One poll: menu state (throttled, only while the items show), then hover and timers.
    func tick() {
        guard isEnabled else { return }
        let t = now()
        if !state.itemsVisible {
            otherMenuOpen = false
        } else if t - lastMenuProbe >= Self.menuProbeInterval {
            otherMenuOpen = probe.anyMenuOpen()
            lastMenuProbe = t
        }
        state.setMenuOpen(otherMenuOpen, now: t)
        let mouse = probe.mouse
        let onExpander = items.expanderFrame?.insetBy(dx: -1, dy: -1).contains(mouse) ?? false
        let effect = state.update(onExpander: onExpander, inBar: probe.isInMenuBar(mouse), now: t)
        if effect == .hide, !items.separatorIsLeftOfExpander {
            // Collapsing now would hide the expander itself: stay expanded.
            _ = state.expand(now: t)
            return
        }
        apply(effect)
    }

    // MARK: - Reporting

    var json: [String: Any] {
        var d: [String: Any] = [
            "enabled": isEnabled, "mode": state.mode.rawValue, "itemsVisible": state.itemsVisible,
            "autoCollapseSeconds": config.autoCollapse, "menuOpen": state.menuOpen,
            "installed": items.isInstalled,
        ]
        if isEnabled {
            d["separatorLeftOfExpander"] = items.separatorIsLeftOfExpander
            d["items"] = items.diagnostics
        }
        if let hk = config.effectiveHotkey(hotkeys: hotkeys) { d["hotkey"] = hk.display }
        if let deadline = state.autoCollapseDeadline { d["autoCollapseIn"] = max(0, deadline - now()) }
        return d
    }

    // MARK: - Socket

    static let verbs = ["state", "collapse", "expand", "toggle", "peek", "enable", "disable"]

    /// `menubar state|collapse|expand|toggle|peek [seconds=]|enable|disable` (bare verb, `_`,
    /// or `action=`).
    func handle(_ args: [String: String]) -> [String: Any] {
        let action = args["action"] ?? args["_"] ?? Self.verbs.first { args[$0] != nil } ?? "state"
        do {
            switch action {
            case "state": break
            case "collapse": try collapse()
            case "expand": try expand()
            case "toggle": try toggle()
            case "peek":
                let hold = args["seconds"].flatMap(Double.init) ?? Self.defaultPeekHold
                try peek(hold: max(0, hold))
            case "enable": setEnabled(true)
            case "disable": setEnabled(false)
            default:
                return ["ok": false, "error": "menubar action must be one of \(Self.verbs.joined(separator: ", "))"]
            }
        } catch {
            var reply = json
            reply["ok"] = false
            reply["error"] = "\(error)"
            return reply
        }
        var reply = json
        reply["ok"] = true
        return reply
    }

    func registerControl(_ control: HUDSocketServer) {
        control.register("menubar") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "menu bar manager gone"]); return }
            done(self.handle(args))
        }
    }

    // MARK: - Status menu

    /// The "Menu Bar" submenu for MacHUD's status menu.
    func menuItems() -> [NSMenuItem] {
        let root = NSMenuItem(title: "Menu Bar", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for item in submenuItems() { sub.addItem(item) }
        root.submenu = sub
        return [root]
    }

    private func submenuItems() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        let enable = NSMenuItem(title: "Hide Menu Bar Items", action: #selector(menuToggleEnabled), keyEquivalent: "")
        enable.target = self
        enable.state = isEnabled ? .on : .off
        out.append(enable)

        let collapsed = state.mode == .collapsed
        var title = collapsed ? "Expand" : "Collapse"
        if let hk = activeHotkey { title += "  (\(hk.display))" }
        let flip = NSMenuItem(title: title, action: isEnabled ? #selector(menuToggleCollapse) : nil, keyEquivalent: "")
        flip.target = self
        flip.isEnabled = isEnabled
        out.append(flip)

        let auto = NSMenuItem(title: "Auto-collapse", action: nil, keyEquivalent: "")
        let autoMenu = NSMenu()
        var choices = Self.autoCollapseChoices
        if !choices.contains(config.autoCollapse) { choices.append(config.autoCollapse); choices.sort() }
        for seconds in choices {
            let label = seconds == 0 ? "Never" : seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
                ? "After \(Int(seconds / 60)) min" : "After \(Int(seconds)) s"
            let mi = NSMenuItem(title: label, action: #selector(menuSetAutoCollapse(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = seconds
            mi.state = seconds == config.autoCollapse ? .on : .off
            autoMenu.addItem(mi)
        }
        auto.submenu = autoMenu
        out.append(auto)

        out.append(.separator())
        let hint = NSMenuItem(title: "⌘-drag items left of the │ separator to hide them", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        out.append(hint)
        return out
    }

    @objc private func menuToggleEnabled() { setEnabled(!isEnabled) }
    @objc private func menuToggleCollapse() {
        do { try toggle() } catch { Toast.show("Menu bar", detail: "\(error)") }
    }
    @objc private func menuSetAutoCollapse(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        setAutoCollapse(seconds)
    }
}

/// The manager as a panel: `menubar` in `panels`/`state`, driven with `panel mode
/// compact|full id=menubar` and `panel show|hide` (enable/disable), and usable as a loadout
/// occupant (a parked slot collapses, a placed one expands).
@MainActor
final class MenuBarPanel: Panel {
    let id = MenuBarManager.panelID
    let title = "Menu Bar"
    let symbol = "menubar.rectangle"
    var window: NSWindow? { nil }
    unowned let manager: MenuBarManager

    init(manager: MenuBarManager) { self.manager = manager }

    var isVisible: Bool { manager.isEnabled }
    func show() { manager.setEnabled(true) }
    func hide() { manager.setEnabled(false) }
    func toggle() { manager.setEnabled(!manager.isEnabled) }
    var mode: HUDPanelMode { manager.panelMode }

    func setMode(_ mode: HUDPanelMode) throws {
        switch mode {
        case .compact: try manager.collapse()
        case .full: try manager.expand()
        case .parked: throw HUDControlError.unsupported("menubar has no parked mode; use compact to collapse")
        }
    }
}
