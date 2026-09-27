import XCTest
@testable import MacHUDCore

final class LoadoutFixupTests: XCTestCase {
    private func loadout(_ name: String, layout: String, regionIDs: [String]) -> Loadout {
        Loadout(name: name, layout: layout,
                slots: regionIDs.map { Slot(regionID: $0, occupant: .panel(id: "dock")) }, hotkey: nil)
    }

    func testRemovingRegionDropsMatchingSlotOnly() {
        let loadouts = [
            loadout("Work", layout: "L1", regionIDs: ["a", "b"]),
            loadout("Play", layout: "L1", regionIDs: ["b", "c"]),
        ]
        let out = LoadoutFixup.removingRegion("b", from: loadouts)
        XCTAssertEqual(out[0].slots.map { $0.regionID }, ["a"])
        XCTAssertEqual(out[1].slots.map { $0.regionID }, ["c"])
    }

    func testRemovingRegionNoOpWhenAbsent() {
        let loadouts = [loadout("Work", layout: "L1", regionIDs: ["a", "b"])]
        let out = LoadoutFixup.removingRegion("z", from: loadouts)
        XCTAssertEqual(out, loadouts)
    }

    func testRenamingLayoutUpdatesMatchingLoadoutsOnly() {
        let loadouts = [
            loadout("Work", layout: "L1", regionIDs: ["a"]),
            loadout("Play", layout: "L2", regionIDs: ["b"]),
        ]
        let out = LoadoutFixup.renamingLayout(from: "L1", to: "Home", in: loadouts)
        XCTAssertEqual(out[0].layout, "Home")
        XCTAssertEqual(out[1].layout, "L2")
    }

    func testRenamingLayoutNoOpWhenNoMatch() {
        let loadouts = [loadout("Work", layout: "L1", regionIDs: ["a"])]
        let out = LoadoutFixup.renamingLayout(from: "Nope", to: "Home", in: loadouts)
        XCTAssertEqual(out, loadouts)
    }

    /// Integration check: EditorView.deleteRegion actually applies the fixup to
    /// config.loadouts, not just the pure LoadoutFixup function in isolation.
    @MainActor
    func testEditorViewDeleteRegionAppliesFixup() {
        let view = EditorView(frame: .zero)
        var config = Config.defaults
        config.layouts = [Layout(name: "L1", regions: [
            Region(id: "a", name: "A", x: 0, y: 0, w: 0.5, h: 1, hit: nil),
            Region(id: "b", name: "B", x: 0.5, y: 0, w: 0.5, h: 1, hit: nil),
        ])]
        config.loadouts = [loadout("Work", layout: "L1", regionIDs: ["a", "b"])]
        view.config = config
        view.layoutIndex = 0

        view.deleteRegion(0)

        XCTAssertEqual(view.config.layouts.first?.regions.map { $0.id }, ["b"])
        XCTAssertEqual(view.config.loadouts?.first?.slots.map { $0.regionID }, ["b"])
    }
}
