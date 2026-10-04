import AppKit
import XCTest
@testable import MacHUDCore

/// The planner's decision table (`PlacementPlan`) against fake window lists across
/// displays and desktops. `step(_:_:)` plans with multi-desktop loadouts on (`spaces.policy`
/// decides, `bring` by default); the `oneScreen` tests plan with them off.
final class PlacementPlanTests: XCTestCase {
    typealias P = PlacementPlan
    // Main 2560×1440 showing desktop 3 of 4; built-in to its right showing its only desktop.
    let screens = [
        P.Screen(name: "DELL", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), currentSpace: 3, spaces: 4),
        P.Screen(name: "Built-in", frame: CGRect(x: 2560, y: 0, width: 1728, height: 1117), currentSpace: 1, spaces: 1),
    ]
    let rect = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func slot(_ candidates: [P.Candidate], screen: Int = 0, space: Int? = nil, running: Bool = true,
                      installed: Bool = true, newWindow: NewWindowClass = .single) -> P.SlotInput {
        P.SlotInput(regionID: "r", regionName: "Left", occupant: "Signal", screen: screen, space: space, rect: rect,
                    candidates: candidates, running: running, installed: installed, newWindow: newWindow)
    }

    private func win(_ n: Int, screen: Int, space: Int?, visible: Bool, frame: CGRect? = nil,
                     minimized: Bool = false) -> P.Candidate {
        P.Candidate(number: n, frame: frame ?? CGRect(x: 10, y: 10, width: 300, height: 300), screen: screen,
                    space: space, visible: visible, minimized: minimized)
    }

    private func step(_ s: P.SlotInput, _ policy: SpacesPolicy = .bring) -> P.Step {
        P.step(for: s, screens: screens, mode: .multiDesktop(policy))
    }

    func testWindowAlreadyInPlaceStays() {
        let s = step(slot([win(1, screen: 0, space: 3, visible: true, frame: rect)]))
        XCTAssertEqual(s.action, .stay)
        XCTAssertEqual(s.window, 1)
    }

    func testWindowOnThisDisplayIsResized() {
        let s = step(slot([win(1, screen: 0, space: 3, visible: true)]))
        XCTAssertEqual(s.action, .resize)
        XCTAssertEqual(s.from?.screen, "DELL")
        XCTAssertEqual(s.to.frame, rect)
    }

    /// Report 4: an app already open on the other display is moved, not failed.
    func testWindowOnOtherDisplayIsMoved() {
        let s = step(slot([win(1, screen: 1, space: 1, visible: true)]))
        XCTAssertEqual(s.action, .move)
        XCTAssertEqual(s.from?.screen, "Built-in")
        XCTAssertEqual(s.to.screen, "DELL")
        XCTAssertEqual(s.to.space, 3)
    }

    func testVisibleWindowBeatsOneOnAHiddenDesktop() {
        let s = step(slot([win(1, screen: 0, space: 1, visible: false), win(2, screen: 1, space: 1, visible: true)]))
        XCTAssertEqual(s.window, 2)
        XCTAssertEqual(s.action, .move)
    }

    func testMinimizedWindowIsRestored() {
        let s = step(slot([win(1, screen: 0, space: nil, visible: false, minimized: true)]))
        XCTAssertEqual(s.action, .resize)
        XCTAssertTrue(s.reason.contains("Dock"))
    }

    func testHiddenDesktopOnOtherDisplayIsBroughtAcross() {
        // The window is on built-in desktop 1 (pretend it had two and shows 2), target DELL.
        var screens = self.screens
        screens[1].currentSpace = 2
        screens[1].spaces = 2
        let s = P.step(for: slot([win(1, screen: 1, space: 1, visible: false)]), screens: screens, mode: .multiDesktop(.bring))
        XCTAssertEqual(s.action, .switchSpace)
        XCTAssertEqual(s.bring, .acrossDisplays(fromScreen: 1, space: 1))
    }

    func testHiddenDesktopOnSameDisplayHopsThroughTheOther() {
        let s = step(slot([win(1, screen: 0, space: 1, visible: false)]))
        XCTAssertEqual(s.action, .switchSpace)
        XCTAssertEqual(s.bring, .hop(screen: 0, space: 1, via: 1))
        XCTAssertEqual(s.from?.space, 1)
    }

    func testOneDisplaySingleWindowAppCannotBeBrought() {
        let one = [screens[0]]
        let s = P.step(for: slot([win(1, screen: 0, space: 1, visible: false)]), screens: one, mode: .multiDesktop(.bring))
        XCTAssertEqual(s.action, .cannot)
        XCTAssertTrue(s.reason.contains("one window"), s.reason)
        XCTAssertTrue(s.reason.contains("desktop 1"), s.reason)
    }

    func testOneDisplayMenuAppFallsBackToANewWindow() {
        let one = [screens[0]]
        let s = P.step(for: slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .menu),
                       screens: one, mode: .multiDesktop(.bring))
        XCTAssertEqual(s.action, .launch)
        XCTAssertTrue(s.newWindow)
        XCTAssertNil(s.window)
    }

    func testLaunchNewPolicy() {
        let browser = step(slot([win(1, screen: 0, space: 2, visible: false)], newWindow: .browser), .launchNew)
        XCTAssertEqual(browser.action, .launch)
        XCTAssertTrue(browser.newWindow)
        let chat = step(slot([win(1, screen: 0, space: 2, visible: false)], newWindow: .single), .launchNew)
        XCTAssertEqual(chat.action, .cannot)
    }

    func testLeavePolicy() {
        let s = step(slot([win(1, screen: 0, space: 2, visible: false)]), .leave)
        XCTAssertEqual(s.action, .leave)
        XCTAssertFalse(s.places)
    }

    func testNotRunningLaunches() {
        let s = step(slot([], running: false))
        XCTAssertEqual(s.action, .launch)
        XCTAssertFalse(s.newWindow, "a launch opens its own first window")
    }

    func testNotInstalledCannot() {
        let s = step(slot([], running: false, installed: false))
        XCTAssertEqual(s.action, .cannot)
        XCTAssertTrue(s.reason.contains("not installed"))
    }

    func testSlotDesktopSwitchesFirst() {
        // Slot wants DELL desktop 2; its window sits on desktop 2 already.
        let s = step(slot([win(1, screen: 0, space: 2, visible: false)], space: 2))
        XCTAssertEqual(s.action, .switchSpace)
        XCTAssertNil(s.bring)
        XCTAssertEqual(s.to.space, 2)
    }

    func testSlotDesktopLeavesTheShowingDesktopsWindowBehind() {
        // Slot wants desktop 2, the window is on desktop 3 (showing): switching would strand it.
        let s = step(slot([win(1, screen: 0, space: 3, visible: true)], space: 2))
        XCTAssertEqual(s.action, .switchSpace)
        XCTAssertEqual(s.bring, .hop(screen: 0, space: 3, via: 1))
    }

    func testBlockedSlotCannot() {
        var input = slot([])
        input.blocked = "no panel dock"
        XCTAssertEqual(step(input).action, .cannot)
    }

    func testPlanJSONShape() {
        let s = step(slot([win(7, screen: 1, space: 1, visible: true)]))
        let json = s.json
        XCTAssertEqual(json["action"] as? String, "move")
        XCTAssertEqual(json["slot"] as? String, "r")
        XCTAssertEqual((json["from"] as? [String: Any])?["screen"] as? String, "Built-in")
        XCTAssertEqual(((json["to"] as? [String: Any])?["frame"] as? [String: Int])?["w"], 800)
    }

    func testSpacesConfigDecodes() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"spaces": {"policy": "launchNew"}}"#.utf8))
        XCTAssertEqual(c.spaces?.effectivePolicy, .launchNew)
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(none.spaces?.effectivePolicy ?? .bring, .bring)
    }

    // MARK: Multi-desktop loadouts off: the desktop showing only

    private func oneScreen(_ s: P.SlotInput, screens: [P.Screen]? = nil) -> P.Step {
        P.step(for: s, screens: screens ?? self.screens, mode: .oneScreen)
    }

    func testOneScreenOpensANewWindowForAnAppThatCan() {
        // Its only window is on hidden desktop 1 of this display, and a second display could
        // carry it across: with the feature off an app that can open a window gets a new one here.
        for kind in [NewWindowClass.menu, .browser] {
            let s = oneScreen(slot([win(1, screen: 0, space: 1, visible: false)], newWindow: kind))
            XCTAssertEqual(s.action, .launch, "\(kind)")
            XCTAssertTrue(s.newWindow, "\(kind)")
            XCTAssertNil(s.bring, "\(kind)")
            XCTAssertNil(s.window, "\(kind)")
        }
    }

    /// The owner's ruling: a single-window app's window is fetched from the other desktop (the one
    /// desktop switch an apply makes with the feature off), in today's `bring` wording.
    func testOneScreenFetchesASingleWindowAppsWindow() {
        let here = oneScreen(slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .single))
        XCTAssertEqual(here.action, .switchSpace)
        XCTAssertEqual(here.bring, .hop(screen: 0, space: 1, via: 1))
        XCTAssertEqual(here.window, 1)
        XCTAssertEqual(here.reason, "show desktop 1, hop it through Built-in, switch back")
        var screens = self.screens
        screens[1].currentSpace = 2
        screens[1].spaces = 2
        let there = oneScreen(slot([win(1, screen: 1, space: 1, visible: false)], newWindow: .single), screens: screens)
        XCTAssertEqual(there.bring, .acrossDisplays(fromScreen: 1, space: 1))
        XCTAssertEqual(there.reason, "show desktop 1 on Built-in, move it to DELL, switch back")
    }

    /// A page in Arc: its window on another desktop is fetched, since a new Arc window would
    /// open on Arc's own desktop too.
    func testOneScreenFetchesAnArcPage() {
        var input = slot([win(1, screen: 0, space: 1, visible: false)],
                         newWindow: NewWindowClass.forWeb(host: .arc, configuredBrowser: nil))
        input.kind = .web
        let s = oneScreen(input)
        XCTAssertEqual(s.action, .switchSpace)
        XCTAssertNotNil(s.bring)
    }

    /// With one display there is nothing to carry it across: the slot is left and names the app.
    func testOneScreenLeavesASingleWindowAppItCannotFetchAndNamesIt() {
        let s = oneScreen(slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .single), screens: [screens[0]])
        XCTAssertEqual(s.action, .cannot)
        XCTAssertFalse(s.places)
        XCTAssertNil(s.bring)
        XCTAssertTrue(s.reason.hasPrefix("Signal has one window, on another desktop (desktop 1 of DELL; "), s.reason)
    }

    func testOneScreenDoesNotFetchWhatBringWould() {
        // On built-in desktop 1 while it shows 2: `bring` would show desktop 1 there and carry it over.
        var screens = self.screens
        screens[1].currentSpace = 2
        screens[1].spaces = 2
        let input = slot([win(1, screen: 1, space: 1, visible: false)], newWindow: .menu)
        XCTAssertEqual(P.step(for: input, screens: screens, mode: .multiDesktop(.bring)).bring, .acrossDisplays(fromScreen: 1, space: 1))
        let s = oneScreen(input, screens: screens)
        XCTAssertEqual(s.action, .launch)
        XCTAssertTrue(s.newWindow)
        XCTAssertNil(s.bring)
    }

    /// The only desktop switch with the feature off is fetching a single-window app's window from
    /// a hidden desktop: never for an app that can open a window, never for a window in reach,
    /// and never because a slot names a desktop.
    func testOneScreenSwitchesOnlyToFetchASingleWindowApp() {
        let hidden: [P.Candidate] = [win(1, screen: 0, space: 1, visible: false), win(2, screen: 1, space: 2, visible: false)]
        let inReach: [P.Candidate] = [
            win(3, screen: 0, space: nil, visible: false), win(4, screen: 0, space: 3, visible: true),
            win(5, screen: 1, space: 1, visible: true), win(6, screen: 0, space: nil, visible: false, minimized: true),
        ]
        for kind in [NewWindowClass.menu, .browser, .single] {
            for candidates in [[]] + (hidden + inReach).map({ [$0] }) {
                for space in [nil, 2] {
                    let s = oneScreen(slot(candidates, space: space, newWindow: kind))
                    let fetches = kind == .single && candidates.count == 1 && hidden.contains(candidates[0])
                    let what = "\(kind) \(candidates) slot desktop \(space as Any): \(s.reason)"
                    XCTAssertEqual(s.action == .switchSpace, fetches, what)
                    XCTAssertEqual(s.bring != nil, fetches, what)
                }
            }
        }
    }

    func testOneScreenStillMovesAcrossDisplaysAndRestoresFromTheDock() {
        let other = oneScreen(slot([win(1, screen: 1, space: 1, visible: true)]))
        XCTAssertEqual(other.action, .move)
        XCTAssertEqual(other.from?.screen, "Built-in")
        let minimized = oneScreen(slot([win(1, screen: 0, space: 2, visible: false, minimized: true)]))
        XCTAssertEqual(minimized.action, .resize)
        XCTAssertTrue(minimized.reason.contains("Dock"))
        XCTAssertEqual(oneScreen(slot([win(1, screen: 0, space: 3, visible: true, frame: rect)])).action, .stay)
    }

    /// The owner's shortcuts: "Move left/right a space" on, "Switch to Desktop N" off.
    func testWhichDesktopsADisplayCanReachAndComeBackFrom() {
        let on = Spaces.Shortcut(enabled: true, keyCode: 123, modifiers: 262_144)
        let off = Spaces.Shortcut(enabled: false, keyCode: 18, modifiers: 262_144)
        func shortcuts(_ moves: Bool) -> (Int) -> Spaces.Shortcut? {
            { key in [Spaces.Key.moveLeft, Spaces.Key.moveRight].contains(key) ? (moves ? on : off) : off }
        }
        XCTAssertEqual(P.Screen.switchable(current: 3, count: 4, shortcuts: shortcuts(true)), [1, 2, 3, 4])
        XCTAssertEqual(P.Screen.switchable(current: 3, count: 4, shortcuts: shortcuts(false)), [3])
        XCTAssertNil(P.Screen.switchable(current: nil, count: 4, shortcuts: shortcuts(true)))
    }

    /// With the switch shortcuts off the plan does not promise a desktop switch: it says the app
    /// is left, and why.
    func testNoFetchIsPlannedWhenDesktopsCannotBeSwitched() {
        var screens = self.screens
        screens[0].switchable = [3]
        let single = oneScreen(slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .single), screens: screens)
        XCTAssertEqual(single.action, .cannot)
        XCTAssertNil(single.bring)
        XCTAssertTrue(single.reason.hasPrefix("Signal has one window, on another desktop (desktop 1 of DELL; "), single.reason)
        XCTAssertTrue(single.reason.contains(Spaces.SwitchError.shortcutDisabled.message), single.reason)
        // With the feature on, `bring` falls back as it does without a second display.
        let menu = P.step(for: slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .menu), screens: screens,
                          mode: .multiDesktop(.bring))
        XCTAssertEqual(menu.action, .launch)
        XCTAssertTrue(menu.newWindow)
        // A desktop it can reach is fetched as before.
        screens[0].switchable = [1, 2, 3, 4]
        XCTAssertNotNil(oneScreen(slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .single), screens: screens).bring)
    }

    /// A hidden (⌘H) app's window on the desktop showing is in reach: unhidden and placed, never
    /// "on another desktop".
    func testAHiddenAppsWindowIsUnhiddenInPlace() {
        XCTAssertTrue(WindowLocator.isShowing(onScreen: false, minimized: false, appHidden: true, space: 3, showingSpace: 3))
        XCTAssertTrue(WindowLocator.isShowing(onScreen: false, minimized: false, appHidden: true, space: nil, showingSpace: 3))
        XCTAssertFalse(WindowLocator.isShowing(onScreen: false, minimized: false, appHidden: true, space: 1, showingSpace: 3))
        XCTAssertFalse(WindowLocator.isShowing(onScreen: false, minimized: false, appHidden: false, space: 3, showingSpace: 3))
        XCTAssertFalse(WindowLocator.isShowing(onScreen: false, minimized: true, appHidden: true, space: 3, showingSpace: 3))
        var hidden = win(1, screen: 0, space: 3, visible: true)
        hidden.hidden = true
        let s = oneScreen(slot([hidden], newWindow: .single))
        XCTAssertEqual(s.action, .resize)
        XCTAssertTrue(s.reason.hasPrefix("unhide it"), s.reason)
        XCTAssertFalse(s.reason.contains("desktop"), s.reason)
        hidden.frame = rect
        XCTAssertEqual(oneScreen(slot([hidden])).action, .resize, "in place but hidden: unhidden")
        var there = win(1, screen: 1, space: 1, visible: true)
        there.hidden = true
        XCTAssertTrue(oneScreen(slot([there])).reason.hasPrefix("unhide it and move it from Built-in"))
    }

    func testThePlanNamesItsMode() {
        XCTAssertEqual(P.Mode.oneScreen.name, "oneScreen")
        XCTAssertEqual(P.Mode.multiDesktop(.bring).name, "bring")
        XCTAssertEqual(P.Mode.multiDesktop(.leave).name, "leave")
    }
}

