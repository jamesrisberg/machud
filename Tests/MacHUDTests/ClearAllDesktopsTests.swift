import XCTest
@testable import MacHUDCore

/// What a standalone `clear` minimises. With multi-desktop loadouts on it reaches every window
/// on every desktop; off, only the windows showing on one screen, the same set `apply clear=1`
/// clears for that screen. The window lists are injected: none of this touches a real window.
final class ClearAllDesktopsTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let side = CGRect(x: 1000, y: 0, width: 1000, height: 800)

    private func entry(_ number: Int, _ pid: pid_t, _ frame: CGRect, onScreen: Bool = true) -> AllSpacesWindows.Entry {
        AllSpacesWindows.Entry(number: number, pid: pid, frame: frame, onScreen: onScreen)
    }

    /// The setting on: no screen is given, so every window on every desktop is a target.
    func testWithMultiDesktopLoadoutsOnClearTargetsExemptOwnSiblingAndHiddenApps() {
        let e = { (n: Int, pid: pid_t, on: Bool) in
            AllSpacesWindows.Entry(number: n, pid: pid, frame: .zero, onScreen: on)
        }
        let entries = [e(1, 10, true), e(2, 10, false), e(3, 20, true), e(4, 30, false), e(5, 40, true)]
        let targets = AllSpacesWindows.clearTargets(entries, exempt: [20], hidden: [40])
        XCTAssertEqual(targets[10]?.map(\.number), [1, 2], "windows on other desktops are included")
        XCTAssertEqual(targets[30]?.map(\.number), [4])
        XCTAssertNil(targets[20])
        XCTAssertNil(targets[40])
    }

    /// The setting off: one screen. Windows on other desktops and on other displays stay.
    func testOnAScreenOnlyItsShowingWindowsAreTargets() {
        let entries = [
            entry(1, 10, main.insetBy(dx: 20, dy: 20)),                      // showing here
            entry(2, 10, main.insetBy(dx: 40, dy: 40), onScreen: false),     // another desktop of this screen
            entry(3, 11, side.insetBy(dx: 20, dy: 20)),                      // showing on the other display
            entry(4, 11, side.insetBy(dx: 40, dy: 40), onScreen: false),     // another desktop of the other display
            entry(5, 20, main.insetBy(dx: 60, dy: 60)),                      // a sibling's panel, here
            entry(6, 40, main.insetBy(dx: 80, dy: 80)),                      // a hidden app's window, here
            entry(7, 12, CGRect(x: 900, y: 100, width: 200, height: 200)),   // straddles both displays
        ]
        let targets = AllSpacesWindows.clearTargets(entries, exempt: [20], hidden: [40], on: main)
        XCTAssertEqual(targets[10]?.map(\.number), [1], "the window on another desktop is left")
        XCTAssertNil(targets[11], "windows of the other display are left, showing or not")
        XCTAssertNil(targets[20], "MacHUD's siblings are exempt on a screen too")
        XCTAssertNil(targets[40])
        XCTAssertEqual(targets[12]?.map(\.number), [7], "a window that reaches this screen is on it, as for apply")
        XCTAssertEqual(Set(targets.keys), [10, 12])
        let other = AllSpacesWindows.clearTargets(entries, exempt: [20], hidden: [40], on: side)
        XCTAssertEqual(other[11]?.map(\.number), [3])
        XCTAssertEqual(other[12]?.map(\.number), [7])
        XCTAssertNil(other[10])
    }

    func testTheScopeIsEveryDesktopOnlyWithTheSettingOnAndNoScreenNamed() {
        let scope = LoadoutEngine.clearScope
        XCTAssertEqual(scope(true, nil, main), .everyDesktop)
        XCTAssertEqual(scope(false, nil, main), .screen(main), "off: the screen under the pointer")
        XCTAssertEqual(scope(false, side, main), .screen(side), "a named screen wins")
        XCTAssertEqual(scope(true, side, main), .screen(side), "named, it is one screen with the setting on too")
        XCTAssertEqual(scope(false, nil, nil), .noScreen, "off and no screen to name: nothing is cleared")
        XCTAssertEqual(scope(true, nil, nil), .everyDesktop)
    }
}

/// The `clear` verb's answers that come before any window is read.
@MainActor
final class ClearVerbTests: XCTestCase {
    func testClearWithAScreenThatIsNotAttachedSaysSoAndClearsNothing() throws {
        for multiDesktop: Bool? in [nil, true] {
            let engine = LoadoutEngine(store: try OneScreenFixture.store(multiDesktop: multiDesktop), panels: PanelRegistry())
            let reply = engine.handleClear(["screen": "No Such Display"])
            XCTAssertEqual(reply["ok"] as? Bool, false, "setting \(String(describing: multiDesktop))")
            XCTAssertEqual(reply["error"] as? String, "no screen matching No Such Display")
            XCTAssertNil(reply["cleared"])
        }
    }
}
