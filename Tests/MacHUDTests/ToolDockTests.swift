import XCTest
import HUDKit
@testable import MacHUDCore

final class ToolDockLayoutTests: XCTestCase {
    let visible = CGRect(x: 0, y: 80, width: 1920, height: 975)
    let l44 = { (p: HUDDockPosition) in ToolDockLayout(position: p, iconSize: 44) }

    func testBottomRowAt44PointsWithDividerBetweenHoverAndWindowed() {
        let l = l44(.bottom)
        XCTAssertEqual(l.padding, 10)
        XCTAssertEqual(l.spacing, 6)
        XCTAssertEqual(l.thickness, 64)
        // 3 hover | 2 windowed: 2*10 + 5*44 + 4*6 + one divider (7 + 6).
        XCTAssertEqual(l.length(groups: [3, 2]), 277)
        let p = l.place(groups: [3, 2], visible: visible)
        XCTAssertEqual(p.frame, CGRect(x: 821.5, y: 86, width: 277, height: 64), "centred, one margin above the edge")
        XCTAssertEqual(p.segments, [p.frame])
        XCTAssertEqual(p.items.map(\.minX), [831.5, 881.5, 931.5, 994.5, 1044.5])
        XCTAssertTrue(p.items.allSatisfy { $0.minY == 96 && $0.size == CGSize(width: 44, height: 44) })
        XCTAssertEqual(p.itemEdges, Array(repeating: .bottom, count: 5))
        XCTAssertEqual(p.dividers.count, 1)
        XCTAssertEqual(p.dividers[0].minX, 984.5, "divider centred between the groups (975.5 ... 994.5)")
        XCTAssertEqual(l.dotCentre(for: p.items[0], edge: .bottom), CGPoint(x: 853.5, y: 91), "dot toward the edge")
        XCTAssertEqual(l.place(groups: [0, 2], visible: visible).dividers, [], "no divider next to an empty group")
        let slot = try! XCTUnwrap(p.slot(0))
        XCTAssertEqual(slot, CGRect(x: 828.5, y: 86, width: 50, height: 64), "hit area spans the bar")
    }

    func testSideColumnsRunTopToBottom() {
        let left = l44(.left).place(groups: [3, 2], visible: visible)
        XCTAssertEqual(left.frame, CGRect(x: 6, y: 429, width: 64, height: 277))
        XCTAssertEqual(left.items.first, CGRect(x: 16, y: 652, width: 44, height: 44))
        XCTAssertEqual(left.items.last?.minY, 439)
        XCTAssertEqual(left.itemEdges.first, .left)
        let right = l44(.right).place(groups: [1], visible: visible)
        XCTAssertEqual(right.frame.maxX, 1914)
        let top = l44(.top).place(groups: [2, 0], visible: visible)
        XCTAssertEqual(top.frame.maxY, visible.maxY - 6)
        XCTAssertEqual(top.frame.midX, 960)
    }

    func testTopLeftIsAnLWithHoverUpTheSideAndWindowedAlongTheTop() {
        let p = l44(.topLeft).place(groups: [3, 2], visible: visible)
        XCTAssertEqual(p.segments.count, 2)
        let (vertical, horizontal) = (p.segments[0], p.segments[1])
        XCTAssertEqual(vertical, CGRect(x: 6, y: 885, width: 64, height: 164), "hover arm: 3 buttons from the corner down")
        XCTAssertEqual(horizontal, CGRect(x: 6, y: 985, width: 177, height: 64), "windowed arm: corner + divider + 2")
        XCTAssertEqual(p.frame, CGRect(x: 6, y: 885, width: 177, height: 164))
        XCTAssertEqual(p.items.prefix(3).map(\.minY), [995, 945, 895])
        XCTAssertEqual(p.items[0], CGRect(x: 16, y: 995, width: 44, height: 44), "first hover button in the corner")
        XCTAssertEqual(p.items.suffix(2).map(\.minX), [79, 129])
        XCTAssertEqual(p.itemEdges, [.left, .left, .left, .top, .top])
        XCTAssertEqual(p.dividers, [CGRect(x: 69, y: 993, width: 1, height: 48)], "divider at the corner's edge")
    }

