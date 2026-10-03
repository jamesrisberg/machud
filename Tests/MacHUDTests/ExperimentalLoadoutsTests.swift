import XCTest
@testable import MacHUDCore

final class ExperimentalLoadoutsTests: XCTestCase {
    private let slot = Slot(regionID: "a", occupant: .app(bundleID: "com.apple.TextEdit", titleMatch: nil))

    private func config(_ loadouts: [Loadout], on: Bool?) -> Config {
        Config(layouts: [], loadouts: loadouts, experimental: on.map { Experimental(multiDesktopLoadouts: $0) })
    }

    private var oneScreen: Loadout { Loadout(name: "Desk", layout: "Main", slots: [slot]) }
    private var twoDisplays: Loadout {
        Loadout(name: "Both", layout: "Main", slots: [],
                screens: [ScreenAssignment(screen: .builtin, layout: "Main", slots: [slot]),
                          ScreenAssignment(screen: .name("DELL S2722QC"), layout: "Side", slots: [slot])])
    }
    private var twoDesktops: Loadout {
        Loadout(name: "Walk", layout: "Main", slots: [],
                screens: [ScreenAssignment(screen: .builtin, layout: "Main", slots: [slot], space: 1),
                          ScreenAssignment(screen: .builtin, layout: "Side", slots: [slot], space: 2)])
    }
    private var desktopSlot: Loadout {
        Loadout(name: "Pinned", layout: "Main",
                slots: [Slot(regionID: "a", occupant: .app(bundleID: "com.apple.TextEdit", titleMatch: nil), space: 3)])
    }

    func testTheFlagDecodesAndIsOffByDefault() throws {
        let on = try JSONDecoder().decode(Config.self, from: Data(#"{"experimental": {"multiDesktopLoadouts": true}}"#.utf8))
        XCTAssertTrue(on.multiDesktopLoadouts)
        let other = try JSONDecoder().decode(Config.self, from: Data(#"{"experimental": {"spacesPrivateAPI": true}}"#.utf8))
        XCTAssertFalse(other.multiDesktopLoadouts)
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).multiDesktopLoadouts)
    }

    func testALoadoutSpansWhenItNamesDisplaysOrDesktops() {
        XCTAssertFalse(oneScreen.spansScreensOrDesktops)
        XCTAssertTrue(twoDisplays.spansScreensOrDesktops)
        XCTAssertTrue(twoDesktops.spansScreensOrDesktops)
        XCTAssertTrue(desktopSlot.spansScreensOrDesktops)
        // An empty assignment list is the one-screen form.
        XCTAssertFalse(Loadout(name: "Desk", layout: "Main", slots: [slot], screens: []).spansScreensOrDesktops)
    }

    func testSpanningLoadoutsAreHeldBackWhileTheFeatureIsOff() {
        let all = [oneScreen, twoDisplays, twoDesktops, desktopSlot]
        for off in [config(all, on: nil), config(all, on: false)] {
            XCTAssertEqual(ExperimentalLoadouts.offered(in: off).map(\.name), ["Desk"])
            XCTAssertEqual(ExperimentalLoadouts.heldBack(in: off), 3)
        }
        let on = config(all, on: true)
        XCTAssertEqual(ExperimentalLoadouts.offered(in: on).map(\.name), ["Desk", "Both", "Walk", "Pinned"])
        XCTAssertEqual(ExperimentalLoadouts.heldBack(in: on), 0)
    }

    func testRefusalsNameTheLoadoutOrActionAndTheSetting() throws {
        let off = config([oneScreen, twoDesktops], on: nil)
        XCTAssertNil(ExperimentalLoadouts.refusal(for: oneScreen, in: off))
        let loadout = try XCTUnwrap(ExperimentalLoadouts.refusal(for: twoDesktops, in: off))
        XCTAssertTrue(loadout.contains("“Walk”"), loadout)
        XCTAssertTrue(loadout.contains("Multi-desktop loadouts"), loadout)
        let action = try XCTUnwrap(ExperimentalLoadouts.refusal(forAction: "Capturing every screen", in: off))
        XCTAssertTrue(action.hasPrefix("Capturing every screen is experimental"), action)
        XCTAssertTrue(action.contains("Multi-desktop loadouts"), action)

        let on = config([oneScreen, twoDesktops], on: true)
        XCTAssertNil(ExperimentalLoadouts.refusal(for: twoDesktops, in: on))
        XCTAssertNil(ExperimentalLoadouts.refusal(forAction: "Capturing every screen", in: on))
    }

    /// Saving a capture (or the HUD) under a held-back loadout's name would replace it unseen.
    func testAHeldBackLoadoutsNameCannotBeCapturedOrSavedOver() {
        let off = config([oneScreen, twoDesktops], on: nil)
        XCTAssertEqual(ExperimentalLoadouts.refusal(forName: "Walk", in: off), ExperimentalLoadouts.refusal(for: twoDesktops, in: off))
        XCTAssertNotNil(ExperimentalLoadouts.refusal(forName: "Walk", in: off))
        XCTAssertNil(ExperimentalLoadouts.refusal(forName: "Desk", in: off), "recapturing an offered loadout replaces it, as always")
        XCTAssertNil(ExperimentalLoadouts.refusal(forName: "New", in: off))
        XCTAssertNil(ExperimentalLoadouts.refusal(forName: "Walk", in: config([oneScreen, twoDesktops], on: true)))
    }
}
