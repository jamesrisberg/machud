import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

/// A sample desk: a DELL beside the built-in display, a loadout captured across both and two
/// desktops (its layouts hidden, as capture keeps them), one on a shared snap layout, and a
/// HUD-only one.
enum LoadoutsFixture {
    static let json = #"""
    {"gap": 0, "startupLoadout": "Desk",
     "layouts": [
       {"name": "Thirds", "regions": [
         {"id": "t1", "name": "Left", "x": 0, "y": 0, "w": 0.3333, "h": 1},
         {"id": "t2", "name": "Middle", "x": 0.3333, "y": 0, "w": 0.3334, "h": 1},
         {"id": "t3", "name": "Right", "x": 0.6667, "y": 0, "w": 0.3333, "h": 1}]},
       {"name": "Desk · DELL", "hidden": true, "regions": [
         {"id": "d1", "name": "Safari", "x": 0, "y": 0, "w": 0.5, "h": 1},
         {"id": "d2", "name": "Terminal", "x": 0.5, "y": 0, "w": 0.5, "h": 0.5},
         {"id": "d3", "name": "Notes", "x": 0.5, "y": 0.5, "w": 0.5, "h": 0.5}]},
       {"name": "Desk · DELL · Desktop 2", "hidden": true, "regions": [
         {"id": "e1", "name": "Mail", "x": 0.1, "y": 0.1, "w": 0.8, "h": 0.8}]},
       {"name": "Desk · Built-in", "hidden": true, "regions": [
         {"id": "b1", "name": "Messages", "x": 0, "y": 0, "w": 1, "h": 1},
         {"id": "b2", "name": "Stash", "x": 0.7, "y": 0.2, "w": 0.3, "h": 0.6}]}],
     "loadouts": [
       {"name": "Desk", "layout": "Desk · DELL", "slots": [],
        "hotkey": {"key": "1", "modifiers": ["control", "option"]},
        "screens": [
          {"screen": {"display": "10ac-a0b4-1", "name": "DELL U2723QE"}, "layout": "Desk · DELL", "space": 1, "slots": [
            {"regionID": "d1", "occupant": {"kind": "app", "bundleID": "com.apple.Safari"}},
            {"regionID": "d2", "occupant": {"kind": "app", "bundleID": "com.apple.Terminal"}},
            {"regionID": "d3", "occupant": {"kind": "app", "bundleID": "com.apple.Notes"}}]},
          {"screen": {"display": "10ac-a0b4-1", "name": "DELL U2723QE"}, "layout": "Desk · DELL · Desktop 2", "space": 2, "slots": [
            {"regionID": "e1", "occupant": {"kind": "app", "bundleID": "com.apple.mail"}}]},
          {"screen": {"builtin": true}, "layout": "Desk · Built-in", "space": 1, "slots": [
            {"regionID": "b1", "occupant": {"kind": "app", "bundleID": "com.apple.MobileSMS"}},
            {"regionID": "b2", "occupant": {"kind": "panel", "id": "xyz.machud.stash/shelf"},
             "mode": "parked", "edge": "right", "z": 1}]}],
        "hud": {"dock": {"position": "bottomLeft"},
                "apps": {"xyz.machud.sift": {"panels": {"browser": {"visible": true, "mode": "full",
                                                                     "frame": {"x": 40, "y": 80, "w": 700, "h": 900}}}},
                         "xyz.machud.stash": {"panels": {"shelf": {"visible": false}}}}}},
       {"name": "Code", "layout": "Thirds", "slots": [
         {"regionID": "t1", "occupant": {"kind": "app", "bundleID": "com.apple.Terminal"}},
         {"regionID": "t2", "occupant": {"kind": "web", "url": "https://developer.apple.com/documentation", "host": "safari"}},
         {"regionID": "t3", "occupant": {"kind": "app", "bundleID": "com.apple.Notes"}}]},
       {"name": "Reading", "layout": "Thirds", "slots": [
         {"regionID": "t2", "occupant": {"kind": "app", "bundleID": "com.apple.Safari"}}]},
       {"name": "My HUD", "layout": "", "slots": [],
        "hud": {"dock": {"position": "right"},
                "apps": {"xyz.machud.sift": {"panels": {"browser": {"visible": true}}},
                         "xyz.machud.scratch": {"panels": {"pad": {"visible": true}}}}}}]}
    """#

    static func config() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    /// The DELL (main) on the left, the built-in display to its right and lower, two
    /// desktops each.
    static let displays: [LoadoutSketch.Display] = [
        .init(descriptor: ScreenDescriptor(name: "DELL U2723QE", isMain: true, isBuiltin: false, persistentID: "10ac-a0b4-1"),
              frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visible: CGRect(x: 0, y: 0, width: 2560, height: 1415),
              desktops: .init(count: 2, current: 1)),
        .init(descriptor: ScreenDescriptor(name: "Built-in Retina Display", isMain: false, isBuiltin: true, persistentID: "610-a045-0"),
              frame: CGRect(x: 2560, y: -300, width: 1512, height: 982), visible: CGRect(x: 2560, y: -300, width: 1512, height: 944),
              desktops: .init(count: 2, current: 1)),
    ]
}

/// The Loadouts settings tab: loadout edits (rename, duplicate, delete, startup) on the
/// config, the preview geometry per display and desktop, the tab model, the `loadouts`
/// verb, and offscreen snapshots.
@MainActor
final class LoadoutsTabTests: XCTestCase {
    // MARK: - Edits

    func testOwnedLayoutsAreTheHiddenOnesNoOtherLoadoutUses() throws {
        var config = try LoadoutsFixture.config()
        XCTAssertEqual(config.ownedLayouts(of: "Desk"), ["Desk · DELL", "Desk · DELL · Desktop 2", "Desk · Built-in"])
        XCTAssertEqual(config.ownedLayouts(of: "Code"), [], "a visible layout is shared, never owned")
        XCTAssertEqual(config.ownedLayouts(of: "My HUD"), [])
        // A hidden layout another loadout also uses belongs to neither.
        config.loadouts?[1].screens = [ScreenAssignment(screen: .main, layout: "Desk · Built-in", slots: [])]
        XCTAssertEqual(config.ownedLayouts(of: "Desk"), ["Desk · DELL", "Desk · DELL · Desktop 2"])
    }

    func testDeleteRemovesTheLoadoutItsLayoutsAndTheStartupSetting() throws {
        var config = try LoadoutsFixture.config()
        let result = try config.apply(.delete("Desk"))
        XCTAssertEqual(result.removedLayouts, ["Desk · DELL", "Desk · DELL · Desktop 2", "Desk · Built-in"])
        XCTAssertNil(result.loadout)
        XCTAssertEqual(config.loadouts?.map(\.name), ["Code", "Reading", "My HUD"])
        XCTAssertEqual(config.layouts.map(\.name), ["Thirds"])
        XCTAssertNil(config.startupLoadout)

        // A shared layout stays for the loadout still using it.
        _ = try config.apply(.delete("Code"))
        XCTAssertEqual(config.layouts.map(\.name), ["Thirds"])
        XCTAssertThrowsError(try config.apply(.delete("Code"))) {
            XCTAssertEqual($0 as? LoadoutEditError, .noSuchLoadout("Code"))
        }
    }

    func testRenameCarriesItsLayoutsAndStartup() throws {
        var config = try LoadoutsFixture.config()
        let result = try config.apply(.rename("Desk", to: " Studio "))
        XCTAssertEqual(result.loadout, "Studio")
        XCTAssertEqual(result.renamedLayouts, ["Desk · DELL": "Studio · DELL",
                                               "Desk · DELL · Desktop 2": "Studio · DELL · Desktop 2",
                                               "Desk · Built-in": "Studio · Built-in"])
        let studio = try XCTUnwrap(config.loadouts?.first { $0.name == "Studio" })
        XCTAssertEqual(studio.layout, "Studio · DELL")
        XCTAssertEqual(studio.screens?.map(\.layout), ["Studio · DELL", "Studio · DELL · Desktop 2", "Studio · Built-in"])
        XCTAssertEqual(studio.screens?[0].slots.map(\.regionID), ["d1", "d2", "d3"], "region ids are kept")
        XCTAssertEqual(config.startupLoadout, "Studio")
        XCTAssertFalse(config.layouts.contains { $0.name.hasPrefix("Desk") })

        // Renaming a loadout on a shared layout leaves the layout alone.
        _ = try config.apply(.rename("Code", to: "Coding"))
        XCTAssertEqual(config.layouts.first?.name, "Thirds")
        XCTAssertEqual(config.loadouts?.first { $0.name == "Coding" }?.layout, "Thirds")

        XCTAssertThrowsError(try config.apply(.rename("Coding", to: "Reading"))) {
            XCTAssertEqual($0 as? LoadoutEditError, .nameTaken("Reading"))
        }
        XCTAssertThrowsError(try config.apply(.rename("Coding", to: "  "))) {
            XCTAssertEqual($0 as? LoadoutEditError, .emptyName)
        }
        XCTAssertThrowsError(try config.apply(.rename("Nope", to: "X"))) {
            XCTAssertEqual($0 as? LoadoutEditError, .noSuchLoadout("Nope"))
        }
    }

    func testDuplicateCopiesOwnedLayoutsWithFreshRegionsAndNoHotkey() throws {
        var config = try LoadoutsFixture.config()
        let original = try XCTUnwrap(config.loadouts?.first { $0.name == "Desk" })
        let result = try config.apply(.duplicate("Desk", as: nil))
        XCTAssertEqual(result.loadout, "Desk copy")
        XCTAssertEqual(result.addedLayouts, ["Desk copy · DELL", "Desk copy · DELL · Desktop 2", "Desk copy · Built-in"])
        let copy = try XCTUnwrap(config.loadouts?.first { $0.name == "Desk copy" })
        XCTAssertNil(copy.hotkey)
        XCTAssertEqual(copy.hud, original.hud)
        XCTAssertEqual(copy.screens?.map(\.layout), ["Desk copy · DELL", "Desk copy · DELL · Desktop 2", "Desk copy · Built-in"])
        XCTAssertEqual(config.loadouts?.first { $0.name == "Desk" }, original, "the original is untouched")
        XCTAssertEqual(config.startupLoadout, "Desk")
        // Every slot of the copy resolves in its own layout, under a new region id.
        for assignment in copy.screens ?? [] {
            let layout = try XCTUnwrap(config.layouts.first { $0.name == assignment.layout })
            XCTAssertEqual(layout.hidden, true)
            for slot in assignment.slots {
                XCTAssertNotNil(layout.region(id: slot.regionID), slot.regionID)
                XCTAssertFalse(["d1", "d2", "d3", "e1", "b1", "b2"].contains(slot.regionID))
            }
        }
        // Deleting the copy leaves the original's layouts.
        _ = try config.apply(.delete("Desk copy"))
        XCTAssertEqual(config.ownedLayouts(of: "Desk").count, 3)

        _ = try config.apply(.duplicate("Desk", as: nil))
        XCTAssertEqual(try config.apply(.duplicate("Desk", as: nil)).loadout, "Desk copy 2")
        // A shared layout stays shared.
        XCTAssertEqual(try config.apply(.duplicate("Code", as: "Code 2")).addedLayouts, [])
        XCTAssertEqual(config.loadouts?.first { $0.name == "Code 2" }?.layout, "Thirds")
        XCTAssertThrowsError(try config.apply(.duplicate("Code", as: "Reading")))
    }

    func testStartupSetsAndClears() throws {
        var config = try LoadoutsFixture.config()
        XCTAssertEqual(try config.apply(.startup("Code")).loadout, "Code")
        XCTAssertEqual(config.startupLoadout, "Code")
        _ = try config.apply(.startup(nil))
        XCTAssertNil(config.startupLoadout)
        XCTAssertThrowsError(try config.apply(.startup("Nope")))
    }

    // MARK: - Preview geometry

    func testSketchPlacesEachDisplaysRegionsOnItsDesktops() throws {
        let config = try LoadoutsFixture.config()
        let desk = try XCTUnwrap(config.loadouts?.first)
        let sketch = LoadoutSketch.build(desk, layouts: config.layouts, displays: LoadoutsFixture.displays, gap: 0)
        XCTAssertEqual(sketch.problems, [])
        XCTAssertEqual(sketch.notes, [])
        XCTAssertEqual(sketch.desktops, [1, 2])
        XCTAssertEqual(sketch.usedDisplays, [0, 1])
        XCTAssertEqual(sketch.bounds, CGRect(x: 0, y: -300, width: 4072, height: 1740))

        let one = sketch.regions(on: 1)
        XCTAssertEqual(one.map(\.regionID), ["d1", "d2", "d3", "b1", "b2"])
        // The DELL's left half, below its menu bar; the built-in display's full visible frame.
        XCTAssertEqual(one[0].rect, CGRect(x: 0, y: 0, width: 1280, height: 1415))
        XCTAssertEqual(one[0].display, 0)
        XCTAssertEqual(one[1].rect, CGRect(x: 1280, y: 707, width: 1280, height: 708))
        XCTAssertEqual(one[3].rect, CGRect(x: 2560, y: -300, width: 1512, height: 944))
        XCTAssertEqual(one[3].display, 1)
        XCTAssertEqual(one[4].parked, .right)
        XCTAssertEqual(one[4].z, 1)

        let two = sketch.regions(on: 2)
        XCTAssertEqual(two.map(\.regionID), ["e1"])
        XCTAssertEqual(two[0].display, 0)
        XCTAssertEqual(two[0].rect, LoadoutEngine.regionRect(config.layouts[2].regions[0],
                                                             visible: LoadoutsFixture.displays[0].visible, gap: 0))

        // The HUD part: the dock and each sibling panel at its saved frame.
        XCTAssertEqual(sketch.dock, .bottomLeft)
        XCTAssertEqual(sketch.hudPanels.map(\.id), ["xyz.machud.sift/browser", "xyz.machud.stash/shelf"])
        XCTAssertEqual(sketch.hudPanels[0].frame, CGRect(x: 40, y: 80, width: 700, height: 900))
        XCTAssertFalse(sketch.hudPanels[1].visible)

        XCTAssertEqual(desk.screenCount, 2)
        XCTAssertEqual(desk.desktopCount, 2)
    }

    func testSketchUsesTheConfiguredGap() throws {
        var config = try LoadoutsFixture.config()
        config.gap = 10
        let code = try XCTUnwrap(config.loadouts?.first { $0.name == "Code" })
        let sketch = LoadoutSketch.build(code, layouts: config.layouts, displays: LoadoutsFixture.displays, gap: 10)
        let region = try XCTUnwrap(config.layouts.first?.regions.first)
        XCTAssertEqual(sketch.regions.first?.rect,
                       LoadoutEngine.regionRect(region, visible: LoadoutsFixture.displays[0].visible, gap: 10))
        XCTAssertEqual(sketch.regions.first?.rect.minX, 10)
    }

    func testSketchDrawsTheOneScreenFormOnTheMainDisplayOnTheShowingDesktop() throws {
        let config = try LoadoutsFixture.config()
        let code = try XCTUnwrap(config.loadouts?.first { $0.name == "Code" })
        let sketch = LoadoutSketch.build(code, layouts: config.layouts, displays: LoadoutsFixture.displays, gap: 0)
        XCTAssertEqual(sketch.desktops, [nil])
        XCTAssertEqual(Set(sketch.regions.map(\.display)), [0])
        XCTAssertEqual(sketch.regions.map(\.regionID), ["t1", "t2", "t3"])
        XCTAssertEqual(code.screenCount, 1)
        XCTAssertEqual(code.desktopCount, 1)
    }

    func testSketchRedirectsAMissingDisplayAndReportsMissingLayouts() throws {
        var config = try LoadoutsFixture.config()
        let desk = try XCTUnwrap(config.loadouts?.first)
        // Only the built-in display is attached: the DELL's desktops land on free desktops there.
        var builtin = LoadoutsFixture.displays[1]
        builtin.descriptor.isMain = true
        builtin.desktops = .init(count: 4, current: 1)
        let sketch = LoadoutSketch.build(desk, layouts: config.layouts, displays: [builtin], gap: 0)
        XCTAssertEqual(Set(sketch.regions.map(\.display)), [0])
        XCTAssertEqual(sketch.notes.count, 2)
        XCTAssertTrue(sketch.notes[0].hasPrefix("DELL U2723QE is not attached: shown on Built-in Retina Display"))
        let redirected = sketch.regions.filter { $0.redirectedFrom != nil }
        XCTAssertEqual(redirected.map(\.regionID), ["d1", "d2", "d3", "e1"])
        XCTAssertEqual(Set(redirected.compactMap(\.desktop)), [2, 3], "desktops the built-in display's own part leaves free")

        config.layouts.removeAll { $0.name == "Desk · Built-in" }
        let broken = LoadoutSketch.build(desk, layouts: config.layouts, displays: LoadoutsFixture.displays, gap: 0)
        XCTAssertEqual(broken.problems, ["no layout named Desk · Built-in"])
        XCTAssertEqual(broken.regions.count, 4)
    }

    func testHUDOnlyLoadoutHasNoRegions() throws {
        let config = try LoadoutsFixture.config()
        let hud = try XCTUnwrap(config.loadouts?.last)
        let sketch = LoadoutSketch.build(hud, layouts: config.layouts, displays: LoadoutsFixture.displays, gap: 0)
        XCTAssertEqual(sketch.regions, [])
        XCTAssertEqual(sketch.problems, [])
        XCTAssertEqual(sketch.dock, .right)
        XCTAssertEqual(hud.screenCount, 0)
        XCTAssertEqual(hud.desktopCount, 0)
    }

    // MARK: - Tab model

    /// A tab over an in-memory config, recording the buttons that leave the tab.
    final class Harness {
        var config: Config
        var calls: [String] = []
        var active: String?

        init() throws { config = try LoadoutsFixture.config() }

        @MainActor func model() -> LoadoutsTabModel {
            LoadoutsTabModel(services: .init(
                config: { self.config }, displays: { LoadoutsFixture.displays }, activeLoadout: { self.active },
                perform: { try self.config.apply($0) },
                apply: { self.calls.append("apply \($0)") }, preview: { self.calls.append("preview \($0)") },
                edit: { self.calls.append("edit \($0)") }, capture: { self.calls.append("capture") },
                drawNew: { self.calls.append("draw") }))
        }
    }

    func testTabListsLoadoutsAndSelectsTheFirst() throws {
        let harness = try Harness()
        harness.active = "Code"
        let model = harness.model()
        model.reload()
        XCTAssertEqual(model.items.map(\.name), ["Desk", "Code", "Reading", "My HUD"])
        XCTAssertEqual(model.items.map(\.summary),
                       ["2 screens · 2 desktops · 6 windows · HUD", "3 windows", "1 window", "HUD · 2 apps"])
        XCTAssertEqual(model.items.map(\.isStartup), [true, false, false, false])
        XCTAssertEqual(model.items.map(\.isActive), [false, true, false, false])
        XCTAssertEqual(model.selection, "Desk")
        XCTAssertEqual(model.desktop, 1)
        model.select("Code")
        XCTAssertNil(model.desktop, "the one-screen form is on whichever desktop is showing")

        model.apply(); model.preview(); model.edit(); model.capture(); model.drawNew()
        XCTAssertEqual(harness.calls, ["apply Code", "preview Code", "edit Code", "capture", "draw"])
    }

    func testTabRenamesDuplicatesAndTogglesStartup() throws {
        let harness = try Harness()
        let model = harness.model()
        model.reload()
        model.beginRename()
        XCTAssertEqual(model.renameDraft, "Desk")
        model.renameDraft = "Code"
        model.commitRename()
        XCTAssertEqual(model.lastError, "a loadout named Code already exists")
        XCTAssertEqual(model.renameDraft, "Code", "the field stays open to fix the name")
        model.renameDraft = "Studio"
        model.commitRename()
        XCTAssertNil(model.renameDraft)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.selection, "Studio")
        XCTAssertEqual(harness.config.startupLoadout, "Studio")
        XCTAssertEqual(model.selected?.ownedLayouts.first, "Studio · DELL")

        model.duplicate()
        XCTAssertEqual(model.selection, "Studio copy")
        XCTAssertEqual(model.items.map(\.name), ["Studio", "Code", "Reading", "My HUD", "Studio copy"])

        model.toggleStartup()
        XCTAssertEqual(harness.config.startupLoadout, "Studio copy")
        XCTAssertTrue(model.selected?.isStartup ?? false)
        model.toggleStartup()
        XCTAssertNil(harness.config.startupLoadout)
    }

    func testTabDeletesOnlyAfterConfirmingAndSelectsTheNeighbour() throws {
        let harness = try Harness()
        let model = harness.model()
        model.reload()
        model.select("Code")
        model.requestDelete()
        XCTAssertEqual(model.confirmingDelete, "Code")
        XCTAssertEqual(harness.config.loadouts?.count, 4, "nothing is deleted before confirming")
        model.cancelDelete()
        XCTAssertNil(model.confirmingDelete)
        model.requestDelete()
        model.confirmDelete()
        XCTAssertEqual(harness.config.loadouts?.map(\.name), ["Desk", "Reading", "My HUD"])
        XCTAssertEqual(model.selection, "Reading")

        model.select("Desk")
        model.requestDelete()
        model.select("Reading")
        XCTAssertNil(model.confirmingDelete, "selecting another loadout drops the question")
        model.select("Desk")
        model.requestDelete()
        model.confirmDelete()
        XCTAssertEqual(harness.config.layouts.map(\.name), ["Thirds"])
        XCTAssertNil(harness.config.startupLoadout)
        XCTAssertEqual(model.selection, "Reading")
    }

    // MARK: - Socket verb

    func testLoadoutsVerbEditsThroughTheStore() throws {
        guard try TestConfig.write(LoadoutsFixture.json) else {
            throw XCTSkip("LayoutStore.configURL was already fixed to \(LayoutStore.configURL.path)")
        }
        let store = LayoutStore()
        let library = LoadoutLibrary(store: store)
        var edits: [LoadoutEdit] = []
        library.onEdit = { edit, _ in edits.append(edit) }

        let list = library.handle([:])
        XCTAssertEqual((list["loadouts"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["Desk", "Code", "Reading", "My HUD"])
        XCTAssertEqual(list["startup"] as? String, "Desk")

        // `machud loadouts rename name=Desk to=Studio`
        let renamed = library.handle(["_": "rename", "rename": "1", "name": "Desk", "to": "Studio"])
        XCTAssertEqual(renamed["ok"] as? Bool, true)
        XCTAssertEqual(renamed["loadout"] as? String, "Studio")
        XCTAssertEqual(store.config.startupLoadout, "Studio")
        let saved = try JSONDecoder().decode(Config.self, from: Data(contentsOf: LayoutStore.configURL))
        XCTAssertEqual(saved.loadouts?.first?.name, "Studio", "saved to layouts.json")

        XCTAssertEqual(library.handle(["action": "duplicate", "name": "Code"])["loadout"] as? String, "Code copy")
        XCTAssertEqual(library.handle(["action": "startup", "name": "Code"])["loadout"] as? String, "Code")
        XCTAssertEqual(store.config.startupLoadout, "Code")
        XCTAssertEqual(library.handle(["action": "startup"])["ok"] as? Bool, true)
        XCTAssertNil(store.config.startupLoadout)

        let deleted = library.handle(["_": "delete", "name": "Studio"])
        XCTAssertEqual(deleted["removedLayouts"] as? [String], ["Studio · DELL", "Studio · DELL · Desktop 2", "Studio · Built-in"])
        XCTAssertNil(store.layout(named: "Studio · DELL"))

        XCTAssertEqual(library.handle(["_": "delete", "name": "Studio"])["error"] as? String, "no loadout named Studio")
        XCTAssertEqual(library.handle(["_": "rename", "name": "Code"])["ok"] as? Bool, false)
        XCTAssertEqual(library.handle(["_": "explode"])["ok"] as? Bool, false)
        XCTAssertEqual(edits, [.rename("Desk", to: "Studio"), .duplicate("Code", as: nil), .startup("Code"), .startup(nil),
                               .delete("Studio")])
    }

    // MARK: - Snapshots

    /// Renders the settings window on the Loadouts tab offscreen (never on screen) into
    /// `MACHUD_LOADOUTS_SNAPSHOT_DIR`, else a temporary folder: the two-display, two-desktop
    /// loadout on each desktop, a one-screen one, the HUD-only one, the delete question, the
    /// rename field and the empty tab.
    func testSnapshots() throws {
        let out = ProcessInfo.processInfo.environment["MACHUD_LOADOUTS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("machud-loadouts-snapshots-\(getpid())")
        let harness = try Harness()
        harness.active = "Desk"
        let tab = harness.model()
        let window = SettingsWindowModel()
        window.tabs = [SettingsTabModel(source: SettingsSource(id: "machud", title: "MacHUD", symbol: "rectangle.3.group",
                                                               socketPath: "/nonexistent", bundleSchema: nil,
                                                               isRunning: false, canLaunch: false))]
        window.loadouts = tab
        window.selection = LoadoutsTabModel.tabID
        tab.reload()

        var files: [URL] = []
        func shot(_ name: String, size: CGSize = LoadoutsSnapshot.size) throws {
            files.append(try LoadoutsSnapshot.write(window, to: out.appendingPathComponent("loadouts-\(name).png"), size: size))
        }
        try shot("desk-desktop1")
        tab.desktop = 2
        try shot("desk-desktop2")
        tab.desktop = 1
        try shot("desk-small-window", size: CGSize(width: 620, height: 460))
        tab.select("Code")
        try shot("code")
        tab.select("My HUD")
        try shot("hud-only")
        tab.select("Desk")
        tab.requestDelete()
        try shot("delete-confirm")
        tab.cancelDelete()
        tab.beginRename()
        tab.renameDraft = "Studio"
        try shot("rename")
        tab.cancelRename()
        harness.config.loadouts = []
        tab.reload()
        try shot("empty")

        for url in files {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)), url.lastPathComponent)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            // The picture is not blank: the list/preview area differs from the backdrop corner.
            let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
            var differs = false
            for x in stride(from: 40, to: rep.pixelsWide - 40, by: 37) where !differs {
                for y in stride(from: 60, to: rep.pixelsHigh - 40, by: 29) where rep.colorAt(x: x, y: y) != corner {
                    differs = true
                    break
                }
            }
            XCTAssertTrue(differs, "\(url.lastPathComponent) is blank")
        }
        print("Loadouts snapshots: \(out.path)")
    }
}
