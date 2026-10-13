import XCTest
@testable import MacHUDCore

/// The HUD summon's state machine, on a fake dock, widgets and watch: what holding the wheel's
/// hotkey brings up, what each way of letting go does with it, and what ends a summon left up.
@MainActor
final class HUDSummonTests: XCTestCase {
    final class Dock: HUDSummonDock {
        var summoned = false
        var point: CGPoint?
        var hoverPaused = false
        var summonKeepFrames: [CGRect] = []
        var log: [String] = []
        func setSummoned(_ on: Bool, at point: CGPoint?) {
            summoned = on
            self.point = point
            log.append(on ? "dock up" : "dock back")
        }
    }

    final class Widgets: HUDSummonWidgets {
        var servesWidgets = true
        var revealed = false
        var revealChanges = 0
        var summonKeepFrames: [CGRect] = []
        var log: [String] = []
        func setRevealed(_ on: Bool) {
            guard on != revealed else { return }
            revealed = on
            revealChanges += 1
            log.append(on ? "reveal" : "lower")
        }
    }

    final class Watch: HUDSummonWatch {
        var escape: (@MainActor () -> Void)?
        var click: (@MainActor (CGPoint) -> Void)?
        var watching: Bool { escape != nil }
        func start(onEscape: @escaping @MainActor () -> Void, onClick: @escaping @MainActor (CGPoint) -> Void) {
            escape = onEscape
            click = onClick
        }
        func stop() { escape = nil; click = nil }
    }

    private var dock: Dock!
    private var widgets: Widgets!
    private var watch: Watch!
    private var summon: HUDSummon!
    /// The puttings back waiting for the action they follow.
    private var later: [@MainActor () -> Void] = []
    private var active: [Bool] = []

    override func setUp() {
        dock = Dock()
        widgets = Widgets()
        watch = Watch()
        summon = HUDSummon(watch: watch)
        summon.dock = dock
        summon.widgets = widgets
        summon.afterAction = { [unowned self] in self.later.append($0) }
        summon.onActiveChange = { [unowned self] in self.active.append($0) }
    }

    private func runLater() {
        let due = later
        later = []
        for body in due { body() }
    }

    private let centre = CGPoint(x: 700, y: 450)

    func testHoldingBringsUpTheDockOnTheWheelsScreenAndRaisesTheWidgets() {
        summon.wheelOpened(at: centre)
        XCTAssertEqual(summon.phase, .wheel)
        XCTAssertTrue(dock.summoned)
        XCTAssertEqual(dock.point, centre, "on the wheel's display")
        XCTAssertTrue(dock.hoverPaused, "no panel slides out over the wheel")
        XCTAssertTrue(widgets.revealed)
        XCTAssertFalse(watch.watching, "the wheel itself takes Esc while it is open")
        XCTAssertEqual(active, [true])
        XCTAssertFalse(summon.userRevealed(widgets.revealed), "the Widgets petal still offers Reveal")
        XCTAssertEqual(summon.json["raisedWidgets"] as? Bool, true)
    }

