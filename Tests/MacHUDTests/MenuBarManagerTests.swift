import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

// MARK: - Settings

final class MenuBarSettingsTests: XCTestCase {
    @MainActor
    func testSettingsReadAndWriteTheMenuBarBlock() throws {
        var config = Config.defaults
        var values = MacHUDSettings.values(config: config, enabled: true, orbsHidden: false)
        XCTAssertEqual(values["menuBar.enabled"] as? Bool, false)
        XCTAssertEqual(values["menuBar.autoCollapseSeconds"] as? Int, 10)
        let parsed = try MacHUDSettings.schema.validate(["menuBar.enabled": "1", "menuBar.autoCollapseSeconds": "30"])
        config = MacHUDSettings.applying(parsed, to: config)
        XCTAssertEqual(config.menuBar, MenuBarConfig(enabled: true, autoCollapseSeconds: 30))
        values = MacHUDSettings.values(config: config, enabled: true, orbsHidden: false)
        XCTAssertEqual(values["menuBar.enabled"] as? Bool, true)
        XCTAssertEqual(values["menuBar.autoCollapseSeconds"] as? Int, 30)
    }
}

// MARK: - Manager, socket verbs, panel

@MainActor
final class FakeMenuBarItems: MenuBarItems {
    var isInstalled = false
    var hidden = false
    var installs = 0
    var separatorIsLeftOfExpander = true
    var expanderFrame: CGRect? = CGRect(x: 1000, y: 875, width: 24, height: 25)
    var onExpanderClick: ((Bool) -> Void)?
    var poppedUp = 0
    var diagnostics: [String: Any] { [:] }
    func install() { isInstalled = true; installs += 1 }
    func remove() { isInstalled = false }
    func setHidden(_ hidden: Bool) { self.hidden = hidden }
    func popUpMenu(_ menu: NSMenu) { poppedUp += 1 }
}

@MainActor
final class FakeMenuBarProbe: MenuBarProbe {
    var mouse = CGPoint(x: 500, y: 400)
    var menuOpen = false
    func isInMenuBar(_ point: CGPoint) -> Bool { point.y >= 875 }
    func anyMenuOpen() -> Bool { menuOpen }
}

@MainActor
final class FakeTicker: MenuBarTicker {
    var valid = true
    func invalidate() { valid = false }
}

@MainActor
final class MenuBarManagerTests: XCTestCase {
    private var items: FakeMenuBarItems!
    private var probe: FakeMenuBarProbe!
    private var clock: TimeInterval = 1000
    private var tickers: [FakeTicker] = []
    private var tick: (() -> Void)?
    private var manager: MenuBarManager!
    private var registered: [HotKey] = []
    private var unregistered: [UInt32] = []
    private var pressed: [() -> Void] = []
    private var persisted: [MenuBarConfig] = []

    override func setUp() {
        items = FakeMenuBarItems()
        probe = FakeMenuBarProbe()
        manager = MenuBarManager(items: items, probe: probe, now: { [unowned self] in self.clock }) { [unowned self] work in
            self.tick = work
            let t = FakeTicker()
            self.tickers.append(t)
            return t
        }
        manager.registerHotkey = { [unowned self] hk, press in
            self.registered.append(hk)
            self.pressed.append(press)
            return UInt32(self.registered.count)
        }
        manager.unregisterHotkey = { [unowned self] in self.unregistered.append($0) }
        manager.persist = { [unowned self] in self.persisted.append($0) }
    }

    private func advance(_ seconds: TimeInterval, step: TimeInterval = 0.05) {
        let end = clock + seconds
        while clock < end - 1e-9 {
            clock = min(end, clock + step)
            tick?()
        }
    }

    private func enable(autoCollapse: Double = 0) {
        manager.configure(MenuBarConfig(enabled: true, autoCollapseSeconds: autoCollapse), hotkeys: nil)
    }

