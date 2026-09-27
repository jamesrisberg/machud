import XCTest
import HUDKit
@testable import MacHUDCore

final class ParkGeometryTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let rest = CGRect(x: 100, y: 200, width: 800, height: 600)

    func testSingleScreenParksPastTheEdgeWithPeek() {
        let r = ParkGeometry.parkedFrame(rest: rest, edge: .left, peek: 6, screen: main, screens: [main])
        XCTAssertEqual(r.frame, CGRect(x: -794, y: 200, width: 800, height: 600))
        XCTAssertFalse(r.crossedDisplay)
        XCTAssertEqual(ParkGeometry.visibleSliver(of: r.frame, edge: .left, screens: [main]), 6)
        let top = ParkGeometry.parkedFrame(rest: rest, edge: .top, peek: 0, screen: main, screens: [main]).frame
        XCTAssertEqual(top.minY, 1080)
        XCTAssertEqual(ParkGeometry.visibleSliver(of: top, edge: .top, screens: [main]), 0)
    }

    func testOuterEdgeOfASecondScreen() {
        let onRight = CGRect(x: 2500, y: 300, width: 900, height: 700)
        let r = ParkGeometry.parkedFrame(rest: onRight, edge: .right, peek: 0, screen: right, screens: [main, right])
        XCTAssertEqual(r.frame.minX, right.maxX)
        XCTAssertFalse(r.crossedDisplay)
    }

    func testSharedEdgeGoesPastTheWholeDesktop() {
        // The right edge of the main screen borders the second display.
        let r = ParkGeometry.parkedFrame(rest: rest, edge: .right, peek: 10, screen: main, screens: [main, right])
        XCTAssertTrue(r.crossedDisplay)
        XCTAssertEqual(r.frame.minX, right.maxX)
        XCTAssertEqual(ParkGeometry.visibleSliver(of: r.frame, edge: .right, screens: [main, right]), 0)
        // The left edge of the second screen borders the main one.
        let onRight = CGRect(x: 2000, y: 100, width: 600, height: 400)
        let l = ParkGeometry.parkedFrame(rest: onRight, edge: .left, peek: 0, screen: right, screens: [main, right])
        XCTAssertTrue(l.crossedDisplay)
        XCTAssertEqual(l.frame.maxX, main.minX)
    }

    func testNeighbourOutsideTheWindowsBandDoesNotCount() {
        // A display above-right that the window's rows never reach.
        let high = CGRect(x: 1920, y: 1080, width: 1920, height: 1080)
        let r = ParkGeometry.parkedFrame(rest: rest, edge: .right, peek: 0, screen: main, screens: [main, high])
        XCTAssertFalse(r.crossedDisplay)
        XCTAssertEqual(r.frame.minX, main.maxX)
    }

    func testDefaultOrbSitsOnTheEdgeCentredOnTheWindows() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let o = ParkGeometry.defaultOrbOrigin(edge: .left, restUnion: rest, visible: visible, size: 44)
        XCTAssertEqual(o, CGPoint(x: 6, y: rest.midY - 22))
        let clamped = ParkGeometry.defaultOrbOrigin(edge: .right, restUnion: CGRect(x: 0, y: 1040, width: 10, height: 10),
                                                    visible: visible, size: 44)
        XCTAssertEqual(clamped, CGPoint(x: 1920 - 44 - 6, y: 1055 - 44 - 6))
    }
}

final class ParkingStoreTests: XCTestCase {
    func testRestFramesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ParkingStore(url: dir.appendingPathComponent("state/parking.json"))
        XCTAssertEqual(store.load(), ParkingState())

        var state = ParkingState()
        state.parked = [
            ParkedRecord(id: "w42", label: "TextEdit · Untitled", kind: .ax, pid: 123, bundleID: "com.apple.TextEdit",
                         title: "Untitled", windowNumber: 42, rest: CGRect(x: 10, y: 20, width: 300, height: 200),
                         parked: CGRect(x: -290, y: 20, width: 300, height: 200), edge: .left, peek: 0, sliver: 10),
            ParkedRecord(id: "region-1", label: "portal", kind: .cooperative, panelID: "portal", socket: "/tmp/x.sock",
                         rest: CGRect(x: 1, y: 2, width: 3, height: 4), parked: CGRect(x: 1, y: 2, width: 3, height: 4),
                         edge: .top, peek: 4),
        ]
        state.orbs = ["left": CGPoint(x: 6, y: 400)]
        state.orbsHidden = true
        store.save(state)
        XCTAssertEqual(store.load(), state)
    }

    func testCorruptFileLoadsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ParkingStore(url: url).load(), ParkingState())
    }
}

