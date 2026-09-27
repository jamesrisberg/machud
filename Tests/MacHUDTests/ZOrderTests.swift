import XCTest
@testable import MacHUDCore

final class ZOrderTests: XCTestCase {
    func testCapturedGivesZeroToUnstackedWindows() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 200, y: 0, width: 100, height: 100)]
        XCTAssertEqual(ZOrder.captured(frontToBack: frames), [0, 0])
    }

    func testTouchingWindowsDoNotStack() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        XCTAssertEqual(ZOrder.captured(frontToBack: frames), [0, 0])
    }

    func testCapturedOrdersOverlapsFrontToBack() {
        // Front: small a overlaps b; b overlaps c and d behind it; e stands alone.
        let a = CGRect(x: 0, y: 0, width: 50, height: 50)
        let b = CGRect(x: 20, y: 20, width: 200, height: 200)
        let c = CGRect(x: 150, y: 150, width: 200, height: 200)
        let d = CGRect(x: 100, y: 0, width: 200, height: 100)
        let e = CGRect(x: 1000, y: 1000, width: 50, height: 50)
        let z = ZOrder.captured(frontToBack: [a, b, c, d, e])
        XCTAssertGreaterThan(z[0], z[1])
        XCTAssertGreaterThan(z[1], z[2])
        XCTAssertGreaterThan(z[1], z[3])
        XCTAssertEqual(z[4], 0)
        // Raising in ascending z puts the frontmost window last.
        let order = ZOrder.raiseOrder(z)
        XCTAssertEqual(order.last, 0)
        XCTAssertLessThan(order.firstIndex(of: 1)!, order.firstIndex(of: 0)!)
        XCTAssertLessThan(order.firstIndex(of: 2)!, order.firstIndex(of: 1)!)
    }

    func testRaiseOrderIsStableOnTies() {
        XCTAssertEqual(ZOrder.raiseOrder([2, 0, 1, 0, -1]), [4, 1, 3, 2, 0])
        XCTAssertFalse(ZOrder.isStacked([0, 0]))
        XCTAssertTrue(ZOrder.isStacked([0, -1]))
    }

    func testBumpMovesOnePastOverlappingNeighbours() {
        let rects = ["a": FractionRect(x: 0, y: 0, w: 0.5, h: 0.5),
                     "b": FractionRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5),
                     "c": FractionRect(x: 0.6, y: 0.6, w: 0.3, h: 0.3),
                     "far": FractionRect(x: 0.9, y: 0, w: 0.1, h: 0.1)]
        let z = ["a": 0, "b": 0, "c": 3]
        XCTAssertEqual(ZOrder.bumped("a", up: true, rects: rects, z: z), 1)
        XCTAssertEqual(ZOrder.bumped("a", up: false, rects: rects, z: z), -1)
        // b overlaps a (0) and c (3): up goes past a only, one step at a time.
        XCTAssertEqual(ZOrder.bumped("b", up: true, rects: rects, z: z), 1)
        XCTAssertEqual(ZOrder.bumped("b", up: true, rects: rects, z: ["a": 0, "b": 1, "c": 3]), 4)
        XCTAssertNil(ZOrder.bumped("c", up: true, rects: rects, z: z))
        XCTAssertNil(ZOrder.bumped("far", up: true, rects: rects, z: z))
    }

    func testSlotJSONStaysBackwardCompatible() throws {
        let old = #"{"regionID":"r","occupant":{"kind":"panel","id":"dock"}}"#
        let slot = try JSONDecoder().decode(Slot.self, from: Data(old.utf8))
        XCTAssertEqual(slot.stackOrder, 0)
        XCTAssertFalse(slot.isParked)
        XCTAssertEqual(slot.parkEdge, .left)
        let encoded = String(decoding: try JSONEncoder().encode(slot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"z\""))
        XCTAssertFalse(encoded.contains("mode"))

        let parked = #"{"regionID":"r","occupant":{"kind":"panel","id":"dock"},"z":2,"mode":"parked","edge":"right","peek":6}"#
        let p = try JSONDecoder().decode(Slot.self, from: Data(parked.utf8))
        XCTAssertEqual(p.stackOrder, 2)
        XCTAssertTrue(p.isParked)
        XCTAssertEqual(p.parkEdge, .right)
        XCTAssertEqual(p.parkPeek, 6)
        XCTAssertEqual(try JSONDecoder().decode(Slot.self, from: try JSONEncoder().encode(p)), p)
    }

    func testReplacingAnOccupantKeepsSlotSettings() {
        var loadout = Loadout(name: "L", layout: "x", slots: [], hotkey: nil)
        loadout.slots = [Slot(regionID: "r", occupant: .panel(id: "dock"), space: 2, z: 3, mode: .parked, edge: .top, peek: 4)]
        loadout.set(.panel(id: "servers"), regionID: "r")
        let slot = loadout.slot(regionID: "r")
        XCTAssertEqual(slot?.occupant, .panel(id: "servers"))
        XCTAssertEqual(slot?.space, 2)
        XCTAssertEqual(slot?.z, 3)
        XCTAssertEqual(slot?.mode, .parked)
        loadout.set(nil, regionID: "r")
        XCTAssertNil(loadout.slot(regionID: "r"))
    }
}
