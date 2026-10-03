import XCTest
@testable import MacHUDCore

/// The `diagnose` snapshot builder: a pure function of injected providers, so these tests
/// need no live windows.
final class DiagnoseSnapshotTests: XCTestCase {
    typealias Snapshot = DiagnoseSnapshot

    // MARK: - A healthy desktop

    private let dell = Snapshot.Display(
        name: "DELL U2720Q", displayID: 2, persistentID: "10ac-d0b9-1", isPrimary: true,
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
        spaceIdentifier: "Main", spaceIDs: [11, 12, 13, 14], currentSpaceID: 11)

    private let machud = Snapshot.FamilyProcess(role: .machud, name: "MacHUD", bundleID: "xyz.machud.machud", pid: 100)
    private let voice = Snapshot.FamilyProcess(role: .voiceHost, name: "MacHUDVoice", bundleID: nil, pid: 200)
    private let widgetHUD = Snapshot.FamilyProcess(role: .sibling, name: "widgetHUD", bundleID: "xyz.machud.widgethud", pid: 300)

    private let everySpace: [UInt64] = [11, 12, 13, 14]

    private func window(_ id: Int, pid: Int32, level: Int = 0, alpha: Double = 1, onScreen: Bool = true,
                        frame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200), owner: String = "App") -> Snapshot.ServerWindow {
        Snapshot.ServerWindow(id: id, pid: pid, ownerName: owner, level: level, alpha: alpha, isOnScreen: onScreen, frame: frame)
    }

    private var orb: Snapshot.ServerWindow {
        window(812, pid: 200, level: 25, frame: CGRect(x: 1265, y: 1409, width: 29, height: 31), owner: "MacHUDVoice")
    }
    private var dock: Snapshot.ServerWindow {
        window(700, pid: 100, level: 4, frame: CGRect(x: 900, y: 0, width: 760, height: 80), owner: "MacHUD")
    }
    private var widget: Snapshot.ServerWindow {
        window(900, pid: 300, level: -2_147_483_623, frame: CGRect(x: 40, y: 900, width: 300, height: 300), owner: "widgetHUD")
    }

    private func appKit(_ number: Int, identifier: String? = nil, title: String? = nil, visible: Bool = true, onActive: Bool = true,
                        alpha: Double = 1, level: Int = 0, behavior: UInt = 0,
                        frame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200)) -> Snapshot.AppKitWindow {
        Snapshot.AppKitWindow(number: number, identifier: identifier, title: title, className: "NSPanel", isVisible: visible,
                              isOnActiveSpace: onActive, alpha: alpha, level: level, collectionBehavior: behavior, frame: frame)
    }

    private let healthyReplies: [String: [String: Any]] = [
        "tooldock": ["ok": true, "enabled": true, "position": "bottom", "visible": true],
        "widgets": ["ok": true, "editing": false, "instances": [["instance": "A", "type": "clock"]]],
        "voiceStatus": ["ok": true, "status": "running", "connected": true, "pid": 200],
        "voiceState": ["ok": true, "state": ["phase": ["name": "idle"], "hiddenForFullScreen": false, "partialTranscript": "",
                                              "muted": false]],
    ]

    private func providers(windows: [Snapshot.ServerWindow]? = nil, spaces: [Int: [UInt64]]? = nil,
                           appKit appKitWindows: [Snapshot.AppKitWindow]? = nil, displays: [Snapshot.Display]? = nil,
                           processes: [Snapshot.FamilyProcess]? = nil, frontmost: Snapshot.App? = Snapshot.App(name: "Xcode", pid: 400),
                           replies: [String: [String: Any]]? = nil) -> Snapshot.Providers {
        let listed = windows ?? [orb, dock, widget]
        let onEverySpace = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, everySpace) })
        let known = spaces ?? onEverySpace
        return Snapshot.Providers(
            now: { Date(timeIntervalSince1970: 1_790_000_000) },
            machud: { Snapshot.Machud(version: "0.3.1", build: "31", pid: 100, launchedAt: Date(timeIntervalSince1970: 1_789_000_000),
                                      isolated: false) },
            displays: { displays ?? [self.dell] },
            frontmost: { frontmost },
            processes: { processes ?? [self.machud, self.voice, self.widgetHUD] },
            serverWindows: { listed },
            spaces: { known[$0] },
            appKitWindows: { appKitWindows ?? [] },
            replies: replies ?? healthyReplies)
    }

    private func build(_ p: Snapshot.Providers) -> Snapshot.Result { Snapshot.build(p) }

    private func processEntry(_ result: Snapshot.Result, pid: Int) throws -> [String: Any] {
        let all = try XCTUnwrap(result.document["processes"] as? [[String: Any]])
        return try XCTUnwrap(all.first { $0["pid"] as? Int == pid }, "no process \(pid) in \(all)")
    }

    private func windowEntry(_ result: Snapshot.Result, pid: Int, id: Int) throws -> [String: Any] {
        let windows = try XCTUnwrap(try processEntry(result, pid: pid)["windows"] as? [[String: Any]])
        return try XCTUnwrap(windows.first { $0["id"] as? Int == id }, "no window \(id) in \(windows)")
    }

    // MARK: - The document

    func testAHealthyDesktopHasNoAnomalies() {
        let result = build(providers())
        XCTAssertEqual(result.anomalies, [])
        XCTAssertEqual(result.document["anomalies"] as? [String], [])
    }

    func testTheDocumentHasTheseTopLevelKeys() {
        let result = build(providers())
        XCTAssertEqual(Set(result.document.keys), ["createdAt", "machud", "displays", "frontmostApp", "processes",
                                                   "fullFrameWindows", "replies", "anomalies"])
        let machud = result.document["machud"] as? [String: Any]
        XCTAssertEqual(machud?["version"] as? String, "0.3.1")
        XCTAssertEqual(machud?["pid"] as? Int, 100)
        XCTAssertEqual(machud?["isolated"] as? Bool, false)
        XCTAssertNotNil(machud?["launchedAt"] as? String)
        XCTAssertEqual(result.document["createdAt"] as? String, "2026-09-21T14:13:20Z")
        let front = result.document["frontmostApp"] as? [String: Any]
        XCTAssertEqual(front?["name"] as? String, "Xcode")
        XCTAssertEqual(front?["pid"] as? Int, 400)
    }

    func testDisplaysCarryFramesPrimaryAndEveryDesktop() throws {
        let second = Snapshot.Display(name: "Built-in", displayID: 1, persistentID: nil, isPrimary: false,
                                      frame: CGRect(x: 2560, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 2560, y: 0, width: 1512, height: 950),
                                      spaceIdentifier: "ABC", spaceIDs: [21, 22], currentSpaceID: 22)
        let result = build(providers(displays: [dell, second]))
        let displays = try XCTUnwrap(result.document["displays"] as? [[String: Any]])
        XCTAssertEqual(displays.map { $0["name"] as? String }, ["DELL U2720Q", "Built-in"])
        XCTAssertEqual(displays.map { $0["primary"] as? Bool }, [true, false])
        XCTAssertEqual(displays[0]["frame"] as? [String: Double], ["x": 0, "y": 0, "w": 2560, "h": 1440])
        XCTAssertEqual(displays[0]["visibleFrame"] as? [String: Double], ["x": 0, "y": 0, "w": 2560, "h": 1415])
        let spaces = try XCTUnwrap(displays[1]["spaces"] as? [String: Any])
        XCTAssertEqual(spaces["all"] as? [Int], [21, 22])
        XCTAssertEqual(spaces["current"] as? Int, 22)
        XCTAssertEqual(spaces["currentIndex"] as? Int, 2)
    }

    func testEveryFamilyProcessListsItsWindowsAsTheServerSeesThem() throws {
        let result = build(providers(windows: [dock, orb, widget, window(1, pid: 999, owner: "Safari")]))
        let processes = try XCTUnwrap(result.document["processes"] as? [[String: Any]])
        XCTAssertEqual(processes.map { $0["pid"] as? Int }, [100, 200, 300], "MacHUD, the voice host, then siblings; no other app")
        XCTAssertEqual(processes.map { $0["role"] as? String }, ["machud", "voiceHost", "sibling"])
        XCTAssertEqual(processes[2]["bundleID"] as? String, "xyz.machud.widgethud")

        let orbEntry = try windowEntry(result, pid: 200, id: 812)
        XCTAssertEqual(orbEntry["level"] as? Int, 25)
        XCTAssertEqual(orbEntry["alpha"] as? Double, 1)
        XCTAssertEqual(orbEntry["onScreen"] as? Bool, true)
        XCTAssertEqual(orbEntry["frame"] as? [String: Double], ["x": 1265, "y": 1409, "w": 29, "h": 31])
        XCTAssertEqual(orbEntry["spaces"] as? [Int], [11, 12, 13, 14])
        XCTAssertEqual(orbEntry["display"] as? String, "DELL U2720Q")
        XCTAssertNil(orbEntry["appKit"], "only MacHUD's own windows have AppKit's view")
    }

    func testWindowsOfAProcessAreInIdOrder() throws {
        let result = build(providers(windows: [window(30, pid: 300), window(10, pid: 300), window(20, pid: 300)]))
        let windows = try XCTUnwrap(try processEntry(result, pid: 300)["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.map { $0["id"] as? Int }, [10, 20, 30])
    }

    func testSpacesAreNullWhenThePrivateCallIsUnavailable() throws {
        let p = providers()
        var unavailable = p
        unavailable.spaces = { _ in nil }
        let entry = try windowEntry(build(unavailable), pid: 200, id: 812)
        XCTAssertTrue(entry["spaces"] is NSNull)
        XCTAssertEqual(build(unavailable).anomalies, [], "no Spaces data, no Spaces anomaly")
    }

    func testAWindowOffEveryDisplayHasNoDisplayName() throws {
        let away = window(5, pid: 300, frame: CGRect(x: -9000, y: -9000, width: 10, height: 10))
        let entry = try windowEntry(build(providers(windows: [away], spaces: [5: [11]])), pid: 300, id: 5)
        XCTAssertTrue(entry["display"] is NSNull)
    }

    // MARK: - AppKit's view of MacHUD's own windows

    func testMacHUDsOwnWindowsCarryAppKitsViewBesideTheServers() throws {
        let behavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .stationary])
        let kit = appKit(700, identifier: "tooldock.strip", visible: true, onActive: true, alpha: 1, level: 4,
                         behavior: behavior.rawValue, frame: CGRect(x: 900, y: 0, width: 760, height: 80))
        let result = build(providers(appKit: [kit]))
        let own = try XCTUnwrap(try windowEntry(result, pid: 100, id: 700)["appKit"] as? [String: Any])
        XCTAssertEqual(own["identifier"] as? String, "tooldock.strip")
        XCTAssertEqual(own["isVisible"] as? Bool, true)
        XCTAssertEqual(own["isOnActiveSpace"] as? Bool, true)
        XCTAssertEqual(own["alpha"] as? Double, 1)
        XCTAssertEqual(own["level"] as? Int, 4)
        XCTAssertEqual(own["collectionBehavior"] as? Int, Int(behavior.rawValue))
        XCTAssertEqual(own["collectionBehaviorNames"] as? [String], ["canJoinAllSpaces", "stationary"], "named from the option bits")
        XCTAssertEqual(own["frame"] as? [String: Double], ["x": 900, "y": 0, "w": 760, "h": 80])
        XCTAssertNil(own["title"], "the identifier names it")
    }

    func testAnUnidentifiedOwnWindowIsNamedByItsTitleThenItsClass() throws {
        let result = build(providers(windows: [dock, window(701, pid: 100, owner: "MacHUD")],
                                     appKit: [appKit(700, title: "MacHUD Tool Dock"), appKit(701)]))
        XCTAssertEqual((try windowEntry(result, pid: 100, id: 700)["appKit"] as? [String: Any])?["title"] as? String, "MacHUD Tool Dock")
        let bare = try XCTUnwrap(try windowEntry(result, pid: 100, id: 701)["appKit"] as? [String: Any])
        XCTAssertNil(bare["title"])
        XCTAssertNil(bare["identifier"])
        XCTAssertEqual(bare["class"] as? String, "NSPanel")
    }

    func testAppKitWindowsTheServerDoesNotListAreKept() throws {
        let result = build(providers(appKit: [appKit(700, identifier: "listed"), appKit(-1, identifier: "never ordered in", visible: false)]))
        let unlisted = try XCTUnwrap(try processEntry(result, pid: 100)["appKitWindowsNotListedByTheServer"] as? [[String: Any]])
        XCTAssertEqual(unlisted.map { $0["identifier"] as? String }, ["never ordered in"])
    }

    func testCollectionBehaviorIsNamedFromItsBits() {
        XCTAssertEqual(Snapshot.collectionBehaviorNames(0), [])
        XCTAssertEqual(Snapshot.collectionBehaviorNames(NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue), ["canJoinAllSpaces"])
        let hover: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        XCTAssertEqual(Snapshot.collectionBehaviorNames(hover.rawValue), ["canJoinAllSpaces", "ignoresCycle", "fullScreenAuxiliary"])
        XCTAssertEqual(Snapshot.collectionBehaviorNames(NSWindow.CollectionBehavior.moveToActiveSpace.rawValue), ["moveToActiveSpace"])
    }

    // MARK: - Full-frame windows

    func testFullFrameLayerZeroWindowsOfAnyAppAreListed() throws {
        let full = window(50, pid: 400, alpha: 1, frame: dell.frame, owner: "Xcode")
        let offScreen = window(51, pid: 401, onScreen: false, frame: dell.frame, owner: "Hidden")
        let menuBarLevel = window(52, pid: 402, level: 25, frame: dell.frame, owner: "Overlay")
        let small = window(53, pid: 403, frame: CGRect(x: 0, y: 0, width: 2560, height: 1415), owner: "Maximised")
        let almost = window(54, pid: 404, frame: CGRect(x: 0.4, y: 0, width: 2560.6, height: 1440), owner: "Rounded")
        let result = build(providers(windows: [orb, full, offScreen, menuBarLevel, small, almost]))
        let listed = try XCTUnwrap(result.document["fullFrameWindows"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? Int }, [50, 54])
        XCTAssertEqual(listed[0]["app"] as? String, "Xcode")
        XCTAssertEqual(listed[0]["pid"] as? Int, 400)
        XCTAssertEqual(listed[0]["alpha"] as? Double, 1)
        XCTAssertEqual(listed[0]["frame"] as? [String: Double], ["x": 0, "y": 0, "w": 2560, "h": 1440])
        XCTAssertEqual(listed[0]["display"] as? String, "DELL U2720Q")
        XCTAssertEqual(listed[0]["ownedByFrontmost"] as? Bool, true)
        XCTAssertEqual(listed[1]["ownedByFrontmost"] as? Bool, false)
    }

    // MARK: - Anomalies: AppKit visible, server not on screen

    func testAWindowAppKitCallsVisibleButTheServerDoesNotListOnScreenIsAnAnomaly() {
        let hidden = window(700, pid: 100, level: 4, onScreen: false, owner: "MacHUD")
        let result = build(providers(windows: [orb, hidden], spaces: [812: everySpace, 700: []],
                                     appKit: [appKit(700, identifier: "tooldock.strip", visible: true, onActive: true)]))
        XCTAssertEqual(result.anomalies,
                       ["MacHUD window #700 (tooldock.strip) is visible to AppKit but the window server does not list it as on screen"])
    }

    func testAnAllSpacesWindowAppKitDoesNotPlaceOnTheActiveSpaceIsAnAnomaly() {
        let joinsAll = NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue
        let hidden = window(700, pid: 100, level: 4, onScreen: false, owner: "MacHUD")
        let result = build(providers(windows: [hidden], spaces: [700: [13]],
                                     appKit: [appKit(700, identifier: "tooldock.strip", visible: true, onActive: false, behavior: joinsAll)]))
        XCTAssertTrue(result.anomalies.contains {
            $0.hasPrefix("MacHUD window #700 (tooldock.strip) is visible to AppKit but the window server does not list it as on screen")
        }, "\(result.anomalies)")
    }

    func testAnOrdinaryWindowOnAnotherDesktopIsNotAnAnomaly() {
        let elsewhere = window(701, pid: 100, onScreen: false, owner: "MacHUD")
        let result = build(providers(windows: [elsewhere], spaces: [701: [13]],
                                     appKit: [appKit(701, identifier: "settings", visible: true, onActive: false)]))
        XCTAssertEqual(result.anomalies, [])
    }

    func testAWindowAppKitHasMadeTransparentOrEmptyIsNotAnAnomaly() {
        let faded = window(700, pid: 100, alpha: 0, onScreen: false, owner: "MacHUD")
        let empty = window(702, pid: 100, onScreen: false, owner: "MacHUD")
        let result = build(providers(windows: [faded, empty], spaces: [700: [], 702: []],
                                     appKit: [appKit(700, visible: true, alpha: 0),
                                              appKit(702, visible: true, frame: .zero)]))
        XCTAssertEqual(result.anomalies, [])
    }

    func testAVisibleWindowTheServerDoesNotListAtAllIsAnAnomaly() {
        let result = build(providers(appKit: [appKit(4242, identifier: "ghost", visible: true)]))
        XCTAssertEqual(result.anomalies, ["MacHUD window #4242 (ghost) is visible to AppKit but the window server does not list it at all"])
    }

    func testStatusItemWindowsAndWindowsNeverOrderedInAreNotAnomalies() {
        // The menu bar's status items have proxy numbers beyond a CGWindowID; AppKit reports them visible.
        let result = build(providers(appKit: [appKit(4_294_967_296, identifier: "Item-0", visible: true, onActive: false),
                                              appKit(-1, identifier: "never ordered in", visible: true)]))
        XCTAssertEqual(result.anomalies, [])
    }

    // MARK: - Anomalies: on some desktops of its display but not the current one

    func testAMacHUDWindowAppKitCallsVisibleButOnlyOnAnotherDesktopIsAnAnomaly() {
        let stuck = window(700, pid: 100, level: 4, onScreen: false, frame: CGRect(x: 900, y: 0, width: 760, height: 80), owner: "MacHUD")
        let kit = appKit(700, identifier: "tooldock.strip", visible: true, onActive: false, level: 4)
        let result = build(providers(windows: [orb, stuck, widget], spaces: [812: everySpace, 700: [13], 900: everySpace], appKit: [kit]))
        XCTAssertEqual(result.anomalies,
                       ["MacHUD window #700 (tooldock.strip, level 4) is on desktop 3 of 4 on DELL U2720Q but not on the one showing (desktop 1)"])
    }

    func testAMacHUDWindowAppKitHasOrderedOutIsDormantNotAnAnomaly() {
        let remembered = window(700, pid: 100, level: 4, onScreen: false, owner: "MacHUD")
        let hiddenKit = appKit(700, identifier: "tooldock.strip", visible: false, onActive: false, level: 4)
        XCTAssertEqual(build(providers(windows: [orb, remembered, widget], spaces: [812: everySpace, 700: [13], 900: everySpace],
                                       appKit: [hiddenKit])).anomalies, [])
        XCTAssertEqual(build(providers(windows: [orb, remembered, widget], spaces: [812: everySpace, 700: [13], 900: everySpace])).anomalies,
                       [], "no AppKit view of it at all")
    }

    private let scratch = Snapshot.FamilyProcess(role: .sibling, name: "Scratch", bundleID: "xyz.machud.scratch", pid: 310)
    private var scratchPanel: Snapshot.ServerWindow {
        window(179_586, pid: 310, level: 3, onScreen: false, frame: CGRect(x: 78, y: 606, width: 560, height: 400), owner: "Scratch")
    }

    func testADormantSiblingPanelRememberingItsLastDesktopIsNotAnAnomaly() {
        // Ordered out, alpha 1, on the one desktop it was last shown on; its app says the panel is hidden.
        let result = build(providers(windows: [orb, scratchPanel], spaces: [812: everySpace, 179_586: [13]],
                                     processes: [machud, voice, scratch]))
        XCTAssertEqual(result.anomalies, [])
    }

    func testASiblingPanelItsAppReportsVisibleButOnlyOnAnotherDesktopIsAnAnomaly() {
        var shown = scratch
        shown.showsHoverPanel = true
        let result = build(providers(windows: [orb, scratchPanel], spaces: [812: everySpace, 179_586: [13]],
                                     processes: [machud, voice, shown]))
        XCTAssertEqual(result.anomalies,
                       ["Scratch window #179586 (level 3) is on desktop 3 of 4 on DELL U2720Q but not on the one showing (desktop 1)"])
    }

    func testAWindowedSiblingPanelOnAnotherDesktopIsNotAnAnomalyEvenWhileShown() {
        var shown = scratch
        shown.showsHoverPanel = true
        let windowed = window(179_590, pid: 310, level: 0, onScreen: false, owner: "Scratch")
        XCTAssertEqual(build(providers(windows: [orb, windowed], spaces: [812: everySpace, 179_590: [13]],
                                       processes: [machud, voice, shown])).anomalies, [], "a window on its own desktop is ordinary")
    }

    func testAnAllDesktopsWindowMissingTheShowingOneIsAnAnomalyEvenWhenDormant() {
        let result = build(providers(windows: [orb, scratchPanel], spaces: [812: everySpace, 179_586: [12, 13, 14]],
                                     processes: [machud, voice, scratch]))
        XCTAssertEqual(result.anomalies,
                       ["Scratch window #179586 (level 3) is on desktops 2, 3, 4 of 4 on DELL U2720Q but not on the one showing (desktop 1)"])
    }

    func testADesktopLevelWidgetOfARunningWidgetAppOnAnotherDesktopIsAnAnomaly() {
        var replies = healthyReplies
        replies["widgets"] = ["ok": true, "instances": [["instance": "A", "app": "xyz.machud.widgethud", "type": "clock"]]]
        let stranded = window(900, pid: 300, level: -2_147_483_623, onScreen: false, owner: "widgetHUD")
        let result = build(providers(windows: [orb, stranded], spaces: [812: everySpace, 900: [13]], replies: replies))
        XCTAssertEqual(result.anomalies,
                       ["widgetHUD window #900 (level -2147483623) is on desktop 3 of 4 on DELL U2720Q but not on the one showing (desktop 1)"])
    }

    func testADesktopLevelWindowOfAnAppWithNoPlacedWidgetIsNotAnAnomaly() {
        let leftover = window(900, pid: 300, level: -2_147_483_623, onScreen: false, owner: "widgetHUD")
        XCTAssertEqual(build(providers(windows: [orb, leftover], spaces: [812: everySpace, 900: [13]])).anomalies, [],
                       "the healthy replies place no widget")
    }

    // MARK: - Anomalies: the window server lags AppKit

    func testAnAppKitVersusServerMismatchIsFlaggedForConfirmation() {
        let hidden = window(700, pid: 100, level: 4, onScreen: false, owner: "MacHUD")
        let mismatch = build(providers(windows: [orb, hidden], spaces: [812: everySpace, 700: []],
                                       appKit: [appKit(700, identifier: "tooldock.strip", visible: true, onActive: true)]))
        XCTAssertTrue(mismatch.appKitMismatch)
        XCTAssertFalse(build(providers()).appKitMismatch)
        // The desktops rule is about the server's own list, so it needs no second reading.
        let kit = appKit(700, identifier: "tooldock.strip", visible: true, onActive: false, level: 4)
        let stuck = build(providers(windows: [orb, hidden], spaces: [812: everySpace, 700: [13]], appKit: [kit]))
        XCTAssertEqual(stuck.anomalies.count, 1)
        XCTAssertFalse(stuck.appKitMismatch)
    }

    // MARK: - Anomalies: on some desktops of its display but not the current one (continued)

    func testAWindowWhoseMembershipWasPartlyDroppedIsAnAnomaly() {
        let partial = window(900, pid: 300, level: 0, onScreen: false, owner: "widgetHUD")
        let result = build(providers(windows: [partial], spaces: [900: [12, 13]]))
        XCTAssertEqual(result.anomalies,
                       ["widgetHUD window #900 (level 0) is on desktops 2, 3 of 4 on DELL U2720Q but not on the one showing (desktop 1)"])
    }

    func testAnOrdinaryWindowOnOneOtherDesktopIsNotAnAnomaly() {
        let notes = window(77, pid: 300, level: 0, onScreen: false, owner: "widgetHUD")
        XCTAssertEqual(build(providers(windows: [notes], spaces: [77: [13]])).anomalies, [])
    }

    func testAWindowOrderedOutOrOnTheShowingDesktopIsNotAnAnomaly() {
        let ordered = window(78, pid: 200, level: 25, onScreen: false, owner: "MacHUDVoice")
        let showing = window(79, pid: 200, level: 25, owner: "MacHUDVoice")
        XCTAssertEqual(build(providers(windows: [ordered, showing], spaces: [78: [], 79: [11, 12]])).anomalies, [])
    }

    func testAnInvisibleWindowIsNotCheckedAgainstTheDesktops() {
        let faded = window(80, pid: 300, level: 25, alpha: 0, onScreen: false, owner: "widgetHUD")
        XCTAssertEqual(build(providers(windows: [faded], spaces: [80: [13]])).anomalies, [])
    }

    // MARK: - Anomalies: the voice host

    func testHiddenForFullScreenNamesTheWindowThatFillsTheScreen() {
        let full = window(50, pid: 400, frame: dell.frame, owner: "Xcode")
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": ["hiddenForFullScreen": true]]
        let result = build(providers(windows: [orb, full], replies: replies))
        XCTAssertEqual(result.anomalies,
                       ["The voice host reports the orb hidden for a full-screen app: Xcode (pid 400) window #50 fills DELL U2720Q"])
    }

    func testHiddenForFullScreenWithNoSuchWindowSaysSo() {
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": ["hiddenForFullScreen": true]]
        let result = build(providers(replies: replies))
        XCTAssertEqual(result.anomalies,
                       ["The voice host reports the orb hidden for a full-screen app, but no layer-0 window fills a screen "
                        + "(frontmost app: Xcode, pid 400)"])
    }

    func testHiddenForFullScreenWithOnlyOtherAppsFullFrameWindowsNamesThem() {
        let other = window(60, pid: 500, frame: dell.frame, owner: "Preview")
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": ["hiddenForFullScreen": true]]
        let result = build(providers(windows: [orb, other], replies: replies))
        XCTAssertEqual(result.anomalies,
                       ["The voice host reports the orb hidden for a full-screen app, but no window of the frontmost app "
                        + "(Xcode, pid 400) fills a screen; full-frame windows of other apps: Preview (pid 500) window #60"])
    }

    func testAVoiceHostThatIsNotConnectedIsAnAnomaly() {
        var replies = healthyReplies
        replies["voiceStatus"] = ["ok": true, "status": "restarting", "connected": false]
        replies["voiceState"] = ["ok": false, "error": "voice host is not reachable"]
        let result = build(providers(windows: [dock], replies: replies))
        XCTAssertEqual(result.anomalies, ["The voice host is not connected (status: restarting)"])
    }

    func testAVoiceHostThatIsOffOrNotInstalledIsNotAnAnomaly() {
        for status in ["disabled", "notInstalled"] {
            var replies = healthyReplies
            replies["voiceStatus"] = ["ok": true, "status": status, "connected": false]
            replies["voiceState"] = ["ok": false, "error": "voice host is not reachable"]
            XCTAssertEqual(build(providers(windows: [dock], replies: replies)).anomalies, [], status)
        }
    }

    func testAMissingVoiceStatusReplyIsAnAnomaly() {
        var replies = healthyReplies
        replies["voiceStatus"] = nil
        XCTAssertEqual(build(providers(replies: replies)).anomalies, ["The voice host's status was not available"])
    }

    func testAConnectedHostThatDoesNotAnswerStateIsAnAnomaly() {
        var replies = healthyReplies
        replies["voiceState"] = ["ok": false, "error": "timed out"]
        XCTAssertEqual(build(providers(replies: replies)).anomalies, ["The voice host did not answer `voice state`: timed out"])
    }

    func testNoVoiceHostWindowOnScreenIsAnAnomalyWhenTheHostIsUp() {
        let ordered = window(812, pid: 200, level: 25, onScreen: false, owner: "MacHUDVoice")
        let result = build(providers(windows: [ordered, dock], spaces: [812: [], 700: everySpace]))
        XCTAssertEqual(result.anomalies, ["No MacHUDVoice window is on screen (the voice host has 1 window, none showing)"])
    }

    func testAHeadlessVoiceHostWithNoWindowsIsNotAnAnomaly() {
        XCTAssertEqual(build(providers(windows: [dock])).anomalies, [])
    }

    func testAMutedVoiceHostStillShowsItsOrbSoAMissingOneIsAnAnomaly() {
        let ordered = window(812, pid: 200, level: 25, onScreen: false, owner: "MacHUDVoice")
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": ["muted": true, "hiddenForFullScreen": false, "phase": ["name": "idle"]]]
        let result = build(providers(windows: [ordered, dock], spaces: [812: [], 700: everySpace], replies: replies))
        XCTAssertEqual(result.anomalies, ["No MacHUDVoice window is on screen (the voice host has 1 window, none showing)"])
    }

    func testAHiddenForFullScreenVoiceHostIsReportedOnlyAsThat() {
        let ordered = window(812, pid: 200, level: 25, onScreen: false, owner: "MacHUDVoice")
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": ["muted": true, "hiddenForFullScreen": true]]
        let result = build(providers(windows: [ordered, dock], spaces: [812: [], 700: everySpace], replies: replies))
        XCTAssertEqual(result.anomalies.count, 1, "\(result.anomalies)")
        XCTAssertTrue(result.anomalies[0].hasPrefix("The voice host reports the orb hidden for a full-screen app"))
    }

    func testNoVoiceHostWindowOnScreenWhileHiddenForFullScreenIsOneAnomalyNotTwo() {
        let ordered = window(812, pid: 200, level: 25, alpha: 0, onScreen: true, owner: "MacHUDVoice")
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": ["hiddenForFullScreen": true]]
        let result = build(providers(windows: [ordered], replies: replies))
        XCTAssertEqual(result.anomalies.count, 1, "\(result.anomalies)")
        XCTAssertTrue(result.anomalies[0].contains("hidden for a full-screen app"))
    }

    // MARK: - Embedded replies

    func testTheFourRepliesAreEmbeddedAsTheyAreExceptForSpokenAndDictatedText() throws {
        var replies = healthyReplies
        replies["voiceState"] = ["ok": true, "state": [
            "phase": ["name": "idle"], "hiddenForFullScreen": false, "muted": false, "inputLevel": 0.25,
            "partialTranscript": "tell my landlord the rent is late",
            "card": ["prompt": "what is on my calendar", "reply": "You have a dentist appointment at 3", "progress": ["reading calendar"]],
        ]]
        let result = build(providers(replies: replies))
        let embedded = try XCTUnwrap(result.document["replies"] as? [String: Any])
        XCTAssertEqual(Set(embedded.keys), ["tooldock", "widgets", "voiceStatus", "voiceState"])
        XCTAssertEqual((embedded["tooldock"] as? [String: Any])?["position"] as? String, "bottom")
        XCTAssertEqual(((embedded["widgets"] as? [String: Any])?["instances"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((embedded["voiceStatus"] as? [String: Any])?["status"] as? String, "running")

        let state = try XCTUnwrap((embedded["voiceState"] as? [String: Any])?["state"] as? [String: Any])
        XCTAssertNil(state["card"])
        XCTAssertNil(state["partialTranscript"])
        XCTAssertEqual(state["inputLevel"] as? Double, 0.25, "everything else is kept")
        XCTAssertEqual((state["phase"] as? [String: Any])?["name"] as? String, "idle")
        XCTAssertEqual((embedded["voiceState"] as? [String: Any])?["redacted"] as? [String], ["card", "partialTranscript"])

        let text = String(decoding: try JSONSerialization.data(withJSONObject: result.document), as: UTF8.self)
        for secret in ["landlord", "calendar", "dentist"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into the snapshot")
        }
    }

    func testARedactionNoteIsAddedOnlyWhenSomethingWasRemoved() throws {
        let embedded = try XCTUnwrap(build(providers()).document["replies"] as? [String: Any])
        let state = try XCTUnwrap(embedded["voiceState"] as? [String: Any])
        XCTAssertEqual(state["redacted"] as? [String], ["partialTranscript"], "healthy state still carries the empty transcript field")
        var replies = healthyReplies
        replies["voiceState"] = ["ok": false, "error": "voice host is not reachable"]
        let failed = try XCTUnwrap(build(providers(replies: replies)).document["replies"] as? [String: Any])
        XCTAssertNil((failed["voiceState"] as? [String: Any])?["redacted"])
    }

    func testAReplyThatWasNotGatheredIsNull() throws {
        var replies = healthyReplies
        replies["widgets"] = nil
        let embedded = try XCTUnwrap(build(providers(replies: replies)).document["replies"] as? [String: Any])
        XCTAssertTrue(embedded["widgets"] is NSNull)
    }

    func testTheDocumentIsAlwaysValidJSON() throws {
        let nan = window(900, pid: 300, level: 0, alpha: .nan, frame: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), owner: "widgetHUD")
        var replies = healthyReplies
        replies["widgets"] = ["ok": true, "when": Date(timeIntervalSince1970: 0), "ratio": Double.nan, "nested": [["x": Float.infinity]]]
        let result = build(providers(windows: [nan], spaces: [900: [11]], replies: replies))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result.document))
        _ = try JSONSerialization.data(withJSONObject: result.document)
        let widgets = try XCTUnwrap((result.document["replies"] as? [String: Any])?["widgets"] as? [String: Any])
        XCTAssertTrue(widgets["ratio"] is NSNull)
        XCTAssertTrue(widgets["when"] is String, "a value JSON cannot hold is written as text")
    }

    // MARK: - Reading the window server

    func testServerWindowReadsOneCGWindowListEntryInCocoaCoordinates() throws {
        let info: [String: Any] = [
            kCGWindowNumber as String: 812, kCGWindowOwnerPID as String: Int32(200), kCGWindowOwnerName as String: "MacHUDVoice",
            kCGWindowLayer as String: 25, kCGWindowAlpha as String: 0.5, kCGWindowIsOnscreen as String: true,
            kCGWindowBounds as String: ["X": 1265.0, "Y": 0.0, "Width": 29.0, "Height": 31.0],
        ]
        let window = try XCTUnwrap(Snapshot.ServerWindow(info: info, primaryHeight: 1440))
        XCTAssertEqual(window.id, 812)
        XCTAssertEqual(window.pid, 200)
        XCTAssertEqual(window.ownerName, "MacHUDVoice")
        XCTAssertEqual(window.level, 25)
        XCTAssertEqual(window.alpha, 0.5)
        XCTAssertTrue(window.isOnScreen)
        XCTAssertEqual(window.frame, CGRect(x: 1265, y: 1409, width: 29, height: 31), "flipped through the primary height")
    }

    func testServerWindowWithoutAnOnScreenKeyIsOffScreen() throws {
        let info: [String: Any] = [
            kCGWindowNumber as String: 1, kCGWindowOwnerPID as String: Int32(7), kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 10.0, "Height": 10.0],
        ]
        let window = try XCTUnwrap(Snapshot.ServerWindow(info: info, primaryHeight: 100))
        XCTAssertFalse(window.isOnScreen)
        XCTAssertEqual(window.ownerName, "")
        XCTAssertEqual(window.alpha, 1, "an entry without alpha is opaque")
        XCTAssertNil(Snapshot.ServerWindow(info: [kCGWindowNumber as String: 1], primaryHeight: 100))
    }
}