    /// Every position with both groups: the hover group on the vertical arm (or the row),
    /// the windowed group on the horizontal arm, one divider, all inside the visible frame.
    func testAllEightPositionsWithTwoGroups() {
        let inner = visible.insetBy(dx: 6, dy: 6)
        for position in HUDDockPosition.allCases {
            let p = l44(position).place(groups: [2, 3], visible: visible)
            XCTAssertEqual(p.items.count, 5, "\(position)")
            XCTAssertEqual(p.dividers.count, 1, "\(position)")
            XCTAssertTrue(p.segments.allSatisfy { inner.contains($0) }, "\(position) stays inside")
            for (i, a) in p.items.enumerated() {
                XCTAssertTrue(p.segments.contains { $0.contains(a) }, "\(position) button \(i) on an arm")
                for b in p.items[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(position) buttons overlap") }
            }
            if position.isCorner {
                XCTAssertEqual(p.segments.count, 2, "\(position) is an L")
                let hEdge = position.edges[0], vEdge = position.edges[1]
                XCTAssertEqual(p.itemEdges, [vEdge, vEdge, hEdge, hEdge, hEdge], "\(position): hover vertical, windowed horizontal")
                XCTAssertTrue(p.items.prefix(2).allSatisfy { p.segments[0].contains($0) }, "\(position)")
                XCTAssertTrue(p.items.suffix(3).allSatisfy { p.segments[1].contains($0) && !p.segments[0].intersects($0) },
                              "\(position)")
                let corner = p.segments[0].intersection(p.segments[1])
                XCTAssertEqual(corner.size, CGSize(width: 64, height: 64), "\(position)")
                XCTAssertTrue(corner.contains(p.items[0]), "\(position): first hover button in the corner")
                XCTAssertTrue(p.segments[1].contains(p.dividers[0]), "\(position): divider on the windowed arm")
                // The windowed group reads away from the corner.
                let d = p.items.suffix(3).map { abs($0.midX - corner.midX) }
                XCTAssertEqual(d, d.sorted(), "\(position)")
            } else {
                XCTAssertEqual(p.segments.count, 1, "\(position) is a single row/column")
                XCTAssertEqual(Set(p.itemEdges), [position.edges[0]])
            }
        }
    }

    func testCornerWithOneGroupEmptyIsJustThatArm() {
        let windowedOnly = l44(.topRight).place(groups: [0, 3], visible: visible)
        XCTAssertEqual(windowedOnly.segments, [CGRect(x: 1750, y: 985, width: 164, height: 64)])
        XCTAssertEqual(windowedOnly.items.map(\.minX), [1860, 1810, 1760], "from the corner inward")
        XCTAssertEqual(Set(windowedOnly.itemEdges), [.top])
        XCTAssertTrue(windowedOnly.dividers.isEmpty)
        let hoverOnly = l44(.bottomLeft).place(groups: [2, 0], visible: visible)
        XCTAssertEqual(hoverOnly.segments, [CGRect(x: 6, y: 86, width: 64, height: 114)])
        XCTAssertEqual(hoverOnly.items.map(\.minY), [96, 146])
        XCTAssertEqual(Set(hoverOnly.itemEdges), [.left])
        let bottomRight = l44(.bottomRight).place(groups: [3, 2], visible: visible)
        XCTAssertEqual(bottomRight.items.prefix(3).map(\.minY), [96, 146, 196], "up from the corner")
        XCTAssertEqual(bottomRight.items.suffix(2).map(\.minX), [1797, 1747], "left from the corner")
    }

    func testFittingShrinksIconsSoEveryArmFits() {
        let crowded = ToolDockLayout(position: .bottom, iconSize: 64).fitted(groups: [30, 0], visible: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertLessThanOrEqual(crowded.length(groups: [30]), 1000 - 12)
        XCTAssertLessThan(crowded.iconSize, 64)
        let lTall = ToolDockLayout(position: .topLeft, iconSize: 64).fitted(groups: [20, 1], visible: CGRect(x: 0, y: 0, width: 3000, height: 800))
        XCTAssertLessThanOrEqual(lTall.armLengths(groups: [20, 1]).vertical, 800 - 12)
        XCTAssertEqual(l44(.bottom).fitted(groups: [3, 2], visible: visible).iconSize, 44)
    }

    func testMagnifyGrowsAwayFromTheEdge() {
        let b = CGRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertEqual(ToolDockLayout.magnified(b, edge: .bottom, scale: 1.15).minY, 0)
        XCTAssertEqual(ToolDockLayout.magnified(b, edge: .top, scale: 1.15).maxY, 40, accuracy: 0.001)
        XCTAssertEqual(ToolDockLayout.magnified(b, edge: .right, scale: 1.15).maxX, 40, accuracy: 0.001)
    }

    func testPanelsSlideOutOfTheButtonClearOfTheDock() {
        let p = l44(.bottom).place(groups: [3, 2], visible: visible)
        let slot = p.slot(0)!
        let up = ToolDockLayout.panelFrame(size: CGSize(width: 400, height: 300), slot: slot, edge: .bottom,
                                           dock: p.segments, visible: visible)
        XCTAssertEqual(up, CGRect(x: 653.5, y: 158, width: 400, height: 300), "above the bar, centred on the button")
        let tall = ToolDockLayout.panelFrame(size: CGSize(width: 300, height: 5000), slot: slot, edge: .bottom,
                                             dock: p.segments, visible: visible)
        XCTAssertEqual(tall.minY, 158, "capped to the room above the dock")
        XCTAssertEqual(tall.maxY, visible.maxY - 6)
        let l = l44(.topLeft).place(groups: [3, 2], visible: visible)
        let down = ToolDockLayout.panelFrame(size: CGSize(width: 300, height: 200), slot: l.slot(4)!, edge: .top,
                                             dock: l.segments, visible: visible)
        XCTAssertEqual(down.maxY, 977, "below the horizontal arm")
    }

    /// In a corner a hover panel sits in the crook of the L: past the vertical arm and on
    /// the open side of the horizontal one, never over either.
    func testCornerHoverPanelsSitInTheCrook() {
        for position in HUDDockPosition.allCases {
            let p = l44(position).place(groups: [3, 2], visible: visible)
            for i in 0..<5 {
                let f = ToolDockLayout.panelFrame(size: CGSize(width: 420, height: 480), slot: p.slot(i)!,
                                                  edge: p.itemEdges[i], dock: p.segments, visible: visible)
                for arm in p.segments {
                    XCTAssertFalse(f.intersects(arm), "\(position) item \(i) covers an arm")
                }
                XCTAssertTrue(visible.contains(f), "\(position) item \(i)")
            }
            guard position.isCorner else { continue }
            let f = ToolDockLayout.panelFrame(size: CGSize(width: 420, height: 480), slot: p.slot(0)!,
                                              edge: p.itemEdges[0], dock: p.segments, visible: visible)
            let (v, h) = (p.segments[0], p.segments[1])
            let top = position.edges[0] == .top, left = position.edges[1] == .left
            XCTAssertEqual(left ? f.minX : f.maxX, left ? v.maxX + 8 : v.minX - 8, "\(position)")
            XCTAssertEqual(top ? f.maxY : f.minY, top ? h.minY - 8 : h.maxY + 8, "\(position) tucked into the crook")
        }
    }

    func testAutoHideSlidesPastTheHorizontalEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let l = l44(.bottom)
        let dock = l.place(groups: [3, 0], visible: visible).frame
        XCTAssertEqual(l.hiddenFrame(dock, screen: screen).maxY, 1, "one point left showing")
        XCTAssertEqual(l.revealZone(dock, screen: screen), CGRect(x: dock.minX, y: 0, width: dock.width, height: 4))
        let corner = l44(.topLeft)
        let lFrame = corner.place(groups: [3, 2], visible: visible).frame
        XCTAssertEqual(corner.hiddenFrame(lFrame, screen: screen).minY, 1079, "a top corner hides past the top")
    }
}

final class ToolDockHoverTests: XCTestCase {
    private let a = CGRect(x: 0, y: 0, width: 44, height: 64)
    private let b = CGRect(x: 50, y: 0, width: 44, height: 64)
    private let bar = [CGRect(x: 0, y: 0, width: 300, height: 64)]
    private let panelA = CGRect(x: 0, y: 72, width: 300, height: 200)
    private var buttons: [String: CGRect] { ["a": a, "b": b] }
    private let onA = CGPoint(x: 20, y: 30), onB = CGPoint(x: 70, y: 30), away = CGPoint(x: 900, y: 900)