    func testLettingGoOnAnActionDoesItThenPutsTheDockAndWidgetsBack() {
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.apply(loadout: "Work", clear: false))
        XCTAssertTrue(dock.summoned, "not before the action has started")
        XCTAssertTrue(widgets.revealed)
        XCTAssertFalse(dock.hoverPaused)
        runLater()
        XCTAssertFalse(dock.summoned)
        XCTAssertFalse(widgets.revealed)
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(watch.watching)
        XCTAssertEqual(active, [true, false])
        XCTAssertEqual(dock.log, ["dock up", "dock back"])
        XCTAssertEqual(widgets.log, ["reveal", "lower"])
    }

    func testLettingGoOnNothingLeavesThemUpUntilEscape() {
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        runLater()
        XCTAssertEqual(summon.phase, .held)
        XCTAssertTrue(dock.summoned)
        XCTAssertTrue(widgets.revealed)
        XCTAssertFalse(dock.hoverPaused, "the dock works again")
        XCTAssertTrue(watch.watching)
        watch.escape?()
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(dock.summoned)
        XCTAssertFalse(widgets.revealed)
        XCTAssertFalse(watch.watching)
    }

    func testAClickOnTheDockItsPanelsOrAWidgetKeepsItAClickAwayEndsIt() {
        dock.summonKeepFrames = [CGRect(x: 0, y: 0, width: 400, height: 64), CGRect(x: 100, y: 70, width: 300, height: 400)]
        widgets.summonKeepFrames = [CGRect(x: 1200, y: 600, width: 170, height: 170)]
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        for kept in [CGPoint(x: 20, y: 30), CGPoint(x: 200, y: 300), CGPoint(x: 1250, y: 650)] {
            watch.click?(kept)
            XCTAssertEqual(summon.phase, .held, "\(kept)")
        }
        watch.click?(CGPoint(x: 900, y: 500))
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(dock.summoned)
        XCTAssertFalse(widgets.revealed)
    }

    func testTheHotkeyAgainHoldsTheSameSummonOrATapEndsIt() {
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        // Held again: the wheel opens over the same summon, nothing comes down in between.
        summon.wheelOpened(at: CGPoint(x: 2400, y: 500))
        XCTAssertEqual(summon.phase, .wheel)
        XCTAssertFalse(watch.watching)
        XCTAssertEqual(dock.point, CGPoint(x: 2400, y: 500), "on the new wheel's display")
        XCTAssertEqual(widgets.log, ["reveal"])
        XCTAssertEqual(active, [true])
        XCTAssertFalse(summon.userRevealed(true), "still the summon's raising")
        summon.wheelClosed(.park(restore: false))
        runLater()
        XCTAssertEqual(widgets.log, ["reveal", "lower"], "back to how they were before the first hold")
        XCTAssertFalse(dock.summoned)

        // Left up, then a tap (the app dismisses before the search bar opens).
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        summon.dismiss()
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(dock.summoned)
        XCTAssertFalse(widgets.revealed)
    }

    func testWidgetsRevealedBeforeTheSummonStayRevealed() {
        widgets.setRevealed(true)
        widgets.log = []
        summon.wheelOpened(at: centre)
        XCTAssertTrue(summon.userRevealed(widgets.revealed), "the petal offers Lower")
        XCTAssertEqual(summon.json["raisedWidgets"] as? Bool, false)
        summon.wheelClosed(.capture(allScreens: false))
        runLater()
        XCTAssertTrue(widgets.revealed)
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        watch.escape?()
        XCTAssertTrue(widgets.revealed)
        XCTAssertEqual(widgets.log, [], "never touched")
    }

    func testWidgetsRevealOrLowerSetsThemAndEditKeepsThemUpUntilDone() {
        // Reveal: they stay revealed.
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.widgets(edit: false, on: true))
        runLater()
        XCTAssertTrue(widgets.revealed)
        XCTAssertFalse(dock.summoned)

        // Lower, from widgets the user had revealed: the action lowers them.
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.widgets(edit: false, on: false))
        widgets.setRevealed(false)   // the action, on the next turn
        runLater()
        XCTAssertFalse(widgets.revealed)

        // Edit: turned on before the putting back, which lowers the summon's raising; edit mode
        // keeps the widgets up itself until Done.
        widgets.log = []
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.widgets(edit: true, on: true))
        var order: [String] = []
        later.insert({ order.append("edit on") }, at: 0)   // the action was scheduled first
        later.append { order.append(self.widgets.revealed ? "still revealed" : "lowered") }
        runLater()
        XCTAssertEqual(order, ["edit on", "lowered"])
        XCTAssertEqual(widgets.log, ["reveal", "lower"])
    }

    func testSomeoneElseChangingTheWidgetsWins() {
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        // ⌃⌥W twice while the summon is up: the user revealed them on purpose.
        widgets.setRevealed(false)
        widgets.setRevealed(true)
        XCTAssertTrue(summon.userRevealed(widgets.revealed))
        watch.escape?()
        XCTAssertTrue(widgets.revealed)
    }

    func testNoWidgetsServedOnlyTheDock() {
        widgets.servesWidgets = false
        summon.wheelOpened(at: centre)
        XCTAssertFalse(widgets.revealed)
        XCTAssertTrue(dock.summoned)
        summon.wheelClosed(.cancelled)
        summon.dismiss()
        XCTAssertEqual(widgets.log, [])
    }

    func testAPuttingBackDoesNotEndTheNextSummon() {
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.preview(loadout: nil))
        summon.dismiss()           // `radial dismiss` before the action's turn
        summon.wheelOpened(at: centre)
        runLater()                 // the first one's putting back
        XCTAssertEqual(summon.phase, .wheel)
        XCTAssertTrue(dock.summoned)
        XCTAssertTrue(widgets.revealed)
    }

    func testAClosedWheelWithoutASummonDoesNothing() {
        summon.wheelClosed(.cancelled)
        summon.wheelClosed(.apply(loadout: "Work", clear: false))
        runLater()
        summon.clicked(at: .zero)
        summon.dismiss()
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertEqual(dock.log, [])
        XCTAssertEqual(widgets.log, [])
        XCTAssertEqual(active, [])
    }
}