final class OrbHoverTests: XCTestCase {
    func testHoverRevealsAfterDelayThenConcealsAfterLeaving() {
        var h = OrbHover()
        XCTAssertNil(h.update(onOrb: true, inside: true, now: 0))
        XCTAssertNil(h.update(onOrb: true, inside: true, now: 0.1))
        XCTAssertEqual(h.update(onOrb: true, inside: true, now: 0.16), .reveal)
        XCTAssertTrue(h.isRevealed)
        // Moving from the orb onto the windows keeps them out.
        XCTAssertNil(h.update(onOrb: false, inside: true, now: 1))
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 2))
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 2.5))
        // Coming back in before the delay cancels the conceal.
        XCTAssertNil(h.update(onOrb: false, inside: true, now: 2.55))
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 3))
        XCTAssertEqual(h.update(onOrb: false, inside: false, now: 3.61), .conceal)
        XCTAssertEqual(h.phase, .concealed)
    }

    func testBriefHoverDoesNothing() {
        var h = OrbHover()
        _ = h.update(onOrb: true, inside: true, now: 0)
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 0.1))
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 1))
        XCTAssertEqual(h.phase, .concealed)
    }

    func testClickPinsUntilClickedAgain() {
        var h = OrbHover()
        _ = h.update(onOrb: true, inside: true, now: 0)
        XCTAssertEqual(h.update(onOrb: true, inside: true, now: 0.2), .reveal)
        XCTAssertNil(h.click())
        XCTAssertEqual(h.phase, .pinned)
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 5))
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 50))
        XCTAssertTrue(h.isRevealed)
        XCTAssertEqual(h.click(), .conceal)
        // Still on the orb after unpinning: no immediate re-reveal.
        XCTAssertNil(h.update(onOrb: true, inside: true, now: 51))
        XCTAssertNil(h.update(onOrb: true, inside: true, now: 52))
        XCTAssertFalse(h.isRevealed)
        XCTAssertNil(h.update(onOrb: false, inside: false, now: 53))
        _ = h.update(onOrb: true, inside: true, now: 54)
        XCTAssertEqual(h.update(onOrb: true, inside: true, now: 54.2), .reveal)
    }

    func testClickWhileConcealedRevealsPinned() {
        var h = OrbHover()
        XCTAssertEqual(h.click(), .reveal)
        XCTAssertEqual(h.phase, .pinned)
    }

    func testExternalRevealAndConceal() {
        var h = OrbHover()
        XCTAssertEqual(h.reveal(pin: false), .reveal)
        XCTAssertNil(h.reveal(pin: true))
        XCTAssertEqual(h.phase, .pinned)
        XCTAssertEqual(h.conceal(), .conceal)
        XCTAssertNil(h.conceal())
    }
}

final class CooperativeParkingTests: XCTestCase {
    @MainActor
    func testParkedModeIsSentOverTheSocket() throws {
        let path = "/tmp/gs-park-test-\(getpid()).sock"
        let server = HUDSocketServer(path: path)
        let received = expectation(description: "panel mode")
        nonisolated(unsafe) var args: [String: String] = [:]
        server.register("panel") { a, done in
            args = a
            done(["ok": true])
            received.fulfill()
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        ParkingController.requestMode(client: HUDSocketClient(path: path), panelID: "portal", mode: .parked)
        wait(for: [received], timeout: 5)
        XCTAssertEqual(args["id"], "portal")
        XCTAssertEqual(args["action"], "mode")
        XCTAssertEqual(args["mode"], "parked")
    }
}

final class ParkEdgeTests: XCTestCase {
    func testNearestEdgeCanSkipTheTop() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let high = CGRect(x: 800, y: 900, width: 300, height: 150)
        XCTAssertEqual(ParkGeometry.nearestEdge(for: high, in: screen), .top)
        // Next nearest: left 950 pt, right 970 pt, bottom 975 pt.
        XCTAssertEqual(ParkGeometry.nearestEdge(for: high, in: screen, allowTop: false), .left)
        let tall = CGRect(x: 800, y: 600, width: 300, height: 450)
        XCTAssertEqual(ParkGeometry.nearestEdge(for: tall, in: screen, allowTop: false), .bottom)
        XCTAssertEqual(ParkGeometry.nearestEdge(for: CGRect(x: 10, y: 900, width: 100, height: 100), in: screen,
                                                allowTop: false), .left)
    }
}