    func testOrbDefaultsAreUnchanged() {
        XCTAssertEqual(OrbHover().hoverDelay, 0.15)
        XCTAssertEqual(OrbHover().leaveDelay, 0.6)
    }

    func testShowsAfter60msOnTheButton() {
        var h = ToolDockHover()
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 10), [])
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 10.05), [])
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 10.06), [.show("a")])
        // Passing over a button without resting does nothing.
        var quick = ToolDockHover()
        _ = quick.update(mouse: onA, buttons: buttons, region: [], now: 0)
        XCTAssertEqual(quick.update(mouse: away, buttons: buttons, region: [], now: 0.03), [])
        XCTAssertEqual(quick.update(mouse: onA, buttons: buttons, region: [], now: 0.07), [], "the delay restarts")
    }

    func testStaysAnywhereInBarPanelAndBetweenThenHidesAfter120ms() {
        var h = ToolDockHover()
        _ = h.update(mouse: onA, buttons: buttons, region: [], now: 0)
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 0.06), [.show("a")])
        let region = bar + [panelA, CGRect(x: 0, y: 64, width: 300, height: 8)]
        XCTAssertEqual(h.update(mouse: CGPoint(x: 200, y: 30), buttons: buttons, region: region, now: 1), [], "along the bar")
        XCTAssertEqual(h.update(mouse: CGPoint(x: 150, y: 68), buttons: buttons, region: region, now: 2), [], "the gap")
        XCTAssertEqual(h.update(mouse: CGPoint(x: 150, y: 200), buttons: buttons, region: region, now: 3), [], "the panel")
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: region, now: 4), [])
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: region, now: 4.11), [])
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: region, now: 4.12), [.hide("a")])
        XCTAssertNil(h.active)
        // Back inside within the grace keeps it.
        _ = h.update(mouse: onA, buttons: buttons, region: [], now: 5)
        _ = h.update(mouse: onA, buttons: buttons, region: [], now: 5.06)
        _ = h.update(mouse: away, buttons: buttons, region: region, now: 6)
        XCTAssertEqual(h.update(mouse: CGPoint(x: 150, y: 200), buttons: buttons, region: region, now: 6.1), [])
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: region, now: 6.2), [])
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: region, now: 6.3), [])
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: region, now: 6.32), [.hide("a")])
    }

    func testMovingToAnotherHoverButtonShowsItBeforeHidingTheOldOneWithoutWaiting() {
        var h = ToolDockHover()
        _ = h.update(mouse: onA, buttons: buttons, region: [], now: 0)
        _ = h.update(mouse: onA, buttons: buttons, region: [], now: 0.06)
        XCTAssertEqual(h.update(mouse: onB, buttons: buttons, region: bar, now: 0.07), [.show("b"), .hide("a")],
                       "cross-fade: new first, at once")
        XCTAssertEqual(h.active, "b")
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: bar, now: 0.08), [.show("a"), .hide("b")])
    }

    func testClickPinsAndSecondClickHidesUntilThePointerLeaves() {
        var h = ToolDockHover()
        XCTAssertEqual(h.click("a"), [.show("a")])
        XCTAssertTrue(h.isPinned("a"))
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: [], now: 1), [])
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: [], now: 5), [], "pinned: leaving keeps it")
        // Hovering another shows it beside the pinned one.
        _ = h.update(mouse: onB, buttons: buttons, region: [], now: 6)
        XCTAssertEqual(h.update(mouse: onB, buttons: buttons, region: [], now: 6.06), [.show("b")])
        XCTAssertEqual(h.shown, ["a", "b"])
        _ = h.update(mouse: away, buttons: buttons, region: bar, now: 7)
        XCTAssertEqual(h.update(mouse: away, buttons: buttons, region: bar, now: 7.2), [.hide("b")])
        XCTAssertEqual(h.click("a"), [.hide("a")])
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 8), [])
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 9), [], "clicked shut: no re-show")
        _ = h.update(mouse: away, buttons: buttons, region: [], now: 10)
        _ = h.update(mouse: onA, buttons: buttons, region: [], now: 11)
        XCTAssertEqual(h.update(mouse: onA, buttons: buttons, region: [], now: 11.06), [.show("a")])
        // Clicking the active hover pins it without another show.
        XCTAssertEqual(h.click("a"), [])
        XCTAssertTrue(h.isPinned("a"))
        XCTAssertEqual(h.retain(["b"]), [.hide("a")])
    }

    func testOpenFromOutsideTakesOverAndCloseHides() {
        var h = ToolDockHover()
        XCTAssertEqual(h.open("a", pin: false), [.show("a")])
        XCTAssertEqual(h.open("b", pin: false), [.show("b"), .hide("a")])
        XCTAssertEqual(h.open("b", pin: true), [])
        XCTAssertTrue(h.isPinned("b"))
        XCTAssertEqual(h.close("b"), [.hide("b")])
        XCTAssertEqual(h.close("b"), [])
    }
}

