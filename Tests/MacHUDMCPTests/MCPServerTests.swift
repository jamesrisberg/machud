import XCTest
import HUDKit
@testable import MacHUDMCPCore

@MainActor
final class MCPServerTests: XCTestCase {
    private var fake: FakeMacHUD!
    private var output: Output!
    private var tools: MacHUDTools!
    private var server: MCPServer!
    private var nextID = 0

    override func setUp() {
        fake = FakeMacHUD()
        fake.start()
        output = Output()
        tools = MacHUDTools(transport: SocketTransport(path: fake.path, timeout: 5))
        let output = output!
        server = MCPServer(tools: tools, version: "9.9.9") { output.append($0) }
    }

    override func tearDown() {
        fake.cleanUp()
    }

    // MARK: - Helpers

    /// Sends a request and waits for its response.
    @discardableResult
    private func request(_ method: String, _ params: [String: Any]? = nil, file: StaticString = #filePath,
                         line: UInt = #line) -> [String: Any] {
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        server.receive(line: JSONLine.string(message))
        XCTAssertTrue(spin(until: { self.output.response(id: id) != nil }), "no reply to \(method)", file: file, line: line)
        return output.response(id: id) ?? [:]
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:], file: StaticString = #filePath,
                      line: UInt = #line) -> [String: Any] {
        let reply = request("tools/call", ["name": tool, "arguments": arguments], file: file, line: line)
        return reply["result"] as? [String: Any] ?? ["noResult": reply]
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// Runs `body` off the main thread (the fake MacHUD answers on it) and waits for it.
    private func offMain(_ body: @escaping @Sendable () -> Void) {
        let done = Output()
        DispatchQueue.global().async { body(); done.append("{}") }
        XCTAssertTrue(spin(until: { !done.all.isEmpty }))
    }

    private func loadApps() {
        let tools = tools!
        offMain { _ = try? tools.refreshApps() }
        XCTAssertFalse(tools.apps.isEmpty)
    }

    // MARK: - Lifecycle

