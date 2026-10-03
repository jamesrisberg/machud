import XCTest
import AppKit
@testable import MacHUDCore

/// The status menu's Loadouts submenu, the wheel and the capture sheet offer one-screen
/// loadouts and capture the screen under the pointer unless multi-desktop loadouts
/// (experimental) are on. Nothing here applies, previews or captures for real: the only
/// actions run are ones refused before they reach the engine, so no window moves.
@MainActor
final class LoadoutMenuTests: XCTestCase {
    private var refusals: [(title: String, detail: String)] = []

    private func make(multiDesktop: Bool, json: String? = nil) throws -> (LoadoutMenu, LayoutStore, LoadoutEngine) {
        guard try TestConfig.write(json ?? LoadoutsFixture.json(multiDesktop: multiDesktop)) else {
            throw XCTSkip("LayoutStore.configURL was already fixed to \(LayoutStore.configURL.path)")
        }
        let store = LayoutStore()
        let engine = LoadoutEngine(store: store, panels: PanelRegistry())
        let menu = LoadoutMenu(store: store, engine: engine)
        menu.showRefusal = { [unowned self] in self.refusals.append(($0, $1)) }
        return (menu, store, engine)
    }

    private func items(_ menu: LoadoutMenu) -> [NSMenuItem] { menu.menuItems().first?.submenu?.items ?? [] }

    private func titles(_ menu: LoadoutMenu) -> [String] { items(menu).map { $0.isSeparatorItem ? "-" : $0.title } }

    private static let tools = ["Save Dock and Panels as HUD Loadout…", "Draw a New Layout…", "-",
                                "Snap Layout", "Restore Cleared Windows"]

    // MARK: - The Loadouts submenu

    func testWithMultiDesktopLoadoutsOffTheMenuOffersOneScreenLoadoutsAndCapturesThisScreen() throws {
        let (menu, _, _) = try make(multiDesktop: false)
        XCTAssertEqual(titles(menu), ["Code", "Reading", "My HUD", "1 multi-desktop loadout hidden (experimental)", "-",
                                      "Capture This Screen as Loadout…"] + Self.tools)
        let hidden = items(menu)[3]
        XCTAssertFalse(hidden.isEnabled, "a dimmed line, not an entry")
        XCTAssertNil(hidden.submenu)
        XCTAssertEqual(hidden.toolTip, ExperimentalLoadouts.howToTurnOn)
    }

    func testWithMultiDesktopLoadoutsOnTheMenuOffersEveryLoadoutAsBefore() throws {
        let (menu, store, _) = try make(multiDesktop: true)
        let hotkey = try XCTUnwrap(store.loadout(named: "Desk")?.hotkey)
        XCTAssertEqual(titles(menu), ["Desk  \(hotkey.display)", "Code", "Reading", "My HUD", "-",
                                      "Capture Windows as Loadout…"] + Self.tools)
    }

    func testTheMenuFollowsTheSettingWithoutARelaunch() throws {
        let (menu, store, _) = try make(multiDesktop: false)
        var config = store.config
        config.experimental?.multiDesktopLoadouts = true
        store.save(config)
        XCTAssertEqual(titles(menu).first?.hasPrefix("Desk"), true)
        XCTAssertTrue(titles(menu).contains("Capture Windows as Loadout…"))
        config.experimental?.multiDesktopLoadouts = false
        store.save(config)
        XCTAssertEqual(titles(menu).first, "Code")
        XCTAssertTrue(titles(menu).contains("Capture This Screen as Loadout…"))
    }

    func testWithEveryLoadoutHiddenTheMenuSaysSoInsteadOfNoLoadoutsYet() throws {
        var config = try LoadoutsFixture.config(multiDesktop: false)
        config.loadouts = config.loadouts.map { Array($0.prefix(1)) }
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        let (menu, _, _) = try make(multiDesktop: false, json: json)
        XCTAssertEqual(titles(menu), ["1 multi-desktop loadout hidden (experimental)", "-",
                                      "Capture This Screen as Loadout…"] + Self.tools)
    }