@MainActor
final class ToolDockMemoryTests: XCTestCase {
    func testRememberedFramesPersistAndMustStillBeOnScreen() {
        let dir = FakeBundles.tempDir("tdmem")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ToolDockStore(url: dir.appendingPathComponent("state/tooldock.json"))
        var state = store.load()
        XCTAssertEqual(state, ToolDockState())
        state.remember(CGRect(x: 100, y: 100, width: 800, height: 600), for: "xyz.machud.sift/browser")
        state.remember(CGRect(x: 0, y: 0, width: 0, height: 0), for: "empty")
        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded.frames.count, 1)
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(loaded.frame(for: "xyz.machud.sift/browser", screens: screens), CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertNil(loaded.frame(for: "xyz.machud.sift/browser", screens: [CGRect(x: 5000, y: 0, width: 100, height: 100)]),
                     "a frame on a display that is gone is not restored")
    }

    func testConfigDefaultsAndSettingsRoundTrip() {
        let c = ToolDockConfig()
        XCTAssertTrue(c.isEnabled)
        XCTAssertEqual(c.dockPosition, .bottom)
        XCTAssertFalse(c.isAutoHide)
        XCTAssertEqual(c.icon, 44)
        XCTAssertEqual(ToolDockConfig(iconSize: 500).icon, 96)

        var config = Config.defaults
        var values = MacHUDSettings.values(config: config, enabled: true, orbsHidden: true)
        XCTAssertEqual(values["toolDock.enabled"] as? Bool, true)
        XCTAssertEqual(values["toolDock.position"] as? String, "bottom")
        XCTAssertNil(values["toolDock.edge"])
        let parsed = try! MacHUDSettings.schema.validate(["toolDock.position": "topLeft",
                                                            "toolDock.autoHide": "true", "toolDock.iconSize": "56"])
        config = MacHUDSettings.applying(parsed, to: config)
        XCTAssertEqual(config.toolDock, ToolDockConfig(position: .topLeft, autoHide: true, iconSize: 56))
        values = MacHUDSettings.values(config: config, enabled: true, orbsHidden: true)
        XCTAssertEqual(values["toolDock.position"] as? String, "topLeft")
        XCTAssertEqual(values["toolDock.iconSize"] as? Int, 56)
        let data = try! JSONEncoder().encode(config)
        XCTAssertEqual(try! JSONDecoder().decode(Config.self, from: data).toolDock, config.toolDock)
        XCTAssertThrowsError(try MacHUDSettings.schema.validate(["toolDock.position": "middle"]))
    }

