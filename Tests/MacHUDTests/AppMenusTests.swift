import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

/// The Apps section: sibling menus fetched with `menu`, built into submenus, performed with
/// `menu-invoke`; and host.json's lifecycle.
@MainActor
final class AppMenusTests: XCTestCase {
    private let id = "dev.test.sift"
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var externals: ExternalPanels!
    private var app: ExternalApp!

    /// What Sift's `menu` looks like, serialized by HUDKit from a real NSMenu.
    private static let fixtureTarget = MenuFixtureTarget()
    private static let siftMenu: [String: Any] = {
        let target = fixtureTarget
        _ = NSApplication.shared  // validation (menu.update) needs NSApp, as in a real app
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Sift", action: #selector(MenuFixtureTarget.act(_:)), keyEquivalent: "/")
        show.keyEquivalentModifierMask = [.option]
        menu.addItem(show)
        let dock = NSMenuItem(title: "Dock Mode", action: #selector(MenuFixtureTarget.act(_:)), keyEquivalent: "")
        dock.state = .on
        menu.addItem(dock)
        menu.addItem(.separator())
        let sub = NSMenu()
        sub.addItem(NSMenuItem(title: "Keep Both", action: #selector(MenuFixtureTarget.act(_:)), keyEquivalent: ""))
        let off = NSMenuItem(title: "Skip", action: nil, keyEquivalent: "")
        sub.addItem(off)
        let parent = NSMenuItem(title: "When Names Collide", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items + sub.items where item.action == #selector(MenuFixtureTarget.act(_:)) { item.target = target }
        return ["ok": true, "items": MainActor.assumeIsolated { HUDMenuBridge.serialize(menu).map(\.json) }]
    }()

    override func setUp() {
        workspace = FakeWorkspace()
        workspace.installed = [id]
        connector = FakeConnector()
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned self] in self.clock.now }
        app = ExternalApp(manifest: HUDManifest(id: id, name: "Sift", socket: "/tmp/gs-sift-menu.sock",
                                                panels: [HUDManifest.Panel(id: "browser", title: "Sift")]),
                          bundleURL: URL(fileURLWithPath: "/tmp/Sift.app"))
        connector.reachable = [app.socketPath]
        connector.replies["menu"] = Self.siftMenu
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        externals.install([app], autoLaunch: [])
    }

    private func startApp() {
        workspace.start(id)
        clock.runQueued()
        XCTAssertEqual(externals.supervisor.record(id)?.health, .running)
    }

    private var menuRequests: [String] { connector.requests.map(\.command).filter { $0.hasPrefix("menu") } }

    func testNotRunningAppIsNotAsked() {
        var result: Result<[HUDMenuBridge.Item], Error>?
        externals.menus.refresh(id) { result = $0 }
        XCTAssertThrowsError(try result?.get())
        XCTAssertEqual(menuRequests, [])
    }

    func testFetchCachesAndRefetchesWhenStale() throws {
        startApp()
        var items: [HUDMenuBridge.Item] = []
        externals.menus.refresh(id) { items = (try? $0.get()) ?? [] }
        XCTAssertEqual(items.map(\.title), ["Show Sift", "Dock Mode", "", "When Names Collide", "", "Quit Sift"])
        XCTAssertEqual(items[1].state, .on)
        XCTAssertEqual(items[3].items?.map(\.id), ["3.0", "3.1"])
        externals.menus.refresh(id)
        externals.menus.refreshRunning()
        XCTAssertEqual(menuRequests, ["menu"], "fresh copy reused")
        clock.now += AppMenus.ttl + 0.1
        externals.menus.refreshRunning()
        XCTAssertEqual(menuRequests, ["menu", "menu"])
    }

    func testRefusedAndFailedRepliesAreRemembered() {
        startApp()
        connector.replies["menu"] = ["ok": false, "error": "no menu"]
        var error: String?
        externals.menus.refresh(id) { if case .failure(let e) = $0 { error = "\(e)" } }
        XCTAssertEqual(error, "no menu")
        XCTAssertEqual(externals.menus.entry(id)?.error, "no menu")
        connector.failing = ["menu"]
        externals.menus.refresh(id, force: true)
        XCTAssertNotNil(externals.menus.entry(id)?.error)
    }

    func testFilteredDropsQuitAndStraySeparators() {
        let items = HUDMenuBridge.Item.list(Self.siftMenu["items"])
        XCTAssertEqual(AppMenus.filtered(items).map(\.title), ["Show Sift", "Dock Mode", "", "When Names Collide"])
        let odd = [HUDMenuBridge.Item(id: "0", title: "", kind: .separator), HUDMenuBridge.Item(id: "1", title: "A"),
                   HUDMenuBridge.Item(id: "2", title: "", kind: .separator), HUDMenuBridge.Item(id: "3", title: "", kind: .separator),
                   HUDMenuBridge.Item(id: "4", title: "Quit")]
        XCTAssertEqual(AppMenus.filtered(odd).map(\.id), ["1"])
    }

    func testSubmenuIsBuiltFromTheReplyAndInvokesByID() throws {
        startApp()
        let services = MacHUDServices(externals: externals, host: MacHUDPanelHost(registry: externals.registry))
        var summoned: [String] = []
        services.summon = { summoned.append($0) }
        externals.menus.onUpdate = { [weak services] in services?.appMenuUpdated($0) }
        connector.deferred = []

        let section = services.menuItems()
        XCTAssertEqual(section.first?.title, "Apps")
        let appItem = try XCTUnwrap(section.first { $0.title == "● Sift" })
        let sub = try XCTUnwrap(appItem.submenu)
        XCTAssertTrue(sub.items.contains { $0.title == "Loading…" }, "no reply yet")
        XCTAssertEqual(menuRequests, ["menu"], "prefetched when the status menu opens")

        // The reply arrives while the menu is open: the submenu fills in place.
        connector.deferred?.removeFirst().reply()
        let titles = sub.items.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(titles, ["Show Sift", "-", "Show Sift", "Dock Mode", "-", "When Names Collide", "-",
                                "Park", "Show on Tool Dock", "Sift Settings…", "-", "Relaunch Sift", "Quit Sift"])
        let dock = try XCTUnwrap(sub.items.first { $0.title == "Dock Mode" })
        XCTAssertEqual(dock.state, .on)
        let appShow = sub.items[2]
        XCTAssertEqual(appShow.keyEquivalent, "/")
        XCTAssertEqual(appShow.keyEquivalentModifierMask, [.option])
        let collide = try XCTUnwrap(sub.items.first { $0.title == "When Names Collide" }?.submenu)
        XCTAssertEqual(collide.items.map(\.isEnabled), [true, false])

        // Choosing one of the app's items sends menu-invoke with its id and title.
        connector.deferred = nil
        sub.performActionForItem(at: try XCTUnwrap(sub.items.firstIndex(of: dock)))
        let invoke = try XCTUnwrap(connector.requests.last)
        XCTAssertEqual(invoke.command, "menu-invoke")
        XCTAssertEqual(invoke.args, ["id": "1", "title": "Dock Mode"])
        XCTAssertNil(externals.menus.entry(id), "cache dropped so the next open shows the change")
        collide.performActionForItem(at: 0)
        XCTAssertEqual(connector.requests.last?.args, ["id": "3.0", "title": "Keep Both"])

        // "Show Sift" at the top summons the panel.
        sub.performActionForItem(at: 0)
        XCTAssertEqual(summoned, ["\(id)/browser"])
    }

    func testAppsVerbServesMenuAndInvoke() throws {
        startApp()
        let dir = FakeBundles.tempDir("appsmenu")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        let server = HUDSocketServer(path: path, label: "machud.test.appsmenu")
        externals.registerControl(server)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        func call(_ args: [String: String]) -> [String: Any] {
            var reply: [String: Any]?
            DispatchQueue.global().async {
                let r = (try? HUDSocketClient(path: path, timeout: 5).request("apps", args: args)) ?? ["client": "failed"]
                DispatchQueue.main.async { reply = r }
            }
            XCTAssertTrue(spin(until: { reply != nil }))
            return reply ?? [:]
        }
        let menu = call(["action": "menu", "id": "Sift"])
        XCTAssertEqual(menu["ok"] as? Bool, true)
        XCTAssertEqual(HUDMenuBridge.Item.list(menu["items"]).count, 6)
        connector.replies["menu-invoke"] = ["ok": true, "id": "1", "title": "Dock Mode"]
        let invoked = call(["action": "menu-invoke", "id": id, "item": "1", "title": "Dock Mode"])
        XCTAssertEqual(invoked["ok"] as? Bool, true)
        XCTAssertEqual(invoked["title"] as? String, "Dock Mode")
        connector.replies["menu-invoke"] = ["ok": false, "error": "menu item 1 is disabled"]
        XCTAssertEqual(call(["action": "menu-invoke", "id": id, "item": "1"])["error"] as? String, "menu item 1 is disabled")
        XCTAssertEqual(call(["action": "menu-invoke", "id": id])["ok"] as? Bool, false)
    }
}

@MainActor
final class MenuHostPublisherTests: XCTestCase {
    func testHostFileLifecycle() throws {
        let dir = FakeBundles.tempDir("host")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("host.json")
        let publisher = MenuHostPublisher(url: url, bundleID: "com.jrisberg.machud", pid: getpid())
        publisher.start(hostsMenus: true)
        var host = try XCTUnwrap(HUDMenuHost.read(from: url))
        XCTAssertEqual(host.pid, getpid())
        XCTAssertEqual(host.bundleID, "com.jrisberg.machud")
        XCTAssertTrue(host.hostsMenus)

        publisher.update(hostsMenus: false)
        host = try XCTUnwrap(HUDMenuHost.read(from: url))
        XCTAssertFalse(host.hostsMenus, "consumeSiblings off: icons come back")

        // A sibling's policy follows it.
        var visible: [Bool] = []
        let policy = HUDStatusItemPolicy(appID: "dev.sib", hostURL: url, store: .defaults(UserDefaults(suiteName: "machud-test-\(getpid())")!),
                                         ownPID: 1, isAlive: { _ in true }, apply: { visible.append($0) })
        policy.evaluate()
        publisher.update(hostsMenus: true)
        policy.evaluate()
        publisher.withdraw()
        policy.evaluate()
        XCTAssertEqual(visible, [true, false, true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "removed on quit")

        // Another instance's file is not ours to remove.
        try HUDMenuHost(pid: 1, bundleID: "other", hostsMenus: true).write(to: url)
        publisher.withdraw()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testConfigAndSetting() throws {
        XCTAssertTrue(MenuBarConfig().consumesSiblings, "default on")
        let decoded = try JSONDecoder().decode(MenuBarConfig.self, from: Data(#"{"consumeSiblings": false}"#.utf8))
        XCTAssertFalse(decoded.consumesSiblings)
        let parsed = try MacHUDSettings.schema.validate(["menuBar.consumeSiblings": "false"])
        let updated = MacHUDSettings.applying(parsed, to: Config.defaults)
        XCTAssertEqual(updated.menuBar?.consumeSiblings, false)
        XCTAssertEqual(MacHUDSettings.values(config: updated, enabled: true, orbsHidden: false)["menuBar.consumeSiblings"] as? Bool, false)
    }

    func testIsolatedInstanceUsesItsOwnFile() {
        // Not settable per test (process env); the rule is documented in fileURL.
        XCTAssertTrue(MenuHostPublisher.fileURL.lastPathComponent == "host.json")
    }
}

/// Keeps the fixture menu's items enabled (menu item targets are weak).
final class MenuFixtureTarget: NSObject {
    @objc func act(_ sender: Any?) {}
}