    func testDisabledByDefaultInstallsNothingAndRefusesCommands() {
        manager.configure(MenuBarConfig(), hotkeys: nil)
        XCTAssertFalse(items.isInstalled)
        XCTAssertTrue(registered.isEmpty, "no hotkey while off")
        let reply = manager.handle(["_": "collapse", "collapse": "1"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue((reply["error"] as? String ?? "").contains("menuBar.enabled"))
    }

    func testEnableInstallsItemsPollerAndHotkeyThenDisableRemovesAndShowsEverything() {
        enable()
        XCTAssertTrue(items.isInstalled)
        XCTAssertEqual(registered, [MenuBarConfig.defaultHotkey])
        XCTAssertEqual(tickers.count, 1)
        try? manager.collapse()
        XCTAssertTrue(items.hidden)
        manager.configure(MenuBarConfig(enabled: false), hotkeys: nil)
        XCTAssertFalse(items.isInstalled)
        XCTAssertFalse(items.hidden, "nothing stays pushed off the menu bar")
        XCTAssertFalse(tickers[0].valid)
        XCTAssertEqual(unregistered, [1])
        XCTAssertEqual(manager.state.mode, .expanded)
    }

    func testReconfiguringWithTheSameConfigKeepsState() {
        enable()
        try? manager.collapse()
        enable()
        XCTAssertEqual(manager.state.mode, .collapsed, "a layouts.json reload must not expand")
        XCTAssertEqual(items.installs, 1)
        XCTAssertEqual(registered.count, 1)
    }

    func testHotkeyChangeReregisters() {
        enable()
        manager.configure(MenuBarConfig(enabled: true, hotkey: HotKey(key: "k", modifiers: ["control"])), hotkeys: nil)
        XCTAssertEqual(registered.last?.key, "k")
        XCTAssertEqual(unregistered, [1])
    }

    func testHotkeyPressTogglesCollapse() {
        enable()
        pressed.last?()
        XCTAssertEqual(manager.state.mode, .collapsed)
        XCTAssertTrue(items.hidden)
        pressed.last?()
        XCTAssertEqual(manager.state.mode, .expanded)
        XCTAssertFalse(items.hidden)
    }

    func testSocketVerbs() {
        enable()
        var reply = manager.handle(["_": "state"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["mode"] as? String, "expanded")
        XCTAssertEqual(reply["hotkey"] as? String, "⌃⌥B")

        reply = manager.handle(["collapse": "1", "_": "collapse"])
        XCTAssertEqual(reply["mode"] as? String, "collapsed")
        XCTAssertEqual(reply["itemsVisible"] as? Bool, false)
        XCTAssertTrue(items.hidden)

        reply = manager.handle(["action": "peek", "seconds": "2"])
        XCTAssertEqual(reply["mode"] as? String, "peeking")
        XCTAssertFalse(items.hidden)
        advance(2.0)
        XCTAssertEqual(manager.state.mode, .peeking, "held for its seconds")
        advance(0.7)
        XCTAssertEqual(manager.state.mode, .collapsed)
        XCTAssertTrue(items.hidden)

        reply = manager.handle(["expand": "1"])
        XCTAssertEqual(reply["mode"] as? String, "expanded")
        reply = manager.handle(["toggle": "1"])
        XCTAssertEqual(reply["mode"] as? String, "collapsed")
        reply = manager.handle(["_": "bogus"])
        XCTAssertEqual(reply["ok"] as? Bool, false)

        reply = manager.handle(["_": "disable"])
        XCTAssertEqual(reply["enabled"] as? Bool, false)
        XCTAssertEqual(persisted.last?.enabled, false)
        reply = manager.handle(["_": "enable"])
        XCTAssertEqual(reply["enabled"] as? Bool, true)
    }

    func testCollapseRefusedWhenSeparatorIsRightOfExpander() {
        enable(autoCollapse: 1)
        items.separatorIsLeftOfExpander = false
        let reply = manager.handle(["_": "collapse"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue((reply["error"] as? String ?? "").contains("⌘-drag"))
        advance(2)
        XCTAssertEqual(manager.state.mode, .expanded, "auto-collapse would hide the expander too")
        XCTAssertFalse(items.hidden)
    }

    func testHoverOverExpanderPeeksThroughThePoll() {
        enable()
        try? manager.collapse()
        probe.mouse = CGPoint(x: 1010, y: 890)   // on the expander
        advance(0.1)
        XCTAssertEqual(manager.state.mode, .collapsed)
        advance(0.12)
        XCTAssertEqual(manager.state.mode, .peeking)
        XCTAssertFalse(items.hidden)
        probe.mouse = CGPoint(x: 400, y: 890)    // along the menu bar
        advance(2)
        XCTAssertEqual(manager.state.mode, .peeking)
        probe.mouse = CGPoint(x: 400, y: 300)    // away
        advance(0.5)
        XCTAssertEqual(manager.state.mode, .peeking)
        advance(0.2)
        XCTAssertEqual(manager.state.mode, .collapsed)
        XCTAssertTrue(items.hidden)
    }

    func testOpenMenuHoldsExpandedAgainstAutoCollapse() {
        enable(autoCollapse: 1)
        probe.menuOpen = true
        advance(5)
        XCTAssertEqual(manager.state.mode, .expanded)
        XCTAssertEqual(manager.json["menuOpen"] as? Bool, true)
        probe.menuOpen = false
        advance(0.5)
        XCTAssertEqual(manager.state.mode, .expanded)
        advance(1)
        XCTAssertEqual(manager.state.mode, .collapsed)
    }

    func testExpanderClickTogglesAndRightClickShowsTheMenu() {
        enable()
        items.onExpanderClick?(false)
        XCTAssertEqual(manager.state.mode, .collapsed)
        items.onExpanderClick?(false)
        XCTAssertEqual(manager.state.mode, .expanded)
        items.onExpanderClick?(true)
        XCTAssertEqual(items.poppedUp, 1)
        XCTAssertEqual(manager.state.mode, .expanded)
    }

    func testStatusMenuSubmenu() throws {
        enable()
        let root = try XCTUnwrap(manager.menuItems().first)
        XCTAssertEqual(root.title, "Menu Bar")
        let titles = root.submenu?.items.map(\.title) ?? []
        XCTAssertEqual(titles.first, "Hide Menu Bar Items")
        XCTAssertTrue(titles.contains { $0.hasPrefix("Collapse") })
        XCTAssertTrue(titles.contains("Auto-collapse"))
        let auto = try XCTUnwrap(root.submenu?.items.first { $0.title == "Auto-collapse" }?.submenu)
        XCTAssertEqual(auto.items.first { $0.state == .on }?.title, "Never")
        manager.setAutoCollapse(30)
        XCTAssertEqual(persisted.last?.autoCollapseSeconds, 30)
        XCTAssertEqual(manager.state.autoCollapseSeconds, 30)
    }

    func testPanelModesThroughTheRouter() throws {
        enable()
        let registry = PanelRegistry()
        registry.register(MenuBarPanel(manager: manager))
        let host = MacHUDPanelHost(registry: registry)
        let dir = FakeBundles.tempDir("menubar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: dir.appendingPathComponent("m.sock").path))

        var reply: [String: Any] = [:]
        router.handle("panel", args: ["id": "menubar", "mode": "compact"]) { reply = $0 }
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["mode"] as? String, "compact")
        XCTAssertTrue(items.hidden)
        XCTAssertEqual(host.panelStates.first { $0.id == "menubar" }?.mode, .compact)

        router.handle("panel", args: ["id": "menubar", "mode": "full"]) { reply = $0 }
        XCTAssertEqual(reply["mode"] as? String, "full")
        XCTAssertFalse(items.hidden)

        router.handle("panel", args: ["id": "menubar", "mode": "parked"]) { reply = $0 }
        XCTAssertEqual(reply["ok"] as? Bool, false)

        router.handle("panel", args: ["id": "menubar", "action": "hide"]) { reply = $0 }
        XCTAssertEqual(reply["visible"] as? Bool, false)
        XCTAssertFalse(items.isInstalled, "hide turns management off")
        router.handle("panel", args: ["id": "menubar", "action": "show"]) { reply = $0 }
        XCTAssertEqual(reply["visible"] as? Bool, true)
        XCTAssertTrue(items.isInstalled)
    }

    func testMenubarVerbOverARealSocket() throws {
        enable()
        let dir = FakeBundles.tempDir("menubarsock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("m.sock").path
        let server = HUDSocketServer(path: path, label: "machud.test.menubar")
        manager.registerControl(server)
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var reply: [String: Any]?
        DispatchQueue.global().async {
            let r = try? HUDSocketClient(path: path, timeout: 5).request("menubar", args: ["collapse": "1"])
            DispatchQueue.main.async { reply = r }
        }
        XCTAssertTrue(spin(until: { reply != nil }))
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["mode"] as? String, "collapsed")
        XCTAssertTrue(items.hidden)
    }
}