final class ApplyReportSlotsTests: XCTestCase {
    private func step(_ id: String, _ action: PlacementPlan.Action, _ reason: String) -> PlacementPlan.Step {
        PlacementPlan.Step(regionID: id, regionName: id, occupant: id.capitalized, action: action, from: nil,
                           to: PlacementPlan.Location(screen: "DELL", space: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
                           reason: reason)
    }

    func testSlotsJSONCarriesResultAndActualFrame() {
        var report = LoadoutEngine.ApplyReport(loadout: "L")
        report.steps = [step("a", .move, "move it from Built-in"), step("b", .cannot, "Signal has one window")]
        report.placed = ["a"]
        report.failed = ["b": "cannot: Signal has one window"]
        report.actual = ["a": CGRect(x: 0, y: 0, width: 12, height: 10)]
        let slots = report.slotsJSON
        XCTAssertEqual(slots[0]["result"] as? String, "placed")
        XCTAssertNotNil(slots[0]["actual"])
        XCTAssertEqual(slots[1]["result"] as? String, "failed")
        XCTAssertEqual((report.json["slots"] as? [[String: Any]])?.count, 2)
    }

    func testToastLinesExplainMovesAndFailuresOnly() {
        var report = LoadoutEngine.ApplyReport(loadout: "L")
        report.steps = [step("a", .resize, "move/resize in place"), step("b", .move, "move it from Built-in"),
                        step("c", .leave, "left on desktop 2")]
        report.placed = ["a", "b"]
        report.failed = ["c": "leave: left on desktop 2", "screen:Other": "screenMissing"]
        let lines = report.detailLines { $0 }
        XCTAssertEqual(lines, ["B: move it from Built-in", "C: leave: left on desktop 2", "screen:Other: screenMissing"])
    }

    @MainActor
    func testLoadoutWedgeReportsItsRings() {
        let wedges = [RadialMenu.Wedge(name: "Work", kind: .loadout("Work")), RadialMenu.Wedge(name: "Park", kind: .park(.init()))]
        let g = RadialGeometry(count: 2, ringCounts: wedges.map { RadialMenu.ringCount(for: $0.kind) })
        let json = RadialMenu.json(wedges: wedges, geometry: g)
        let out = json["wedges"] as? [[String: Any]]
        XCTAssertEqual(out?[0]["kind"] as? String, "loadout")
        XCTAssertEqual(out?[0]["rings"] as? [String], ["Preview", "Apply", "Clear + Apply"])
        XCTAssertEqual(out?[1]["rings"] as? [String], ["Park", "Restore"])
    }
}

// MARK: - Regression: overlapping regions stay overlapping

/// A MacHUD panel whose window stands in for an app window: placing it sets its frame,
/// raising it is recorded.
@MainActor
private final class FakePanel: Panel {
    static var raised: [String] = []
    let id: String
    var title: String { id }
    var symbol: String { "square" }
    let fake: RecordingWindow
    var shown = false
    var window: NSWindow? { fake }
    var isVisible: Bool { shown }

