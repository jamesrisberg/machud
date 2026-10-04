import AppKit
import XCTest
@testable import MacHUDCore

/// With `experimental.multiDesktopLoadouts` off (the default) a loadout is one screen: the
/// display under the pointer, on the desktop showing. These pin the engine and socket side of
/// that rule. The multi-desktop behaviour is pinned by ScreensTests and PlacementPlanTests, and
/// here with the setting on.

/// A config with a one-screen loadout and two that span: one assigned to a display, one with a
/// slot pinned to a desktop. Every occupant is a panel nobody registered, so even an apply that
/// got past the refusal would find nothing to move.
enum OneScreenFixture {
    static func json(multiDesktop: Bool?) -> String {
        let experimental = multiDesktop.map { #", "experimental": {"multiDesktopLoadouts": \#($0)}"# } ?? ""
        return """
        {"gap": 0, "spaces": {"policy": "bring"},
         "layouts": [{"name": "Main", "regions": [
            {"id": "a", "name": "A", "x": 0, "y": 0, "w": 0.5, "h": 1},
            {"id": "b", "name": "B", "x": 0.5, "y": 0, "w": 0.5, "h": 1}]}],
         "loadouts": [
            {"name": "Desk", "layout": "Main",
             "slots": [{"regionID": "a", "occupant": {"kind": "panel", "id": "test.nobody"}}]},
            {"name": "Studio", "layout": "Main", "slots": [],
             "screens": [{"screen": {"main": true}, "layout": "Main",
                          "slots": [{"regionID": "b", "occupant": {"kind": "panel", "id": "test.nobody"}}]}]},
            {"name": "Pinned", "layout": "Main",
             "slots": [{"regionID": "a", "space": 2, "occupant": {"kind": "panel", "id": "test.nobody"}}]}]\(experimental)}
        """
    }

    /// A store on the shared test config holding the fixture.
    static func store(multiDesktop: Bool?) throws -> LayoutStore {
        guard try TestConfig.write(json(multiDesktop: multiDesktop)) else {
            throw XCTSkip("LayoutStore.configURL was already fixed to \(LayoutStore.configURL.path)")
        }
        return LayoutStore()
    }
}

@MainActor
final class OneScreenLoadoutListTests: XCTestCase {
    private func names(_ reply: [String: Any]) -> [String] {
        (reply["loadouts"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    func testTheListOffersOneScreenLoadoutsAndCountsTheOthers() throws {
        let library = LoadoutLibrary(store: try OneScreenFixture.store(multiDesktop: nil))
        let reply = library.handle([:])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(names(reply), ["Desk"])
        XCTAssertEqual(reply["heldBack"] as? Int, 2)
        XCTAssertEqual(reply["heldBackNote"] as? String, ExperimentalLoadouts.heldBackNote(count: 2))
    }

    /// A hidden loadout as the startup loadout would only be refused at launch, so naming one is
    /// refused now; clearing it, and an offered one, are not.
    func testAHiddenLoadoutCannotBecomeTheStartupLoadout() throws {
        let store = try OneScreenFixture.store(multiDesktop: nil)
        let library = LoadoutLibrary(store: store)
        let studio = try XCTUnwrap(store.loadout(named: "Studio"))
        let reply = library.handle(["_": "startup", "startup": "1", "name": "Studio"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, ExperimentalLoadouts.refusal(for: studio, in: store.config))
        XCTAssertNil(store.config.startupLoadout)
        XCTAssertEqual(library.handle(["action": "startup", "name": "Desk"])["ok"] as? Bool, true)
        XCTAssertEqual(store.config.startupLoadout, "Desk")
        XCTAssertEqual(library.handle(["action": "startup", "name": "none"])["ok"] as? Bool, true)
        XCTAssertNil(store.config.startupLoadout)
    }

    func testWithTheSettingOnAnyLoadoutCanBeTheStartupLoadout() throws {
        let store = try OneScreenFixture.store(multiDesktop: true)
        XCTAssertEqual(LoadoutLibrary(store: store).handle(["action": "startup", "name": "Studio"])["ok"] as? Bool, true)
        XCTAssertEqual(store.config.startupLoadout, "Studio")
    }

    /// Renaming, copying and deleting a hidden loadout by name are the owner's explicit acts.
    func testAHiddenLoadoutCanStillBeRenamedCopiedAndDeleted() throws {
        let store = try OneScreenFixture.store(multiDesktop: nil)
        let library = LoadoutLibrary(store: store)
        XCTAssertEqual(library.handle(["action": "rename", "name": "Studio", "to": "Studio 2"])["ok"] as? Bool, true)
        XCTAssertEqual(library.handle(["action": "duplicate", "name": "Studio 2"])["loadout"] as? String, "Studio 2 copy")
        XCTAssertEqual(library.handle(["action": "delete", "name": "Pinned"])["ok"] as? Bool, true)
        XCTAssertEqual(store.loadouts.map(\.name), ["Desk", "Studio 2", "Studio 2 copy"])
        XCTAssertEqual(ExperimentalLoadouts.heldBack(in: store.config), 2)
    }

    func testWithTheSettingOnEveryLoadoutIsListed() throws {
        let library = LoadoutLibrary(store: try OneScreenFixture.store(multiDesktop: true))
        let reply = library.handle(["action": "list"])
        XCTAssertEqual(names(reply), ["Desk", "Studio", "Pinned"])
        XCTAssertNil(reply["heldBack"])
        XCTAssertNil(reply["heldBackNote"])
    }
}

@MainActor
final class OneScreenApplyTests: XCTestCase {
    private func engine(multiDesktop: Bool?) throws -> LoadoutEngine {
        LoadoutEngine(store: try OneScreenFixture.store(multiDesktop: multiDesktop), panels: PanelRegistry())
    }

    func testASpanningLoadoutIsRefusedBeforeAnythingMoves() throws {
        let engine = try engine(multiDesktop: nil)
        // Studio names a display but no desktop and holds only an unregistered panel: had the
        // refusal not stopped it, the apply would still have had nothing to move or switch.
        let studio = try XCTUnwrap(engine.store.loadout(named: "Studio"))
        let expected = try XCTUnwrap(ExperimentalLoadouts.refusal(for: studio, in: engine.store.config))
        var report: LoadoutEngine.ApplyReport?
        engine.apply(studio, clear: false) { report = $0 }
        let refused = try XCTUnwrap(report, "answered at once: nothing was started")
        XCTAssertEqual(refused.refused, expected)
        XCTAssertTrue(refused.steps.isEmpty)
        XCTAssertNil(engine.activeLoadout, "a refused loadout does not become the active one")
        XCTAssertEqual(refused.json["ok"] as? Bool, false)
        XCTAssertEqual(refused.json["error"] as? String, expected)
        XCTAssertEqual(refused.detailLines { $0 }, [expected], "the toast says why")
    }

    /// The `capture` verb, every one-screen form, with a hidden loadout's name: refused, and
    /// layouts.json is left byte for byte as it was.
    func testTheCaptureVerbLeavesAHiddenLoadoutAlone() throws {
        let engine = try engine(multiDesktop: nil)
        let before = try Data(contentsOf: LayoutStore.configURL)
        for form in [[:], ["screen": "main"], ["layout": "Main"], ["hud": "only"], ["hud": "1"], ["screens": "all"]] {
            let args = form.merging(["name": "Studio"]) { a, _ in a }
            // Only reach the verb once the rule says it refuses: a capture that went ahead would
            // read the windows on this Mac.
            guard let expected = MultiDesktopVerbs.refusal(capture: args, in: engine.store.config) else {
                XCTFail("\(args) is not refused"); continue
            }
            var reply: [String: Any]?
            engine.handleCapture(args) { reply = $0 }
            XCTAssertEqual(reply?["ok"] as? Bool, false, "\(args)")
            XCTAssertEqual(reply?["error"] as? String, expected, "\(args)")
        }
        XCTAssertEqual(try Data(contentsOf: LayoutStore.configURL), before, "layouts.json is untouched")
    }

    /// With the setting off, a one-screen loadout whose app's only window is on a hidden desktop
    /// plans a fetch (a desktop switch) only for a single-window app; an app that can open a window
    /// gets a new one here, wherever its window is.
    func testAOneScreenPlanSwitchesDesktopsOnlyToFetchASingleWindowApp() throws {
        let engine = try engine(multiDesktop: nil)
        let screens = [PlacementPlan.Screen(name: "DELL", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), currentSpace: 3, spaces: 4),
                       PlacementPlan.Screen(name: "Built-in", frame: CGRect(x: 2560, y: 0, width: 1728, height: 1117), currentSpace: 1, spaces: 2)]
        for (screen, space) in [(0, 1), (1, 2)] {
            for kind in [NewWindowClass.menu, .browser, .single] {
                let hidden = PlacementPlan.Candidate(number: 7, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                                     screen: screen, space: space, visible: false)
                let input = PlacementPlan.SlotInput(regionID: "a", regionName: "A", occupant: "App", screen: 0, space: nil,
                                                    rect: CGRect(x: 0, y: 0, width: 800, height: 600), candidates: [hidden],
                                                    running: true, newWindow: kind)
                let step = PlacementPlan.step(for: input, screens: screens, mode: engine.planMode)
                let what = "\(kind) on \(screen):\(space): \(step.reason)"
                if kind == .single {
                    XCTAssertEqual(step.action, .switchSpace, what)
                    XCTAssertNotNil(step.bring, what)
                    XCTAssertTrue(step.reason.hasPrefix("show desktop \(space)"), what)
                } else {
                    XCTAssertEqual(step.action, .launch, what)
                    XCTAssertTrue(step.newWindow, what)
                    XCTAssertNil(step.bring, what)
                }
            }
        }
    }

    func testThePlanAndThePreviewAreRefusedToo() throws {
        let engine = try engine(multiDesktop: nil)
        for name in ["Studio", "Pinned"] {
            let loadout = try XCTUnwrap(engine.store.loadout(named: name))
            let expected = try XCTUnwrap(ExperimentalLoadouts.refusal(for: loadout, in: engine.store.config))
            let (steps, report) = engine.plan(loadout)
            XCTAssertTrue(steps.isEmpty, name)
            XCTAssertEqual(report.refused, expected, name)
            let json = engine.planJSON(loadout)
            XCTAssertEqual(json["ok"] as? Bool, false, name)
            XCTAssertEqual(json["error"] as? String, expected, name)
            XCTAssertNil(json["plan"], name)
        }
    }

    func testAOneScreenLoadoutIsNotRefused() throws {
        let engine = try engine(multiDesktop: nil)
        let desk = try XCTUnwrap(engine.store.loadout(named: "Desk"))
        let (steps, report) = engine.plan(desk)
        XCTAssertNil(report.refused)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(engine.planJSON(desk)["ok"] as? Bool, true)
    }

    /// `spaces.policy` defaulted to `bring` (and the fixture sets it): with the setting off it is
    /// not read, the planner keeps to the desktop showing, and the plan says so.
    func testAOneScreenPlanDoesNotReadSpacesPolicy() throws {
        let engine = try engine(multiDesktop: nil)
        XCTAssertEqual(engine.planMode, .oneScreen)
        let desk = try XCTUnwrap(engine.store.loadout(named: "Desk"))
        XCTAssertEqual(engine.planJSON(desk)["policy"] as? String, "oneScreen")
    }

    func testWithTheSettingOnSpanningLoadoutsArePlannedAndSpacesPolicyDecides() throws {
        let engine = try engine(multiDesktop: true)
        XCTAssertEqual(engine.planMode, .multiDesktop(.bring))
        for name in ["Desk", "Studio", "Pinned"] {
            let loadout = try XCTUnwrap(engine.store.loadout(named: name))
            let (steps, report) = engine.plan(loadout)
            XCTAssertNil(report.refused, name)
            XCTAssertEqual(steps.count, 1, name)
            let json = engine.planJSON(loadout)
            XCTAssertEqual(json["ok"] as? Bool, true, name)
            XCTAssertEqual(json["policy"] as? String, "bring", name)
        }
    }
}

/// The socket forms that exist only for spanning loadouts.
@MainActor
final class MultiDesktopVerbTests: XCTestCase {
    private let off = Config.defaults
    private var on: Config {
        var c = Config.defaults
        c.experimental = Experimental(multiDesktopLoadouts: true)
        return c
    }

    func testEveryScreenWalkAndPerDisplayCapturesAreRefused() throws {
        let refused: [([String: String], String)] = [
            (["name": "X", "screens": "all"], "Capturing every screen"),
            (["name": "X", "screens": "*", "hud": "1"], "Capturing every screen"),
            (["name": "X", "screens": "all", "desktops": "1,2"], "Capturing every screen"),
            (["name": "X", "desktops": "1,3"], "Walking desktops"),
            (["name": "X", "desktops": "1", "screen": "main"], "Walking desktops"),
            (["name": "X", "screens": "Main@main,Side@builtin"], "Capturing a layout per display"),
        ]
        for (args, action) in refused {
            let reason = try XCTUnwrap(MultiDesktopVerbs.refusal(capture: args, in: off), "\(args)")
            XCTAssertEqual(reason, ExperimentalLoadouts.refusal(forAction: action, in: off), "\(args)")
            XCTAssertNil(MultiDesktopVerbs.refusal(capture: args, in: on), "\(args) with the setting on")
        }
    }

    func testOneScreenCapturesAreNotRefused() {
        for args in [["name": "X"], ["name": "X", "screen": "builtin"], ["name": "X", "layout": "Main"],
                     ["name": "X", "hud": "only"], ["name": "X", "hud": "1"],
                     ["name": "X", "hud": "only", "screens": "all"]] {
            XCTAssertNil(MultiDesktopVerbs.refusal(capture: args, in: off), "\(args)")
        }
    }

    /// A capture with a hidden loadout's name would replace it unseen: every form is refused,
    /// `hud=only` included, with the foundation's sentence for that loadout.
    func testNoCaptureFormTakesAHiddenLoadoutsName() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(OneScreenFixture.json(multiDesktop: nil).utf8))
        let forms: [[String: String]] = [[:], ["screen": "main"], ["layout": "Main"], ["hud": "only"], ["hud": "1"]]
        for name in ["Studio", "Pinned"] {
            let expected = try XCTUnwrap(ExperimentalLoadouts.refusal(forName: name, in: config))
            for form in forms {
                let args = form.merging(["name": name]) { a, _ in a }
                XCTAssertEqual(MultiDesktopVerbs.refusal(capture: args, in: config), expected, "\(args)")
            }
        }
        for form in forms {
            XCTAssertNil(MultiDesktopVerbs.refusal(capture: form.merging(["name": "Desk"]) { a, _ in a }, in: config),
                         "an offered loadout is recaptured as always: \(form)")
            XCTAssertNil(MultiDesktopVerbs.refusal(capture: form.merging(["name": "New"]) { a, _ in a }, in: config))
        }
        var on = config
        on.experimental = Experimental(multiDesktopLoadouts: true)
        XCTAssertNil(MultiDesktopVerbs.refusal(capture: ["name": "Studio"], in: on))
    }

    func testSwitchingDesktopsIsRefusedButReadingThemIsNot() throws {
        let reason = try XCTUnwrap(MultiDesktopVerbs.refusal(spaces: ["action": "switch", "n": "2"], in: off))
        XCTAssertEqual(reason, ExperimentalLoadouts.refusal(forAction: "Switching desktops", in: off))
        XCTAssertNil(MultiDesktopVerbs.refusal(spaces: [:], in: off))
        XCTAssertNil(MultiDesktopVerbs.refusal(spaces: ["action": "status", "screen": "main"], in: off))
        XCTAssertNil(MultiDesktopVerbs.refusal(spaces: ["action": "switch", "n": "2"], in: on))
    }
}
