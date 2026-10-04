import AppKit
import XCTest
@testable import MacHUDCore

/// Fetching a window from a desktop that is not showing, against a fake world: the owner's two
/// displays (DELL showing desktop 3 of 4, the built-in its only desktop), each step failed in
/// turn. Whatever happens after the first keystroke, every display ends on the desktop it showed
/// before, or the fetch says which one it was left on.
@MainActor
final class DesktopFetchTests: XCTestCase {
    /// The displays and the window, scripted.
    private final class World {
        var showing: [Int?] = [3, 1]
        let names = ["DELL", "Built-in"]
        var switches: [(desktop: Int, display: Int)] = []
        /// Called for each switch in turn; nil does it.
        var script: [((Int, Int) -> Result<Int, Spaces.SwitchError>)?] = []
        var reachable = true
        var placed: [CGRect] = []
        var onScreen = true

        var fetchWorld: DesktopFetch.World {
            DesktopFetch.World(
                showing: { [unowned self] in self.showing },
                displayName: { [unowned self] in self.names[$0] },
                switchTo: { [unowned self] desktop, display, done in
                    self.switches.append((desktop, display))
                    let step = self.script.isEmpty ? nil : self.script.removeFirst()
                    if let step {
                        done(step(desktop, display))
                    } else {
                        self.showing[display] = desktop
                        done(.success(desktop))
                    }
                },
                reach: { [unowned self] in
                    guard self.reachable else { return nil }
                    return { self.placed.append($0) }
                },
                isOnScreen: { [unowned self] in self.onScreen },
                after: { _, body in body() })
        }
    }

    private let target = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let parked = CGRect(x: 2600, y: 100, width: 800, height: 600)

    /// The window is on DELL desktop 1; it goes into a region on DELL, parked on the built-in
    /// display while DELL switches back.
    private func fetch(_ world: World, via: CGRect? = nil) -> DesktopFetch.Outcome? {
        var outcome: DesktopFetch.Outcome?
        DesktopFetch.run(DesktopFetch.Request(home: 0, desktop: 1, target: target, via: via ?? parked),
                         world: world.fetchWorld) { outcome = $0 }
        return outcome
    }

    private func switches(_ world: World) -> [String] { world.switches.map { "\($0.display):\($0.desktop)" } }

    func testAFetchShowsTheDesktopParksTheWindowAndSwitchesBack() {
        let world = World()
        XCTAssertEqual(fetch(world), .fetched)
        XCTAssertEqual(switches(world), ["0:1", "0:3"])
        XCTAssertEqual(world.placed, [parked, target], "parked on the other display, then moved home")
        XCTAssertEqual(world.showing, [3, 1])
    }