    init(id: String) {
        self.id = id
        fake = RecordingWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless],
                               backing: .buffered, defer: true)
        fake.panelID = id
    }

    func show() { shown = true }
    func hide() { shown = false }
}

private final class RecordingWindow: NSWindow {
    var panelID = ""
    override func orderFrontRegardless() {
        MainActor.assumeIsolated { FakePanel.raised.append(panelID) }
    }
}

@MainActor
final class OverlappingPlacementTests: XCTestCase {
    /// Report 3: two overlapping regions, two windows. Each lands on its exact region
    /// frame (so they overlap) and the higher z is raised last.
    func testOverlappingRegionsKeepExactFramesAndStackingOrder() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no display") }
        let json = """
        {"gap": 0,
         "layouts": [{"name": "Stack", "regions": [
            {"id": "back", "name": "Back", "x": 0.05, "y": 0.05, "w": 0.6, "h": 0.6},
            {"id": "front", "name": "Front", "x": 0.35, "y": 0.3, "w": 0.6, "h": 0.6}]}],
         "loadouts": [{"name": "Stacked", "layout": "Stack", "slots": [
            {"regionID": "front", "z": 1, "occupant": {"kind": "panel", "id": "test.front"}},
            {"regionID": "back", "occupant": {"kind": "panel", "id": "test.back"}}]}]}
        """
        guard try TestConfig.write(json) else {
            throw XCTSkip("LayoutStore.configURL was already fixed to \(LayoutStore.configURL.path)")
        }
        let store = LayoutStore()
        let registry = PanelRegistry()
        let back = FakePanel(id: "test.back"), front = FakePanel(id: "test.front")
        registry.register(back)
        registry.register(front)
        let engine = LoadoutEngine(store: store, panels: registry)
        let loadout = try XCTUnwrap(store.loadout(named: "Stacked"))
        let layout = try XCTUnwrap(store.layout(named: "Stack"))

