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

    func testWithTheSettingOnSpanningLoadoutsArePlanned() throws {
        let engine = try engine(multiDesktop: true)
        for name in ["Desk", "Studio", "Pinned"] {
            let loadout = try XCTUnwrap(engine.store.loadout(named: name))
            let (steps, report) = engine.plan(loadout)
            XCTAssertNil(report.refused, name)
            XCTAssertEqual(steps.count, 1, name)
            XCTAssertEqual(engine.planJSON(loadout)["ok"] as? Bool, true, name)
        }
    }
}
