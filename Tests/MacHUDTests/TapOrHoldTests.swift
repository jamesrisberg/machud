import XCTest
@testable import MacHUDCore

/// The wheel's hotkey told apart by time, on a clock the test steps by hand: a release within
/// the threshold is a tap and the wheel never shows; held to the threshold the wheel shows and
/// the release commits it.
@MainActor
final class TapOrHoldTests: XCTestCase {
    /// A clock whose time moves only when told, running what was scheduled as it passes.
    final class Steps {
        var now: TimeInterval = 100
        private var pending: [(at: TimeInterval, id: Int, run: @MainActor () -> Void)] = []
        private var next = 0

        var clock: TapOrHold.Clock {
            TapOrHold.Clock(now: { [unowned self] in self.now }, after: { [unowned self] delay, run in
                let id = self.next
                self.next += 1
                self.pending.append((self.now + delay, id, run))
                return { [weak self] in self?.pending.removeAll { $0.id == id } }
            })
        }

        var scheduled: Int { pending.count }

        @MainActor
        func advance(_ seconds: TimeInterval) {
            now += seconds
            let due = pending.filter { $0.at <= now + 1e-9 }
            pending.removeAll { $0.at <= now + 1e-9 }
            for item in due { item.run() }
        }
    }

    private var events: [String] = []
    private var showing = false

    private func key(threshold: TimeInterval = 0.2, steps: Steps) -> TapOrHold {
        let key = TapOrHold(clock: steps.clock, threshold: { threshold })
        key.onTap = { [unowned self] in self.events.append("tap") }
        key.onHold = { [unowned self] in self.events.append("hold"); self.showing = true }
        key.onRelease = { [unowned self] in self.events.append("release"); self.showing = false }
        key.isShowing = { [unowned self] in self.showing }
        return key
    }

    func testAQuickReleaseIsATapAndTheWheelNeverShows() {
        let steps = Steps()
        let key = key(steps: steps)
        key.press()
        steps.advance(0.12)
        key.release()
        XCTAssertEqual(events, ["tap"])
        XCTAssertEqual(steps.scheduled, 0, "the hold was called off")
        steps.advance(1)
        XCTAssertEqual(events, ["tap"], "nothing shows later either")
        XCTAssertEqual(key.phase, .idle)
    }

    func testHeldToTheThresholdTheWheelShowsAndTheReleaseCommits() {
        let steps = Steps()
        let key = key(steps: steps)
        key.press()
        steps.advance(0.19)
        XCTAssertEqual(events, [], "not yet")
        steps.advance(0.01)
        XCTAssertEqual(events, ["hold"])
        XCTAssertEqual(key.phase, .held)
        steps.advance(2)
        key.release()
        XCTAssertEqual(events, ["hold", "release"])
    }

    /// The threshold is read at each press: a changed setting takes effect at once.
    func testTheThresholdIsReadAtEachPress() {
        let steps = Steps()
        var threshold: TimeInterval = 0.2
        let key = TapOrHold(clock: steps.clock, threshold: { threshold })
        key.onTap = { [unowned self] in self.events.append("tap") }
        key.onHold = { [unowned self] in self.events.append("hold") }
        threshold = 0.5
        key.press()
        steps.advance(0.3)
        key.release()
        XCTAssertEqual(events, ["tap"])
        threshold = 0.05
        key.press()
        steps.advance(0.06)
        XCTAssertEqual(events, ["tap", "hold"])
    }

    /// The key repeats while held: a press while it is down changes nothing.
    func testRepeatedPressesWhileDownAreIgnored() {
        let steps = Steps()
        let key = key(steps: steps)
        key.press()
        steps.advance(0.1)
        key.press()
        XCTAssertEqual(steps.scheduled, 1)
        steps.advance(0.1)
        key.press()
        XCTAssertEqual(events, ["hold"])
        key.release()
        XCTAssertEqual(events, ["hold", "release"])
    }

    /// A release that comes after the threshold before the hold could show (the main thread was
    /// busy) is neither a tap nor a commit.
    func testALateReleaseBeforeTheWheelShowedIsNeither() {
        let steps = Steps()
        let key = key(steps: steps)
        key.press()
        steps.now += 0.3
        key.release()
        XCTAssertEqual(events, [])
        XCTAssertEqual(steps.scheduled, 0)
    }

    /// A wheel already showing (opened by a script) makes the press a hold at once: its release
    /// commits, and a release with no press seen still commits a wheel showing.
    func testAWheelAlreadyShowingIsCommittedByTheRelease() {
        let steps = Steps()
        let key = key(steps: steps)
        showing = true
        key.press()
        XCTAssertEqual(steps.scheduled, 0)
        key.release()
        XCTAssertEqual(events, ["release"])
        showing = true
        key.release()
        XCTAssertEqual(events, ["release", "release"])
        key.release()
        XCTAssertEqual(events, ["release", "release"], "nothing showing, no press: nothing")
    }

    /// The setting: 200 ms by default, kept within 50 to 1000, read from `hotkeys.tapMilliseconds`.
    func testTheThresholdSetting() throws {
        XCTAssertEqual(Hotkeys.defaults.tapThreshold, 0.2, accuracy: 1e-9)
        var hotkeys = Hotkeys.defaults
        hotkeys.tapMilliseconds = 10
        XCTAssertEqual(hotkeys.tapThreshold, 0.05, accuracy: 1e-9)
        hotkeys.tapMilliseconds = 5000
        XCTAssertEqual(hotkeys.tapThreshold, 1, accuracy: 1e-9)
        let decoded = try JSONDecoder().decode(Hotkeys.self, from: Data(#"{"loadoutMenu": {"key": "space", "modifiers": ["control", "option"]}, "tapMilliseconds": 320}"#.utf8))
        XCTAssertEqual(decoded.tapThreshold, 0.32, accuracy: 1e-9)
        XCTAssertEqual(decoded.loadoutMenu, Hotkeys.defaults.loadoutMenu, "the stored hotkey is kept")
        let old = try JSONDecoder().decode(Hotkeys.self, from: Data(#"{"loadoutMenu": {"key": "f5", "modifiers": ["command"]}}"#.utf8))
        XCTAssertEqual(old.tapThreshold, 0.2, accuracy: 1e-9, "a config from before the setting")
        XCTAssertEqual(old.loadoutMenu, HotKey(key: "f5", modifiers: ["command"]))
    }
}