        // The plan says both are placed where they are, on this display.
        let (steps, _) = engine.plan(loadout, screen: screen)
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps.allSatisfy(\.places), "\(steps.map(\.reason))")

        FakePanel.raised = []
        var report: LoadoutEngine.ApplyReport?
        engine.apply(loadout, clear: false, screen: screen) { report = $0 }
        XCTAssertTrue(spin(until: { report != nil }), "apply finishes")
        XCTAssertEqual(Set(report?.placed ?? []), ["back", "front"], "failed: \(report?.failed ?? [:])")

        let backRect = engine.regionRect(layout.region(id: "back")!, on: screen)
        let frontRect = engine.regionRect(layout.region(id: "front")!, on: screen)
        XCTAssertTrue(ZOrder.overlaps(backRect, frontRect))
        XCTAssertEqual(back.fake.frame, backRect, "exact region frame, not tiled")
        XCTAssertEqual(front.fake.frame, frontRect, "exact region frame, not tiled")
        // Stacking: raised back (z 0) then front (z 1), so front ends up on top.
        XCTAssertTrue(spin(until: { FakePanel.raised.suffix(2) == ["test.back", "test.front"] }),
                      "raise order \(FakePanel.raised)")
        XCTAssertEqual(report?.steps.map(\.regionID), ["front", "back"])
    }
}