    func testAWindowAccessibilityCannotReachStillSwitchesBack() {
        let world = World()
        world.reachable = false
        guard case .failed(let reason) = fetch(world) else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("accessibility cannot reach it"), reason)
        XCTAssertEqual(switches(world), ["0:1", "0:3"])
        XCTAssertEqual(world.showing, [3, 1])
        XCTAssertTrue(world.placed.isEmpty)
    }

    func testAnAppThatQuitMidwayStillSwitchesBack() {
        let world = World()
        world.onScreen = false
        world.script = [nil, nil]
        // Reached and parked, then gone by the time DELL is back: not on screen.
        guard case .failed(let reason) = fetch(world) else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("desktop 1"), reason)
        XCTAssertEqual(world.showing, [3, 1])
    }

    func testASwitchThatStopsPartWayIsUndone() {
        let world = World()
        // One keystroke lands on desktop 2, the next is swallowed.
        world.script = [{ _, display in world.showing[display] = 2; return .failure(.didNotSwitch(to: 1)) }]
        guard case .failed(let reason) = fetch(world) else { return XCTFail("expected a failure") }
        XCTAssertEqual(reason, Spaces.SwitchError.didNotSwitch(to: 1).message, "the message, not the code")
        XCTAssertEqual(switches(world), ["0:1", "0:3"])
        XCTAssertEqual(world.showing, [3, 1])
    }

    func testASwitchBackThatFailsIsReportedAndNeverASuccess() {
        let world = World()
        // Both passes fail to switch DELL back.
        world.script = [nil, { _, _ in .failure(.shortcutDisabled) }, { _, _ in .failure(.shortcutDisabled) }]
        guard case .leftOnAnotherDesktop(let reason) = fetch(world) else { return XCTFail("expected left on another desktop") }
        XCTAssertTrue(reason.contains("left on desktop 1 of DELL"), reason)
        XCTAssertTrue(reason.contains(Spaces.SwitchError.shortcutDisabled.message), reason)
    }

    func testASwitchBackThatFailsOnceIsTriedAgain() {
        let world = World()
        world.script = [nil, { _, _ in .failure(.didNotSwitch(to: 3)) }]
        XCTAssertEqual(fetch(world), .fetched)
        XCTAssertEqual(switches(world), ["0:1", "0:3", "0:3"])
        XCTAssertEqual(world.showing, [3, 1])
    }

    func testAnUnknownHomeDesktopStartsNothing() {
        let world = World()
        world.showing = [nil, 1]
        guard case .failed(let reason) = fetch(world) else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("DELL"), reason)
        XCTAssertTrue(world.switches.isEmpty, "no keystroke")
    }

    /// A keystroke typed late (System Events answering long after a quick keystroke would) is
    /// waited for: the fetch reports only once it has landed, and ends on the recorded desktop.
    func testALateKeystrokeIsWaitedFor() {
        let world = World()
        var outcome: DesktopFetch.Outcome?
        var showingWhenReported: [Int?] = []
        var fetchWorld = world.fetchWorld
        let inner = fetchWorld.switchTo
        fetchWorld.switchTo = { desktop, display, done in
            // The switch back answers after a delay, and its keystroke lands at that moment.
            guard world.switches.count == 1 else { inner(desktop, display, done); return }
            world.switches.append((desktop, display))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                world.showing[display] = desktop
                done(.success(desktop))
            }
        }
        DesktopFetch.run(DesktopFetch.Request(home: 0, desktop: 1, target: target, via: parked), world: fetchWorld) {
            outcome = $0
            showingWhenReported = world.showing
        }
        XCTAssertNil(outcome, "not reported before the switch back has finished")
        XCTAssertTrue(spin(until: { outcome != nil }))
        XCTAssertEqual(outcome, .fetched)
        XCTAssertEqual(showingWhenReported, [3, 1])
        XCTAssertEqual(switches(world), ["0:1", "0:3"])
    }

    /// Putting one display back moved another one already checked: it is caught and put back too.
    func testARestoreThatMovesAnotherDisplayIsCaught() {
        let world = World()
        world.showing = [3, 1]
        // Fetching moves the built-in to 2; putting the built-in back moves DELL to 4.
        world.script = [{ desktop, display in
            world.showing[display] = desktop
            world.showing[1] = 2
            return .success(desktop)
        }, nil, { desktop, display in
            world.showing[display] = desktop
            world.showing[0] = 4
            return .success(desktop)
        }]
        XCTAssertEqual(fetch(world), .fetched)
        XCTAssertEqual(switches(world), ["0:1", "0:3", "1:1", "0:3"])
        XCTAssertEqual(world.showing, [3, 1])
    }

    func testADisplayThatWillNotStayPutIsReported() {
        let world = World()
        // Putting DELL back moves the built-in, and putting the built-in back moves DELL, every time.
        let dell: (Int, Int) -> Result<Int, Spaces.SwitchError> = { desktop, display in
            world.showing[display] = desktop
            world.showing[1] = 2
            return .success(desktop)
        }
        let builtIn: (Int, Int) -> Result<Int, Spaces.SwitchError> = { desktop, display in
            world.showing[display] = desktop
            world.showing[0] = 4
            return .success(desktop)
        }
        world.script = [nil, dell, builtIn, dell, builtIn]
        guard case .leftOnAnotherDesktop(let reason) = fetch(world) else { return XCTFail("expected left on another desktop") }
        XCTAssertTrue(reason.contains("left on desktop 4 of DELL"), reason)
        XCTAssertEqual(world.switches.count, 5, "two passes, then said")
    }

    func testEveryDisplayIsPutBack() {
        let world = World()
        // Showing DELL's desktop 1 also moved the built-in display (as macOS does with
        // "Displays have separate Spaces" off).
        world.script = [{ desktop, display in
            world.showing[display] = desktop
            world.showing[1] = 2
            return .success(desktop)
        }]
        XCTAssertEqual(fetch(world), .fetched)
        XCTAssertEqual(switches(world), ["0:1", "0:3", "1:1"])
        XCTAssertEqual(world.showing, [3, 1])
    }
}
