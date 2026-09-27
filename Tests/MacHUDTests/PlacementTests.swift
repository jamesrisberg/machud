import AppKit
import XCTest
@testable import MacHUDCore

/// The planner's decision table (`PlacementPlan`) against fake window lists across
/// displays and desktops.
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
        P.step(for: s, screens: screens, policy: policy)
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
        let s = P.step(for: slot([win(1, screen: 1, space: 1, visible: false)]), screens: screens, policy: .bring)
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
        let s = P.step(for: slot([win(1, screen: 0, space: 1, visible: false)]), screens: one, policy: .bring)
        XCTAssertEqual(s.action, .cannot)
        XCTAssertTrue(s.reason.contains("one window"), s.reason)
        XCTAssertTrue(s.reason.contains("desktop 1"), s.reason)
    }

    func testOneDisplayMenuAppFallsBackToANewWindow() {
        let one = [screens[0]]
        let s = P.step(for: slot([win(1, screen: 0, space: 1, visible: false)], newWindow: .menu),
                       screens: one, policy: .bring)
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

    func testNewWindowClasses() {
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.apple.MobileSMS", hasNewWindowMenu: true), .single)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.google.Chrome", hasNewWindowMenu: false), .browser)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.apple.TextEdit", hasNewWindowMenu: true), .menu)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.example.unknown", hasNewWindowMenu: false), .single)
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
        let wedges = [RadialMenu.Wedge(title: "Work", kind: .loadout("Work")), RadialMenu.Wedge(title: "Park", kind: .park)]
        let g = RadialGeometry(count: 2, ringCounts: wedges.map { RadialMenu.ringCount(for: $0.kind) })
        let json = RadialMenu.json(wedges: wedges, geometry: g)
        let out = json["wedges"] as? [[String: Any]]
        XCTAssertEqual(out?[0]["kind"] as? String, "loadout")
        XCTAssertEqual(out?[0]["rings"] as? [String], ["Preview", "Apply", "Clear this screen + Apply"])
        XCTAssertEqual(out?[1]["rings"] as? [String], ["Park front window", "Restore parked"])
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
