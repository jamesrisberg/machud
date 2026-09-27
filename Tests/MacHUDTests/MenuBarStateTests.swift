import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

// MARK: - State machine

final class MenuBarStateTests: XCTestCase {
    private let hover = MenuBarState.hoverDelay
    private let leave = MenuBarState.leaveDelay

    func testTimingsMatchTheParkingOrb() {
        XCTAssertEqual(hover, 0.15)
        XCTAssertEqual(leave, 0.6)
    }

    func testCollapseAndExpandReportOnlyRealChanges() {
        var s = MenuBarState()
        XCTAssertTrue(s.itemsVisible)
        XCTAssertNil(s.expand(now: 0))
        XCTAssertEqual(s.collapse(now: 1), .hide)
        XCTAssertNil(s.collapse(now: 2))
        XCTAssertFalse(s.itemsVisible)
        XCTAssertEqual(s.expand(now: 3), .show)
        XCTAssertEqual(s.mode, .expanded)
    }

    func testHoverOnExpanderPeeksAfterDelayAndLeavingCollapses() {
        var s = MenuBarState(mode: .collapsed)
        XCTAssertNil(s.update(onExpander: true, inBar: true, now: 10))
        XCTAssertNil(s.update(onExpander: true, inBar: true, now: 10.1), "not yet 150 ms")
        XCTAssertEqual(s.update(onExpander: true, inBar: true, now: 10.16), .show)
        XCTAssertEqual(s.mode, .peeking)
        // Moving along the menu bar to a revealed item keeps the peek.
        XCTAssertNil(s.update(onExpander: false, inBar: true, now: 12))
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 13))
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 13.5))
        XCTAssertEqual(s.update(onExpander: false, inBar: false, now: 13.61), .hide)
        XCTAssertEqual(s.mode, .collapsed)
    }

    func testBriefHoverDoesNotPeekAndReturningCancelsLeave() {
        var s = MenuBarState(mode: .collapsed)
        _ = s.update(onExpander: true, inBar: true, now: 0)
        _ = s.update(onExpander: false, inBar: true, now: 0.1)
        XCTAssertNil(s.update(onExpander: true, inBar: true, now: 0.2), "arming restarts")
        XCTAssertNil(s.update(onExpander: true, inBar: true, now: 0.3))
        XCTAssertEqual(s.update(onExpander: true, inBar: true, now: 0.36), .show)
        _ = s.update(onExpander: false, inBar: false, now: 1)
        _ = s.update(onExpander: false, inBar: true, now: 1.5)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 1.7), "leave timer restarted")
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 2.2))
        XCTAssertEqual(s.update(onExpander: false, inBar: false, now: 2.31), .hide)
    }

    func testOpenMenuHoldsAPeekOpen() {
        var s = MenuBarState(mode: .collapsed)
        XCTAssertEqual(s.peek(now: 0), .show)
        s.setMenuOpen(true, now: 0.1)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 0.2))
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 5), "held while the menu is open")
        s.setMenuOpen(false, now: 5)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 5.1))
        XCTAssertEqual(s.update(onExpander: false, inBar: false, now: 5.75), .hide)
    }

    func testSocketPeekHoldsForItsDuration() {
        var s = MenuBarState(mode: .collapsed)
        XCTAssertEqual(s.peek(now: 0, hold: 3), .show)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 1))
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 2.9))
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 3.0))
        XCTAssertEqual(s.update(onExpander: false, inBar: false, now: 3.61), .hide)
    }

    func testPeekIsANoOpWhileExpanded() {
        var s = MenuBarState()
        XCTAssertNil(s.peek(now: 0))
        XCTAssertEqual(s.mode, .expanded)
    }

    func testAutoCollapseAfterIdleSeconds() {
        var s = MenuBarState(autoCollapseSeconds: 10)
        _ = s.expand(now: 100)
        XCTAssertEqual(s.autoCollapseDeadline, 110)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 109.9))
        XCTAssertEqual(s.update(onExpander: false, inBar: false, now: 110), .hide)
    }

    func testAutoCollapseWaitsForTheMouseAndMenus() {
        var s = MenuBarState(autoCollapseSeconds: 5)
        _ = s.expand(now: 0)
        XCTAssertNil(s.update(onExpander: false, inBar: true, now: 4), "in the bar: countdown restarts")
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 8.9))
        s.setMenuOpen(true, now: 8.95)
        XCTAssertNil(s.autoCollapseDeadline)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 30), "menu open")
        s.setMenuOpen(false, now: 30)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 34.9))
        XCTAssertEqual(s.update(onExpander: false, inBar: false, now: 35), .hide)
    }

    func testAutoCollapseOffNeverCollapses() {
        var s = MenuBarState(autoCollapseSeconds: 0)
        _ = s.expand(now: 0)
        XCTAssertNil(s.autoCollapseDeadline)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 10_000))
    }

    func testToggleMakesAPeekStickyAndClickCollapseNeedsTheMouseToLeave() {
        var s = MenuBarState(mode: .collapsed, autoCollapseSeconds: 0)
        _ = s.update(onExpander: true, inBar: true, now: 0)
        XCTAssertEqual(s.update(onExpander: true, inBar: true, now: 0.2), .show)
        XCTAssertNil(s.toggle(now: 0.5, onExpander: true), "peek -> expanded, already visible")
        XCTAssertEqual(s.mode, .expanded)
        XCTAssertNil(s.update(onExpander: false, inBar: false, now: 5), "expanded is sticky")
        XCTAssertEqual(s.toggle(now: 6, onExpander: true), .hide)
        // Still on the expander after the click: no immediate re-peek.
        XCTAssertNil(s.update(onExpander: true, inBar: true, now: 6.1))
        XCTAssertNil(s.update(onExpander: true, inBar: true, now: 7))
        _ = s.update(onExpander: false, inBar: true, now: 7.1)
        _ = s.update(onExpander: true, inBar: true, now: 7.2)
        XCTAssertEqual(s.update(onExpander: true, inBar: true, now: 7.4), .show)
    }

    func testHotkeyToggleFromCollapsedExpands() {
        var s = MenuBarState(mode: .collapsed)
        XCTAssertEqual(s.toggle(now: 0), .show)
        XCTAssertEqual(s.mode, .expanded)
        XCTAssertEqual(s.toggle(now: 1), .hide)
        XCTAssertEqual(s.mode, .collapsed)
    }
}