    func testEdgeAndOffsetMigrateToPosition() throws {
        let old = #"{"toolDock": {"edge": "left", "offset": 0.3, "iconSize": 40}}"#
        let migrated = try JSONDecoder().decode(Config.self, from: Data(old.utf8)).toolDock
        XCTAssertEqual(migrated, ToolDockConfig(position: .left, iconSize: 40))
        let written = String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self)
        XCTAssertTrue(written.contains(#""position":"left""#), written)
        XCTAssertFalse(written.contains("edge") || written.contains("offset"), "the old keys are not written back: \(written)")
        let both = #"{"toolDock": {"position": "topRight", "edge": "left"}}"#
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(both.utf8)).toolDock?.position, .topRight)
        let bogus = #"{"toolDock": {"position": "middle"}}"#
        XCTAssertNil(try JSONDecoder().decode(Config.self, from: Data(bogus.utf8)).toolDock?.position, "unknown: default")
        XCTAssertNil(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).toolDock)
    }
}

/// The dock driven headless: fake sibling apps, fake sockets, synthetic pointer.
@MainActor
final class ToolDockControllerTests: XCTestCase {
    private let scratchID = "dev.test.scratch", stashID = "dev.test.stash", siftID = "dev.test.sift"
    private let scratchSock = "/tmp/td-scratch.sock", stashSock = "/tmp/td-stash.sock", siftSock = "/tmp/td-sift.sock"
    private var dir: URL!
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var registry: PanelRegistry!
    private var externals: ExternalPanels!
    private var dock: ToolDock!
    private var config = ToolDockConfig()
    private let screen = ToolDockScreen(name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                        visible: CGRect(x: 0, y: 80, width: 1920, height: 975))

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("tdctl")
        workspace = FakeWorkspace()
        workspace.installed = [scratchID, stashID, siftID]
        connector = FakeConnector()
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned clock] in clock!.now }
        registry = PanelRegistry()
        externals = ExternalPanels(registry: registry, supervisor: supervisor) { AppsConfig() }
        // Names sort Scratch, Sift, Stash; `order` puts Stash before Scratch in the hover group.
        let scratch = ExternalApp(manifest: HUDManifest(id: scratchID, name: "Scratch", socket: scratchSock, panels: [
            HUDManifest.Panel(id: "pad", title: "Scratch", defaultSize: HUDSize(width: 400, height: 300),
                              verbs: ["show", "hide", "frame"], kind: .hover)]),
                                  bundleURL: dir.appendingPathComponent("Scratch.app"))
        let stash = ExternalApp(manifest: HUDManifest(id: stashID, name: "Stash", socket: stashSock, panels: [
            HUDManifest.Panel(id: "shelf", title: "Stash", defaultSize: HUDSize(width: 300, height: 200),
                              capabilities: [HUDDrop.capability], verbs: ["show", "hide", "frame"], kind: .hover, order: 1)]),
                                bundleURL: dir.appendingPathComponent("Stash.app"))
        let sift = ExternalApp(manifest: HUDManifest(id: siftID, name: "Sift", socket: siftSock, panels: [
            HUDManifest.Panel(id: "browser", title: "Sift", verbs: ["show", "hide", "frame"])]),
                               bundleURL: dir.appendingPathComponent("Sift.app"))
        for (id, sock) in [(scratchID, scratchSock), (stashID, stashSock), (siftID, siftSock)] {
            workspace.running[id] = [4242]
            connector.reachable.insert(sock)
        }
        externals.install([scratch, sift, stash], autoLaunch: [])
        dock = ToolDock(registry: registry, externals: externals, config: { [unowned self] in self.config },
                        saveConfig: { [unowned self] in self.config = $0 },
                        stateURL: dir.appendingPathComponent("tooldock.json"), ui: false)
        dock.screens = { [unowned self] in [self.screen] }
        dock.dockRegistry = HUDDockRegistry(url: dir.appendingPathComponent("docks.json"))
        dock.registryID = "test.machud"
        registry.register(dock)
        dock.refresh()
        connector.requests = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func panelRequests(_ sock: String) -> [[String: String]] {
        connector.requests.filter { $0.path == sock && $0.command == "panel" }.map(\.args)
    }

    private func centre(_ id: String) throws -> CGPoint {
        let f = try XCTUnwrap(dock.buttonFrame(id))
        return CGPoint(x: f.midX, y: f.midY)
    }

    func testOneListHoverAppsFirstThenWindowed() {
        XCTAssertEqual(dock.items.map(\.title), ["Stash", "Scratch", "Sift"], "hover by order then name, then windowed")
        XCTAssertEqual(dock.items.map(\.behaviour), [.hover, .hover, .windowed])
        XCTAssertEqual(dock.items.map(\.group), [0, 0, 1])
        XCTAssertEqual(dock.items.map(\.acceptsDrop), [true, false, false])
        XCTAssertEqual(dock.indicator(for: dock.items[2]), .running)
        XCTAssertEqual(dock.geometry()?.placement.dividers.count, 1)
    }

    func testHoverShowsSlidingFromTheButtonStaysOverThePanelAndHidesQuickly() throws {
        let on = try centre(scratchID)
        dock.step(mouse: on, now: 10)
        dock.step(mouse: on, now: 10.05)
        XCTAssertTrue(panelRequests(scratchSock).isEmpty, "not before 60 ms")
        dock.step(mouse: on, now: 10.06)
        let sent = panelRequests(scratchSock)
        XCTAssertEqual(sent.map { $0["action"] }, ["frame", "show"], "positioned first, then shown")
        let slot = try XCTUnwrap(dock.slot(scratchID))
        XCTAssertEqual(sent[1]["from"], "bottom")
        XCTAssertEqual(sent[1]["reason"], "hover")
        XCTAssertEqual(sent[1]["anchor"], HUDPanelTransition.formatAnchor(slot.frame))
        let frame = try XCTUnwrap(dock.hoverFrames[scratchID])
        XCTAssertEqual(frame.size, CGSize(width: 400, height: 300), "the manifest's default size")
        XCTAssertEqual(frame.midX, slot.frame.midX, accuracy: 0.5)
        XCTAssertEqual(frame.minY, slot.frame.maxY + ToolDockLayout.panelGap)
        XCTAssertEqual(dock.indicator(for: dock.items[1]), .visible)

        // Down through the gap into the panel: stays.
        dock.step(mouse: CGPoint(x: frame.midX, y: slot.frame.maxY + 4), now: 11)
        dock.step(mouse: CGPoint(x: frame.midX, y: frame.midY), now: 12)
        dock.step(mouse: CGPoint(x: frame.midX, y: frame.midY), now: 13)
        XCTAssertEqual(panelRequests(scratchSock).count, 2)
        // Away: gone after the 120 ms grace.
        dock.step(mouse: CGPoint(x: 1500, y: 900), now: 14)
        dock.step(mouse: CGPoint(x: 1500, y: 900), now: 14.1)
        XCTAssertEqual(panelRequests(scratchSock).count, 2)
        dock.step(mouse: CGPoint(x: 1500, y: 900), now: 14.12)
        let hide = try XCTUnwrap(panelRequests(scratchSock).last)
        XCTAssertEqual(hide["action"], "hide")
        XCTAssertEqual(hide["to"], "bottom")
        XCTAssertNil(dock.hoverFrames[scratchID])
    }

    func testMovingAcrossHoverButtonsCrossFadesShowBeforeHide() throws {
        let stash = try centre(stashID), scratch = try centre(scratchID)
        dock.step(mouse: stash, now: 1)
        dock.step(mouse: stash, now: 1.06)
        connector.requests = []
        dock.step(mouse: scratch, now: 1.1)
        let order = connector.requests.filter { $0.command == "panel" }.map { "\($0.path == scratchSock ? "scratch" : "stash") \($0.args["action"]!)" }
        XCTAssertEqual(order, ["scratch frame", "scratch show", "stash hide"], "the new one shows first, at once")
    }

    func testClickPinsAHoverPanelAndWindowedClickSummonsWithReasonClick() {
        dock.click(dock.items[1], anchor: nil)
        XCTAssertEqual(panelRequests(scratchSock).map { $0["action"] }, ["frame", "show"])
        dock.step(mouse: CGPoint(x: 1500, y: 900), now: 1)
        dock.step(mouse: CGPoint(x: 1500, y: 900), now: 5)
        XCTAssertEqual(panelRequests(scratchSock).count, 2, "pinned: leaving does not hide")
        dock.click(dock.items[1], anchor: nil)
        XCTAssertEqual(panelRequests(scratchSock).last?["action"], "hide")

        dock.click(dock.items[2], anchor: nil)
        let show = panelRequests(siftSock).last
        XCTAssertEqual(show?["action"], "show")
        XCTAssertEqual(show?["reason"], "click")
        XCTAssertEqual(show?["from"], "bottom")
    }

    func testDraggingTheStripClosesHoverPanelsAndOpensNoneUntilItEnds() throws {
        let strip = HUDDockStripView()
        let scratch = try centre(scratchID)
        dock.step(mouse: scratch, now: 1)
        dock.step(mouse: scratch, now: 1.06)
        dock.click(dock.items[0], anchor: nil)  // Stash pinned
        dock.click(dock.items[2], anchor: nil)  // Sift, windowed
        XCTAssertEqual(dock.hover.shown, [stashID, scratchID].sorted())
        connector.requests = []

        dock.dockStripDidBeginDrag(strip)
        XCTAssertTrue(dock.isDragging)
        XCTAssertEqual(dock.hover.shown, [], "pinned or hovered, hover panels go")
        for sock in [scratchSock, stashSock] {
            let hide = try XCTUnwrap(panelRequests(sock).last)
            XCTAssertEqual(hide["action"], "hide")
            XCTAssertEqual(hide["to"], "bottom", "back into the button")
        }
        XCTAssertTrue(panelRequests(siftSock).isEmpty, "a windowed panel is a window: it stays")
        // Over a hover button mid-drag: nothing opens.
        dock.step(mouse: scratch, now: 2)
        dock.step(mouse: scratch, now: 3)
        XCTAssertEqual(panelRequests(scratchSock).count, 1)

        dock.dockStrip(strip, didDragTo: .bottom, at: CGPoint(x: 960, y: 100), on: nil)
        dock.dockStripDidEndDrag(strip)
        XCTAssertFalse(dock.isDragging)
        XCTAssertFalse(dock.hover.isPinned(stashID), "the drag left nothing pinned")
        // Hovering works again afterwards.
        dock.step(mouse: scratch, now: 4)
        dock.step(mouse: scratch, now: 4.06)
        XCTAssertEqual(panelRequests(scratchSock).last?["action"], "show")
    }

    func testOnlyWindowedButtonsHaveAHoverLabel() {
        let strip = dock.items.map { $0.stripItem(indicator: .none) }
        XCTAssertEqual(strip.map(\.label), [nil, nil, "Sift"], "hover buttons show their panel instead")
        XCTAssertEqual(dock.json["buttons"].flatMap { ($0 as? [[String: Any]])?.compactMap { $0["label"] as? String } }, ["Sift"])
    }

    func testWindowedSummonComesBackToTheRememberedFrameThenDismisses() {
        var reply = dock.handleSummon(["id": "Sift"], summon: true)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(panelRequests(siftSock).map { $0["action"] }, ["show"], "nothing remembered yet")
        XCTAssertEqual(panelRequests(siftSock).last?["reason"], "summon")
        // The app reports it visible, with its frame.
        connector.onEvents[siftSock]?(["event": "state", "panels": [["id": "browser", "visible": true,
                                                                     "frame": [200, 150, 900, 560]]]])
        XCTAssertEqual(dock.indicator(for: dock.items[2]), .visible)
        connector.requests = []
        reply = dock.handleSummon(["id": siftID], summon: false)
        XCTAssertEqual(panelRequests(siftSock).map { $0["action"] }, ["hide"])
        XCTAssertEqual(reply["remembered"] as? [String: Int], ["x": 200, "y": 150, "w": 900, "h": 560],
                       "the frame the app reported")
        connector.onEvents[siftSock]?(["event": "state", "panels": [["id": "browser", "visible": false]]])
        connector.requests = []
        reply = dock.handleSummon(["id": "\(siftID)/browser"], summon: true)
        XCTAssertEqual(reply["frame"] as? [String: Int], ["x": 200, "y": 150, "w": 900, "h": 560])
        XCTAssertEqual(panelRequests(siftSock).map { $0["action"] }, ["frame", "show"])
    }

    func testDismissOfAnAppThatIsNotRunningDoesNotLaunchIt() {
        workspace.stop(siftID)
        let reply = dock.handleSummon(["id": siftID], summon: false)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertTrue(workspace.launches.isEmpty)
        XCTAssertTrue(panelRequests(siftSock).isEmpty)
    }

    func testDropsGoToAcceptingButtonsOnlyAndSpringLoadOpens() throws {
        let files = [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/x|y.mov")]
        XCTAssertFalse(dock.drop(files, on: siftID), "Sift does not take files")
        XCTAssertTrue(dock.drop(files, on: stashID))
        let action = try XCTUnwrap(connector.requests.last { $0.command == "action" })
        XCTAssertEqual(action.path, stashSock)
        XCTAssertEqual(action.args["name"], "drop")
        XCTAssertEqual(action.args["paths"], HUDDrop.encode(files))
        XCTAssertNil(action.args["id"], "a one-panel app gets no id=")
        dock.springLoad(stashID)
        XCTAssertEqual(panelRequests(stashSock).map { $0["action"] }, ["frame", "show"])
        XCTAssertTrue(dock.hover.isShown(stashID))
        // A not-running app is launched for the drop.
        workspace.stop(stashID)
        workspace.launches = []
        XCTAssertTrue(dock.drop(files, on: stashID))
        XCTAssertEqual(workspace.launches, [stashID])
        let reply = dock.handle(["action": "drop", "id": "Sift", "paths": "/tmp/a"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
    }

    func testTooldockVerbsAndRegistry() throws {
        var reply = dock.handle(["_": "state"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["position"] as? String, "bottom")
        let buttons = try XCTUnwrap(reply["buttons"] as? [[String: Any]])
        XCTAssertEqual(buttons.map { $0["group"] as? String }, ["hover", "hover", "windowed"])
        XCTAssertEqual(buttons.first?["acceptsDrop"] as? Bool, true)
        XCTAssertNotNil(reply["neighbors"] as? [String: Any])

        reply = dock.handle(["action": "position", "position": "top-left"])
        XCTAssertEqual(reply["position"] as? String, "topLeft")
        XCTAssertEqual(config.position, .topLeft)
        XCTAssertEqual((reply["segments"] as? [[String: Int]])?.count, 2, "an L")
        reply = dock.handle(["action": "position", "edge": "right"])
        XCTAssertEqual(config.position, .right)
        XCTAssertEqual((reply["frame"] as? [String: Int])?["x"], 1914 - 64)
        XCTAssertEqual(dock.handle(["action": "position", "position": "middle"])["ok"] as? Bool, false)
        XCTAssertEqual(dock.handle(["action": "position", "offset": "0.2"])["ok"] as? Bool, false)
        XCTAssertEqual(dock.handle(["action": "position"])["ok"] as? Bool, false)

        // Every move is published for sibling strips.
        let entry = try XCTUnwrap(dock.dockRegistry?.entry(for: "test.machud"))
        XCTAssertEqual(entry.position, .right)
        XCTAssertEqual(entry.frames, dock.geometry()?.placement.segments)
        _ = dock.handle(["action": "position", "position": "bottomLeft"])
        XCTAssertEqual(dock.dockRegistry?.entry(for: "test.machud")?.position, .bottomLeft)
        XCTAssertEqual(dock.dockRegistry?.entry(for: "test.machud")?.frames.count, 2)
        // A neighbour shows up in state.
        let sift = HUDDockRegistry(url: dir.appendingPathComponent("docks.json"))
        try sift.publish(appID: "xyz.machud.sift", position: .left, frames: [CGRect(x: 0, y: 200, width: 40, height: 400)])
        XCTAssertTrue(spin { (self.dock.handle(["_": "state"])["neighbors"] as? [String: Any])?["xyz.machud.sift"] != nil })
        _ = dock.handle(["_": "hide"])
        XCTAssertNil(dock.dockRegistry?.entry(for: "test.machud"), "withdrawn when turned off")

        reply = dock.handle(["autohide": "1"])
        XCTAssertEqual(reply["autoHide"] as? Bool, true)
        reply = dock.handle(["toggle": "1"])
        XCTAssertEqual(reply["enabled"] as? Bool, true)
        XCTAssertEqual(dock.handle(["_": "bogus"])["ok"] as? Bool, false)
        reply = dock.handle(["action": "click", "id": "Scratch"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(panelRequests(scratchSock).map { $0["action"] }, ["frame", "show"])
        XCTAssertEqual(dock.handleSummon(["id": "nope"], summon: true)["ok"] as? Bool, false)
    }

    func testDragAndRegionsSnapToTheNearestOfEightPositions() {
        dock.finishDrag(at: CGPoint(x: 40, y: 1000))
        XCTAssertEqual(config.position, .topLeft)
        dock.finishDrag(at: CGPoint(x: 960, y: 100))
        XCTAssertEqual(config.position, .bottom)
        dock.finishDrag(at: CGPoint(x: 1900, y: 560))
        XCTAssertEqual(config.position, .right)
        dock.place(inRegion: CGRect(x: 1700, y: 80, width: 220, height: 975))
        XCTAssertEqual(config.position, .right)
        dock.place(inRegion: CGRect(x: 0, y: 955, width: 300, height: 100))
        XCTAssertEqual(config.position, .topLeft)
    }

    func testOrbsHiddenByDefaultWhileTheDockIsOn() {
        let parking = ParkingController(panels: registry, stateURL: dir.appendingPathComponent("parking.json"))
        dock.parking = parking
        dock.refresh()
        XCTAssertTrue(parking.orbsHidden)
        config.enabled = false
        dock.refresh()
        XCTAssertFalse(parking.orbsHidden)
        parking.setOrbsHidden(true)
        XCTAssertTrue(parking.orbsHidden, "an explicit choice wins over the default")
    }
}