    func testInitializeNegotiatesALegacyVersion() throws {
        let reply = request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                           "clientInfo": ["name": "test", "version": "1"]])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["capabilities"] as? [String: Any])?["tools"] as? [String: Bool], ["listChanged": true])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "machud")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "9.9.9")
        XCTAssertNotNil(result["instructions"] as? String)

        let other = request("initialize", ["protocolVersion": "2099-01-01", "capabilities": [:]])
        XCTAssertEqual((other["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25",
                       "an unknown version gets the latest legacy one")
    }

    func testDiscoverAndPerRequestVersions() throws {
        let meta: [String: Any] = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
        let discover = try XCTUnwrap(request("server/discover", meta)["result"] as? [String: Any])
        XCTAssertEqual(discover["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertEqual(discover["resultType"] as? String, "complete")
        XCTAssertNotNil((discover["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"])

        let list = try XCTUnwrap(request("tools/list", meta)["result"] as? [String: Any])
        XCTAssertEqual(list["resultType"] as? String, "complete")

        let bad = request("tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]])
        let error = try XCTUnwrap(bad["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32022)
        XCTAssertEqual((error["data"] as? [String: Any])?["requested"] as? String, "1900-01-01")
    }

    func testProtocolErrors() {
        server.receive(line: "{not json")
        XCTAssertTrue(spin(until: { self.output.all.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 } }))
        XCTAssertEqual((request("resources/list")["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((request("tools/call", ["name": "no_such_tool"])["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNotNil(request("ping")["result"] as? [String: Any])
        // Notifications get no reply.
        let before = output.all.count
        server.receive(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(output.all.count, before)
    }

    // MARK: - tools/list

    func testToolListNamesTheDiscoveredApps() throws {
        loadApps()
        let result = try XCTUnwrap(request("tools/list")["result"] as? [String: Any])
        let list = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(list.compactMap { $0["name"] as? String }, [
            "machud_status", "list_loadouts", "apply_loadout", "capture_loadout", "show_panel", "hide_panel",
            "toggle_panel", "list_app_actions", "app_action", "tool_dock", "park_window", "unpark",
            "open_session", "feed_add", "say", "list_widgets", "add_widget", "change_widget", "widget_mode",
        ])
        for tool in list {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], "\(tool["name"] ?? "")")
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
        let action = try XCTUnwrap(list.first { $0["name"] as? String == "app_action" })
        let app = ((action["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["app"] as? [String: Any]
        XCTAssertEqual(app?["enum"] as? [String], ["xyz.machud.scratch", "xyz.machud.mechahud"])
        let description = action["description"] as? String ?? ""
        XCTAssertTrue(description.contains("Scratch (xyz.machud.scratch): append, new, clear"), description)
        XCTAssertTrue(description.contains("open-session, approve, deny"), description)
    }

    // MARK: - Each tool

    func testLoadoutTools() throws {
        fake.replies["loadouts"] = { _ in
            ["ok": true, "startup": "Desk", "loadouts": [
                ["name": "Desk", "layout": "", "slots": [], "hud": ["dock": ["position": "bottom"]]],
                ["name": "Work", "layout": "Thirds", "slots": [["regionID": "a"], ["regionID": "b"]], "hotkey": ["key": "1"]],
            ]]
        }
        fake.replies["status"] = { _ in ["ok": true, "activeLoadout": "Work", "regions": []] }
        let list = call("list_loadouts")
        XCTAssertEqual(list["isError"] as? Bool, false)
        let loadouts = try XCTUnwrap((list["structuredContent"] as? [String: Any])?["loadouts"] as? [[String: Any]])
        XCTAssertEqual(loadouts.map { $0["name"] as? String }, ["Desk", "Work"])
        XCTAssertEqual(loadouts[0]["startup"] as? Bool, true)
        XCTAssertEqual(loadouts[0]["hud"] as? Bool, true)
        XCTAssertEqual(loadouts[1]["lastApplied"] as? Bool, true)
        XCTAssertEqual(loadouts[1]["windows"] as? Int, 2)
        XCTAssertEqual(loadouts[1]["layout"] as? String, "Thirds")

        fake.replies["apply"] = { _ in ["ok": true, "placed": ["a"], "failed": [:]] }
        let applied = call("apply_loadout", ["name": "Work", "clear": true, "screen": "main"])
        XCTAssertEqual((applied["structuredContent"] as? [String: Any])?["placed"] as? [String], ["a"])
        XCTAssertNil((applied["structuredContent"] as? [String: Any])?["ok"], "ok is not part of the result")
        XCTAssertEqual(fake.requests("apply").last, ["loadout": "Work", "clear": "1", "screen": "main"])
        call("apply_loadout", ["name": "Work", "dry_run": true])
        XCTAssertEqual(fake.requests("apply").last, ["loadout": "Work", "plan": "1"])

        call("capture_loadout", ["name": "New"])
        XCTAssertEqual(fake.requests("capture").last, ["name": "New"])
        call("capture_loadout", ["name": "All", "all_screens": true, "hud": "include"])
        XCTAssertEqual(fake.requests("capture").last, ["name": "All", "screens": "all", "hud": "1"])
        call("capture_loadout", ["name": "H", "hud": "only", "screen": "builtin"])
        XCTAssertEqual(fake.requests("capture").last, ["name": "H", "screen": "builtin", "hud": "only"])
    }

    func testPanelTools() {
        loadApps()
        call("show_panel", ["app": "Scratch"])
        XCTAssertEqual(fake.requests("summon").last, ["id": "xyz.machud.scratch/pad"])
        call("hide_panel", ["app": "xyz.machud.mechahud", "panel": "dashboard"])
        XCTAssertEqual(fake.requests("dismiss").last, ["id": "xyz.machud.mechahud/dashboard"])

        fake.replies["panels"] = { _ in ["ok": true, "panels": [["id": "xyz.machud.scratch/pad", "visible": true]]] }
        call("toggle_panel", ["app": "xyz.machud.scratch"])
        XCTAssertEqual(fake.requests("dismiss").last, ["id": "xyz.machud.scratch/pad"], "visible: toggling hides it")
        fake.replies["panels"] = { _ in ["ok": true, "panels": [["id": "xyz.machud.scratch/pad", "visible": false]]] }
        let summonsBefore = fake.requests("summon").count
        call("toggle_panel", ["app": "xyz.machud.scratch"])
        XCTAssertEqual(fake.requests("summon").count, summonsBefore + 1)

        let missing = call("show_panel", ["app": "Scratch", "panel": "nope"])
        XCTAssertEqual(missing["isError"] as? Bool, true)
        XCTAssertEqual(text(missing), "Scratch has no panel nope; its panels: pad")
        let noApp = call("show_panel", ["app": "Nothing"])
        XCTAssertEqual(noApp["isError"] as? Bool, true)
        XCTAssertTrue(text(noApp).hasPrefix("No app Nothing. Apps: Scratch (xyz.machud.scratch)"), text(noApp))
    }

    func testAppActionIsValidatedAgainstTheManifest() throws {
        loadApps()
        let listed = call("list_app_actions", ["app": "Scratch"])
        let content = try XCTUnwrap(listed["structuredContent"] as? [String: Any])
        XCTAssertEqual(content["actions"] as? [String], ["append", "new", "clear"])
        XCTAssertEqual((content["panels"] as? [[String: Any]])?.first?["capabilities"] as? [String], ["acceptsFileDrop"])

        fake.replies["apps"] = { [apps = [FakeMacHUD.pad, FakeMacHUD.dashboard]] args in
            args["action"] == "perform" ? ["ok": true, "app": "xyz.machud.scratch", "count": 2] : ["ok": true, "apps": apps]
        }
        let ran = call("app_action", ["app": "Scratch", "verb": "append", "args": ["text": "hi", "line": 3, "top": true]])
        XCTAssertEqual(ran["isError"] as? Bool, false, text(ran))
        XCTAssertEqual((ran["structuredContent"] as? [String: Any])?["count"] as? Int, 2)
        XCTAssertEqual(fake.requests("apps").last, ["action": "perform", "app": "xyz.machud.scratch", "verb": "append",
                                                    "text": "hi", "line": "3", "top": "true"])

        let performs = fake.requests("apps").filter { $0["action"] == "perform" }.count
        let undeclared = call("app_action", ["app": "Scratch", "verb": "paste"])
        XCTAssertEqual(undeclared["isError"] as? Bool, true)
        XCTAssertEqual(text(undeclared), "Scratch has no action paste; it declares append, new, clear")
        let panelVerb = call("app_action", ["app": "Scratch", "verb": "show"])
        XCTAssertEqual(panelVerb["isError"] as? Bool, true, "panel verbs go through show_panel")
        let reserved = call("app_action", ["app": "Scratch", "verb": "new", "args": ["app": "x"]])
        XCTAssertEqual(text(reserved), "args may not use the key app (MacHUD's own)")
        XCTAssertEqual(fake.requests("apps").filter { $0["action"] == "perform" }.count, performs,
                       "nothing invalid reaches MacHUD")
    }

    func testAppListRefreshesForAnAppDiscoveredSinceTheLastRead() {
        loadApps()
        fake.setApps([FakeMacHUD.pad, FakeMacHUD.dashboard, FakeMacHUD.stash])
        let shown = call("show_panel", ["app": "Stash"])
        XCTAssertEqual(shown["isError"] as? Bool, false, text(shown))
        XCTAssertEqual(fake.requests("summon").last, ["id": "xyz.machud.stash/history"])
    }

    func testWidgetTools() {
        fake.replies["widgets"] = { args in
            args["action"] == "types" ? ["ok": true, "types": [["type": "clock"]]]
                : ["ok": true, "editing": false, "revealed": false, "instances": [["instance": "A", "type": "clock"]]]
        }
        let listed = call("list_widgets")
        let content = listed["structuredContent"] as? [String: Any]
        XCTAssertEqual((content?["types"] as? [[String: Any]])?.first?["type"] as? String, "clock")
        XCTAssertEqual((content?["instances"] as? [[String: Any]])?.count, 1)

        call("add_widget", ["type": "clock", "size": "medium", "col": 2, "row": 1, "settings": ["zone": "UTC", "seconds": true]])
        XCTAssertEqual(fake.requests("widgets").last, ["action": "add", "type": "clock", "size": "medium", "col": "2", "row": "1",
                                                       "settings": #"{"seconds":true,"zone":"UTC"}"#])
        XCTAssertEqual(text(call("add_widget", ["type": "clock", "col": 2])), "give both col and row, or neither")
        call("change_widget", ["instance": "A", "action": "move", "col": 0, "row": 3, "screen": "builtin"])
        XCTAssertEqual(fake.requests("widgets").last, ["action": "move", "instance": "A", "col": "0", "row": "3", "screen": "builtin"])
        call("change_widget", ["instance": "A", "action": "layer", "layer": "float"])
        XCTAssertEqual(fake.requests("widgets").last, ["action": "layer", "instance": "A", "layer": "float"])
        call("change_widget", ["instance": "A", "action": "remove"])
        XCTAssertEqual(fake.requests("widgets").last, ["action": "remove", "instance": "A"])
        XCTAssertEqual(text(call("change_widget", ["instance": "A", "action": "resize"])), "size is required")
        call("widget_mode", ["mode": "reveal", "state": "on"])
        XCTAssertEqual(fake.requests("widgets").last, ["action": "reveal", "state": "on"])
        call("widget_mode", ["mode": "edit"])
        XCTAssertEqual(fake.requests("widgets").last, ["action": "edit", "state": "toggle"])
    }

    func testPanelToolsSkipWidgetTypes() {
        fake.setApps([["id": "xyz.machud.widgethud", "name": "widgetHUD", "health": "running", "running": true,
                       "manifest": ["id": "xyz.machud.widgethud", "name": "widgetHUD", "socket": "widgethud",
                                    "panels": [["id": "clock", "title": "Clock", "kind": "widget"]]]]])
        loadApps()
        XCTAssertEqual(text(call("show_panel", ["app": "widgetHUD"])), "widgetHUD serves only widgets (see list_widgets)")
    }

    func testDockParkingSessionsFeedAndVoiceTools() {
        call("tool_dock")
        XCTAssertEqual(fake.requests("tooldock").last, ["action": "state"])
        call("tool_dock", ["action": "hide"])
        XCTAssertEqual(fake.requests("tooldock").last, ["action": "hide"])
        call("tool_dock", ["action": "position", "position": "topLeft"])
        XCTAssertEqual(fake.requests("tooldock").last, ["action": "position", "position": "topLeft"])
        XCTAssertEqual(call("tool_dock", ["action": "position"])["isError"] as? Bool, true)

        call("park_window", ["app": "com.apple.Safari", "title": "Docs", "edge": "right", "peek": 12])
        XCTAssertEqual(fake.requests("park").last, ["app": "com.apple.Safari", "title": "Docs", "edge": "right", "peek": "12"])
        call("park_window", ["window": 4711])
        XCTAssertEqual(fake.requests("park").last, ["window": "4711"])
        call("park_window", ["region": "left"])
        XCTAssertEqual(fake.requests("park").last, ["id": "left"])
        let two = call("park_window", ["region": "left", "window": 1])
        XCTAssertEqual(text(two), "park_window needs exactly one of region, window or app")
        call("unpark", ["id": "left"])
        XCTAssertEqual(fake.requests("unpark").last, ["id": "left"])
        call("unpark")
        XCTAssertEqual(fake.requests("unpark").last, [:])

        call("open_session", ["id": "claude:abc"])
        XCTAssertEqual(fake.requests("sessions").last, ["action": "open", "id": "claude:abc"])
        call("feed_add", ["text": "hello"])
        XCTAssertEqual(fake.requests("feed").last, ["action": "add", "text": "hello", "source": "Agent"])
        call("feed_add", ["text": "t", "source": "Brain", "title": "T"])
        XCTAssertEqual(fake.requests("feed").last, ["action": "add", "text": "t", "source": "Brain", "title": "T"])
        call("say", ["text": "Done."])
        XCTAssertEqual(fake.requests("voice").last, ["_": "action", "name": "say", "text": "Done."])
        XCTAssertEqual(text(call("say")), "text is required")
    }

    func testMacHUDsRefusalIsAToolError() {
        fake.replies["apply"] = { _ in ["ok": false, "error": "no loadout Nope"] }
        let result = call("apply_loadout", ["name": "Nope"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(text(result), "no loadout Nope")
    }

    func testMacHUDNotRunningIsAToolError() {
        fake.stop()
        let result = call("list_loadouts")
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text(result).hasPrefix("MacHUD is not running (no socket at \(fake.path))"), text(result))
        let status = call("machud_status")
        XCTAssertEqual(status["isError"] as? Bool, true)
    }

    func testStatusGathersTheDesktop() throws {
        fake.replies["screens"] = { _ in ["ok": true, "screens": [["index": 0, "name": "Built-in", "main": true, "builtin": true,
                                                                    "w": 1512, "h": 982, "spaces": 3, "currentSpace": 1,
                                                                    "persistentID": "x"]]] }
        fake.replies["loadouts"] = { _ in ["ok": true, "startup": "", "loadouts": [["name": "Work", "layout": "Halves", "slots": []]]] }
        fake.replies["status"] = { _ in ["ok": true, "activeLoadout": "Work"] }
        fake.replies["tooldock"] = { _ in ["ok": true, "enabled": true, "position": "bottom", "visible": true, "buttons": []] }
        fake.replies["panels"] = { _ in ["ok": true, "panels": [["id": "xyz.machud.scratch/pad", "visible": true]]] }
        fake.replies["park"] = { _ in ["ok": true, "parked": [["id": "left", "label": "Safari"]], "orbs": []] }
        fake.replies["voice"] = { args in
            args["_"] == "status" ? ["ok": true, "status": "running", "connected": true, "pid": 12]
                : ["ok": true, "state": ["phase": ["name": "idle"], "brainAvailable": true, "inputLevel": 0.2]]
        }
        let result = call("machud_status")
        XCTAssertEqual(result["isError"] as? Bool, false, text(result))
        let status = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertNil(status["unavailable"])
        XCTAssertEqual((status["screens"] as? [[String: Any]])?.first?["spaces"] as? Int, 3)
        XCTAssertNil((status["screens"] as? [[String: Any]])?.first?["persistentID"])
        XCTAssertEqual((status["loadouts"] as? [[String: Any]])?.first?["lastApplied"] as? Bool, true)
        XCTAssertEqual((status["toolDock"] as? [String: Any])?["position"] as? String, "bottom")
        XCTAssertNil((status["toolDock"] as? [String: Any])?["buttons"])
        XCTAssertEqual((status["parked"] as? [[String: Any]])?.first?["label"] as? String, "Safari")
        let voice = try XCTUnwrap(status["voice"] as? [String: Any])
        XCTAssertEqual(voice["status"] as? String, "running")
        XCTAssertEqual(voice["brainAvailable"] as? Bool, true)
        XCTAssertNil(voice["inputLevel"])
        let apps = try XCTUnwrap(status["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.map { $0["app"] as? String }, ["xyz.machud.scratch", "xyz.machud.mechahud"])
        XCTAssertEqual((apps[0]["panels"] as? [[String: Any]])?.first?["visible"] as? Bool, true)
        XCTAssertEqual(apps[1]["actions"] as? [String], ["open-session", "approve", "deny"])
        XCTAssertEqual(apps[0]["outdated"] as? Bool, true)
        XCTAssertEqual(apps[0]["outdatedReason"] as? String, "rebuilt after it started")
        XCTAssertEqual(apps[0]["olderContract"] as? Bool, true)
        XCTAssertEqual(apps[1]["outdated"] as? Bool, false)
        XCTAssertEqual(apps[1]["olderContract"] as? Bool, false)
    }

    func testStatusReportsAMissingPartWithoutFailing() throws {
        fake.replies["voice"] = { _ in ["ok": false, "error": "the voice host is not running"] }
        let status = try XCTUnwrap(call("machud_status")["structuredContent"] as? [String: Any])
        XCTAssertEqual((status["unavailable"] as? [String: String])?["voice"], "the voice host is not running")
        XCTAssertNotNil(status["apps"])
    }

    // MARK: - list_changed

    func testLegacyClientIsToldWhenTheAppsChange() throws {
        request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]])
        let server = server!
        let watcher = AppWatcher(tools: tools, retryInterval: 0.2, settle: 0.05) { server.toolsMayHaveChanged() }
        offMain { watcher.start() }
        defer { watcher.stop() }
        request("tools/list")
        // Subscribing happens on a background thread; wait until MacHUD has the subscriber.
        XCTAssertTrue(spin(until: { self.fake.server.subscriberCount == 1 }))

        fake.pushState()   // a panel change: same apps, nothing to tell
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(output.notifications("notifications/tools/list_changed").isEmpty)

        fake.setApps([FakeMacHUD.pad, FakeMacHUD.dashboard, FakeMacHUD.stash])
        fake.pushState()
        XCTAssertTrue(spin(until: { self.output.notifications("notifications/tools/list_changed").count == 1 }))
        XCTAssertNil(output.notifications("notifications/tools/list_changed")[0]["params"])
        let list = try XCTUnwrap((request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let show = try XCTUnwrap(list.first { $0["name"] as? String == "show_panel" })
        XCTAssertTrue((show["description"] as? String ?? "").contains("Stash (xyz.machud.stash)"))
    }

    func testModernSubscriptionCarriesItsIdAndEndsOnCancel() throws {
        let server = server!
        let watcher = AppWatcher(tools: tools, retryInterval: 0.2, settle: 0.05) { server.toolsMayHaveChanged() }
        offMain { watcher.start() }
        defer { watcher.stop() }
        let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
        request("tools/list", ["_meta": meta])
        server.receive(line: JSONLine.string(["jsonrpc": "2.0", "id": "sub-1", "method": "subscriptions/listen",
                                              "params": ["_meta": meta, "notifications": ["toolsListChanged": true]]]))
        XCTAssertTrue(spin(until: { self.fake.server.subscriberCount == 1 }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        fake.setApps([FakeMacHUD.pad])
        fake.pushState()
        XCTAssertTrue(spin(until: { !self.output.notifications("notifications/tools/list_changed").isEmpty }))
        let note = output.notifications("notifications/tools/list_changed")[0]
        XCTAssertEqual(((note["params"] as? [String: Any])?["_meta"] as? [String: Any])?["io.modelcontextprotocol/subscriptionId"] as? String,
                       "sub-1")

        server.receive(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"sub-1"}}"#)
        XCTAssertTrue(spin(until: { self.output.all.contains { $0["id"] as? String == "sub-1" } }))
        let end = try XCTUnwrap(output.all.first { $0["id"] as? String == "sub-1" }?["result"] as? [String: Any])
        XCTAssertEqual(end["resultType"] as? String, "complete")
    }

    func testWatcherReconnectsWhenMacHUDComesBack() {
        fake.stop()
        let changed = Output()
        let watcher = AppWatcher(tools: tools, retryInterval: 0.1, settle: 0.05) { changed.append("{}") }
        offMain { watcher.start() }
        defer { watcher.stop() }
        XCTAssertTrue(tools.apps.isEmpty)
        let restarted = HUDSocketServer(path: fake.path, label: "machud-mcp.test.restarted")
        restarted.register("apps") { _, done in done(["ok": true, "apps": [FakeMacHUD.pad]]) }
        XCTAssertTrue(restarted.start())
        defer { restarted.stop() }
        XCTAssertTrue(spin(until: { self.tools.apps.map(\.id) == ["xyz.machud.scratch"] }))
        XCTAssertTrue(spin(until: { changed.all.count == 1 }))
        XCTAssertTrue(spin(until: { restarted.subscriberCount == 1 }), "subscribed again")
    }
}
