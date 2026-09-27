import XCTest
@testable import MacHUDCore

final class DisplayPinningTests: XCTestCase {
    private let dellA = ScreenDescriptor(name: "DELL S2722QC", isMain: true, isBuiltin: false, persistentID: "10ac-a0b4-111")
    private let dellB = ScreenDescriptor(name: "DELL S2722QC (2)", isMain: false, isBuiltin: false, persistentID: "10ac-a0b4-222")
    private let lg = ScreenDescriptor(name: "LG UltraFine", isMain: false, isBuiltin: false, persistentID: "1e6d-5b11-0")
    private let builtin = ScreenDescriptor(name: "Built-in Retina Display", isMain: false, isBuiltin: true, persistentID: "610-a04c-0")

    func testDisplayRefCodesWithNameFallback() throws {
        let ref = ScreenRef.display(id: "10ac-a0b4-111", name: "DELL S2722QC")
        let data = try JSONEncoder().encode(ref)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(obj, ["display": "10ac-a0b4-111", "name": "DELL S2722QC"])
        XCTAssertEqual(try JSONDecoder().decode(ScreenRef.self, from: data), ref)
        XCTAssertEqual(try JSONDecoder().decode(ScreenRef.self, from: Data(#"{"display": "x"}"#.utf8)),
                       .display(id: "x", name: ""))
        XCTAssertEqual(ref.label, "DELL S2722QC")
    }

    func testDisplayRefResolvesByIdThenName() {
        let a = ScreenRef.display(id: "10ac-a0b4-111", name: "DELL S2722QC")
        XCTAssertEqual(a.index(in: [lg, dellB, dellA]), 2, "by id, whatever the order and names")
        // Renamed by macOS but same panel: still found by id.
        var renamed = dellA; renamed.name = "DELL S2722QC (1)"
        XCTAssertEqual(a.index(in: [renamed]), 0)
        // The other DELL of the same model is a different screen: no name fallback onto it.
        var otherSameName = dellB; otherSameName.name = "DELL S2722QC"
        XCTAssertNil(a.index(in: [otherSameName, lg]))
        // A display that reports no id is matched by exact name.
        let anonymous = ScreenDescriptor(name: "DELL S2722QC", isMain: false, isBuiltin: false, persistentID: nil)
        XCTAssertEqual(a.index(in: [lg, anonymous]), 1)
    }

    func testMigrationPinsAttachedNamedDisplaysOnly() {
        var loadout = Loadout(name: "Desk", layout: "L", slots: [], hotkey: nil)
        loadout.screens = [
            ScreenAssignment(screen: .name("DELL S2722QC"), layout: "L", slots: []),
            ScreenAssignment(screen: .name("LG"), layout: "L", slots: [],
                             fallback: .init(screen: .name("DELL S2722QC (2)"), space: 2)),
            ScreenAssignment(screen: .builtin, layout: "L", slots: []),
            ScreenAssignment(screen: .name("Studio Display"), layout: "L", slots: []),   // not attached
            ScreenAssignment(screen: .name("DELL"), layout: "L", slots: []),             // ambiguous
            ScreenAssignment(screen: .index(2), layout: "L", slots: []),
        ]
        var config = Config.defaults
        config.loadouts = [loadout]
        let out = DisplayPinning.migrate(config, screens: [dellA, dellB, lg, builtin])
        let refs = out.loadouts![0].screens!.map(\.screen)
        XCTAssertEqual(refs, [.display(id: "10ac-a0b4-111", name: "DELL S2722QC"),
                              .display(id: "1e6d-5b11-0", name: "LG UltraFine"),
                              .builtin, .name("Studio Display"), .name("DELL"), .index(2)])
        XCTAssertEqual(out.loadouts![0].screens![1].fallback?.screen, .display(id: "10ac-a0b4-222", name: "DELL S2722QC (2)"))
        XCTAssertEqual(out.loadouts![0].screens![1].fallback?.space, 2)
        XCTAssertEqual(DisplayPinning.migrate(out, screens: [dellA, dellB, lg, builtin]), out, "idempotent")
        XCTAssertEqual(DisplayPinning.migrate(config, screens: []), config)
    }

    func testFallbackPlanningUsesPinnedIds() {
        let requests = [ScreenFallback.Request(screen: .display(id: "10ac-a0b4-222", name: "DELL S2722QC (2)"),
                                               space: nil, fallback: nil)]
        let outcomes = ScreenFallback.plan(requests, screens: [dellA, lg], policy: .skip,
                                           desktops: { _ in ScreenFallback.Desktops(count: 1, current: 1) })
        guard case .skipped = outcomes[0] else { return XCTFail("missing DELL must not land on the other DELL: \(outcomes)") }
    }

    @MainActor
    func testDisplayWatcherFiresOnlyWhenTheSetChanges() {
        var screens = ["a", "b"]
        var fired = 0
        let watcher = DisplayWatcher(signature: { screens }) { fired += 1 }
        XCTAssertFalse(watcher.check(), "resolution changes and the like do not count")
        screens = ["a"]
        XCTAssertTrue(watcher.check())
        XCTAssertFalse(watcher.check())
        screens = ["a", "c"]
        watcher.debounce = 0.05
        watcher.screensChanged()
        watcher.screensChanged()                      // a burst: one check
        XCTAssertTrue(spin { fired == 2 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fired, 2)
    }
}