// MARK: - Config

final class MenuBarConfigTests: XCTestCase {
    func testDefaultsAreOffWithTenSecondsAndControlOptionB() {
        let c = MenuBarConfig()
        XCTAssertFalse(c.isEnabled)
        XCTAssertEqual(c.autoCollapse, 10)
        XCTAssertEqual(c.effectiveHotkey(hotkeys: nil), HotKey(key: "b", modifiers: ["control", "option"]))
        XCTAssertNil(Config.defaults.menuBar)
    }

    func testOldConfigWithoutMenuBarStillDecodes() throws {
        let json = #"{"gap": 4, "layouts": [], "hotkeys": {"dock": {"key": "d", "modifiers": ["control"]}}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertNil(config.menuBar)
        XCTAssertNil(config.hotkeys?.menuBar)
        XCTAssertEqual((config.menuBar ?? MenuBarConfig()).effectiveHotkey(hotkeys: config.hotkeys)?.key, "b")
        // And re-encodes without inventing a menuBar block.
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["menuBar"])
    }

    func testMenuBarBlockRoundTripsAndHotkeyPrecedence() throws {
        let json = #"""
        {"layouts": [], "menuBar": {"enabled": true, "autoCollapseSeconds": 0},
         "hotkeys": {"menuBar": {"key": "h", "modifiers": ["command", "option"]}}}
        """#
        var config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let mb = try XCTUnwrap(config.menuBar)
        XCTAssertTrue(mb.isEnabled)
        XCTAssertEqual(mb.autoCollapse, 0)
        XCTAssertEqual(mb.effectiveHotkey(hotkeys: config.hotkeys)?.key, "h", "hotkeys.menuBar is honoured")
        config.menuBar?.hotkey = HotKey(key: "m", modifiers: ["control"])
        XCTAssertEqual(config.menuBar?.effectiveHotkey(hotkeys: config.hotkeys)?.key, "m", "menuBar.hotkey wins")
        config.menuBar?.hotkey = HotKey(key: "", modifiers: [])
        XCTAssertNil(config.menuBar?.effectiveHotkey(hotkeys: config.hotkeys), "empty key disables it")
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again, config)
    }

    func testNegativeAutoCollapseClampsToOff() {
        XCTAssertEqual(MenuBarConfig(enabled: true, autoCollapseSeconds: -3).autoCollapse, 0)
    }
}