    func testWithNoLoadoutsTheMenuPointsAtTheCaptureItem() throws {
        let (off, _, _) = try make(multiDesktop: false, json: #"{"experimental": {"multiDesktopLoadouts": false}}"#)
        XCTAssertEqual(titles(off).first, "No loadouts yet: arrange windows, then Capture This Screen…")
        let (on, _, _) = try make(multiDesktop: true, json: #"{"experimental": {"multiDesktopLoadouts": true}}"#)
        XCTAssertEqual(titles(on).first, "No loadouts yet: arrange windows, then Capture Windows…")
    }

    // MARK: - The wheel

    func testWithMultiDesktopLoadoutsOffTheWheelOffersOneScreenLoadoutsAndOneCapture() throws {
        let (menu, _, _) = try make(multiDesktop: false)
        let wedges = menu.wedges()
        XCTAssertEqual(wedges.map(\.title), ["Code", "Reading", "My HUD", "Capture…", "Park"])
        XCTAssertEqual(wedges.prefix(3).map(\.subtitle), ["3 windows", "1 window", "0 windows · HUD"])
        XCTAssertEqual(wedges[3].kind, .capture(offersAllScreens: false))
        XCTAssertFalse(wedges.contains { $0.subtitle.contains("desktop") })
    }

    func testWithMultiDesktopLoadoutsOnTheWheelIsAsBefore() throws {
        let (menu, _, _) = try make(multiDesktop: true)
        let wedges = menu.wedges()
        XCTAssertEqual(wedges.map(\.title), ["Desk", "Code", "Reading", "My HUD", "Capture…", "Park"])
        XCTAssertEqual(wedges[0].subtitle, "6 windows · 2 desktops · HUD")
        XCTAssertEqual(wedges[4].kind, .capture(offersAllScreens: true))
    }

    // MARK: - Hotkeys and the default loadout

    func testOnlyOfferedLoadoutsGetTheirHotkeys() throws {
        let on = try LoadoutsFixture.config(multiDesktop: true)
        XCTAssertEqual(LoadoutMenu.loadoutHotkeys(in: on), ["Desk": try XCTUnwrap(on.loadouts?.first?.hotkey)])
        XCTAssertEqual(LoadoutMenu.loadoutHotkeys(in: try LoadoutsFixture.config(multiDesktop: false)), [:])
    }

    func testWithNoNameThePreviewTakesTheFirstOfferedLoadout() throws {
        let (off, _, _) = try make(multiDesktop: false)
        XCTAssertEqual(off.defaultLoadoutName, "Code")
        let (on, _, _) = try make(multiDesktop: true)
        XCTAssertEqual(on.defaultLoadoutName, "Desk")
    }

    // MARK: - Refusals

    func testAHiddenLoadoutIsRefusedWithTheReasonBeforeTheEngineRuns() throws {
        let (menu, store, engine) = try make(multiDesktop: false)
        let desk = try XCTUnwrap(store.loadout(named: "Desk"))
        let reason = try XCTUnwrap(ExperimentalLoadouts.refusal(for: desk, in: store.config))
        menu.apply(desk, clear: false)
        menu.apply(desk, clear: true)
        menu.preview(desk)
        XCTAssertEqual(refusals.map(\.title), ["Could not apply Desk", "Could not apply Desk", "Could not preview Desk"])
        XCTAssertEqual(refusals.map(\.detail), [reason, reason, reason])
        XCTAssertNil(engine.activeLoadout, "the engine never started an apply")
        XCTAssertFalse(LoadoutPreview.shared.isVisible)
    }

    func testCapturingEveryScreenIsRefusedWithMultiDesktopLoadoutsOff() throws {
        let (menu, store, _) = try make(multiDesktop: false)
        menu.captureCurrent(allScreens: true)
        XCTAssertEqual(refusals.map(\.title), ["Could not capture every screen"])
        XCTAssertEqual(refusals.first?.detail, ExperimentalLoadouts.refusal(forAction: "Capturing every screen", in: store.config))
    }

    // MARK: - What a capture covers

    func testACaptureCoversTheScreenUnderThePointerUnlessMultiDesktopLoadoutsAreOn() {
        // Off: one screen, whatever has windows and whichever ring was asked for.
        XCTAssertFalse(LoadoutMenu.capturesEveryScreen(allScreens: nil, screensWithWindows: 2, multiDesktop: false))
        XCTAssertFalse(LoadoutMenu.capturesEveryScreen(allScreens: false, screensWithWindows: 2, multiDesktop: false))
        XCTAssertFalse(LoadoutMenu.capturesEveryScreen(allScreens: true, screensWithWindows: 2, multiDesktop: false))
        // On: as before; the menu bar decides from how many displays have windows.
        XCTAssertTrue(LoadoutMenu.capturesEveryScreen(allScreens: nil, screensWithWindows: 2, multiDesktop: true))
        XCTAssertFalse(LoadoutMenu.capturesEveryScreen(allScreens: nil, screensWithWindows: 1, multiDesktop: true))
        XCTAssertTrue(LoadoutMenu.capturesEveryScreen(allScreens: true, screensWithWindows: 1, multiDesktop: true))
        XCTAssertFalse(LoadoutMenu.capturesEveryScreen(allScreens: false, screensWithWindows: 3, multiDesktop: true))
    }

    func testTheCaptureSheetLeavesTheHUDOutAndOffersNoWalkWithoutDesktops() {
        let sheet = LoadoutMenu.CaptureSheet(name: "Loadout 1", desktops: nil)
        XCTAssertEqual(sheet.boxes.map(\.title), ["Also keep the layout on its own, for ⇧-drag and other loadouts",
                                                  "Include the tool dock and the apps' panels (the HUD)"])
        XCTAssertEqual(sheet.keepLayout.state, .on)
        XCTAssertEqual(sheet.hud.state, .off, "the HUD is saved only when asked")
        XCTAssertNil(sheet.walk)
        XCTAssertEqual(sheet.answer, LoadoutMenu.CaptureAnswer(name: "Loadout 1", layoutName: "Loadout 1",
                                                               walkDesktops: false, includeHUD: false))
        sheet.hud.state = .on
        sheet.keepLayout.state = .off
        XCTAssertEqual(sheet.answer, LoadoutMenu.CaptureAnswer(name: "Loadout 1", layoutName: nil,
                                                               walkDesktops: false, includeHUD: true))

        // With multi-desktop loadouts on and several desktops, the walk box is offered, off.
        let walking = LoadoutMenu.CaptureSheet(name: "Desk", desktops: 3)
        XCTAssertEqual(walking.walk?.title, "Also walk desktops 1…3")
        XCTAssertEqual(walking.walk?.state, .off)
        XCTAssertEqual(walking.hud.state, .off, "the HUD box starts off there too")
        XCTAssertEqual(walking.boxes.count, 3)
    }
}
