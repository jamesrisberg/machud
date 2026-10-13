import XCTest
@testable import MacHUDCore

/// The HUD summon's state machine, on a fake dock, widgets and watch: what holding the wheel's
/// hotkey brings up, what each way of letting go does with it, and what ends a summon left up.
@MainActor
final class HUDSummonTests: XCTestCase {
    final class Dock: HUDSummonDock {
        var summoned = false
        var point: CGPoint?
        var hasButtons = true
        var hoverPaused = false
        var summonKeepFrames: [CGRect] = []
        var summonKeepApps: Set<String> = []
        var isMenuOpen = false
        var onSummonChange: (() -> Void)?
        var log: [String] = []
        var showsForSummon: Bool { summoned && hasButtons }
        func setSummoned(_ on: Bool, at point: CGPoint?) {
            summoned = on
            self.point = point
            log.append(on ? "dock up" : "dock back")
        }
        /// What the dock does when it is turned on or off by hand.
        func turnedOnOrOff() {
            guard summoned else { return }
            summoned = false
            log.append("dock set")
            onSummonChange?()
        }
    }

    final class Widgets: HUDSummonWidgets {
        var servesWidgets = true
        var revealed = false
        var revealChanges = 0
        var summonKeepFrames: [CGRect] = []
        var summonKeepApps: Set<String> = []
        var onRevealChange: (() -> Void)?
        var log: [String] = []
        func setRevealed(_ on: Bool) {
            guard on != revealed else { return }
            revealed = on
            revealChanges += 1
            log.append(on ? "reveal" : "lower")
            onRevealChange?()
        }
    }

    final class Watch: HUDSummonWatch {
        var escape: (@MainActor () -> Void)?
        var click: (@MainActor (HUDSummonClick) -> Void)?
        var watching: Bool { escape != nil }
        func start(onEscape: @escaping @MainActor () -> Void, onClick: @escaping @MainActor (HUDSummonClick) -> Void) {
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
        summon.ownApp = "com.jrisberg.machud"
    }

    private func click(_ x: CGFloat, _ y: CGFloat, app: String? = nil, menu: Bool = false) {
        watch.click?(HUDSummonClick(point: CGPoint(x: x, y: y), app: app, inMenu: menu))
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
            click(kept.x, kept.y)
            XCTAssertEqual(summon.phase, .held, "\(kept)")
        }
        click(900, 500)
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
        summon.wheelClosed(.apply(loadout: "Work", clear: false))
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
        summon.clicked(HUDSummonClick(point: .zero))
        summon.loadoutWillApply()
        summon.dismiss()
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertEqual(dock.log, [])
        XCTAssertEqual(widgets.log, [])
        XCTAssertEqual(active, [])
    }

    // MARK: Review fixes

    /// Nothing up (no button on the dock, no widgets served): a cancel ends the summon at once,
    /// so Esc and the clicks are never taken for nothing.
    func testAnEmptySummonEndsOnACancelAndTakesNoEsc() {
        dock.hasButtons = false
        widgets.servesWidgets = false
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(watch.watching)
        XCTAssertEqual(active, [true, false])
        XCTAssertFalse(dock.summoned)

        // The widgets alone are enough to hold it.
        widgets.servesWidgets = true
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        XCTAssertEqual(summon.phase, .held)
        XCTAssertTrue(watch.watching)
    }

    /// The dock turned on or off by hand while the summon is held: with nothing else up the
    /// summon ends (Esc and the clicks go); with widgets it raised it holds, and Esc then lowers
    /// them.
    func testTheDockTurnedOnOrOffEndsAHeldSummonWithNothingElseUp() {
        widgets.servesWidgets = false
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        XCTAssertEqual(summon.phase, .held)
        dock.turnedOnOrOff()
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(watch.watching)
        XCTAssertEqual(active, [true, false])

        widgets.servesWidgets = true
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        dock.turnedOnOrOff()
        XCTAssertEqual(summon.phase, .held, "the widgets it raised are still up")
        watch.escape?()
        XCTAssertFalse(widgets.revealed)
        XCTAssertEqual(summon.phase, .idle)
    }

    /// The widgets lowered by someone else while only they were up: the summon ends.
    func testTheWidgetsLoweredBySomeoneElseEndAHeldSummonWithNoDock() {
        dock.hasButtons = false
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        XCTAssertEqual(summon.phase, .held)
        widgets.setRevealed(false)   // ⌃⌥W
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(watch.watching)
    }

    /// A click in a menu or popover of an app whose panel is open from the dock, in a raised
    /// widget's app, while the dock's own menu is open, or in a MacHUD menu keeps the summon up;
    /// a click in another window of MacHUD's, or another app's, ends it.
    func testClicksInTheOpenPanelsAppsAndInMenusKeepTheSummon() {
        dock.summonKeepApps = ["dev.test.stash"]
        widgets.summonKeepApps = ["dev.test.widgets"]
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        click(900, 500, app: "dev.test.stash", menu: true)
        click(900, 500, app: "dev.test.stash")
        click(900, 500, app: "dev.test.widgets", menu: true)
        click(900, 500, app: "com.jrisberg.machud", menu: true)
        dock.isMenuOpen = true
        click(900, 500, app: "com.apple.Safari")
        dock.isMenuOpen = false
        XCTAssertEqual(summon.phase, .held)
        click(900, 500, app: "com.jrisberg.machud")
        XCTAssertEqual(summon.phase, .idle, "MacHUD's settings window is away")
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        click(900, 500, app: "com.apple.Safari", menu: true)
        XCTAssertEqual(summon.phase, .idle)
    }

    /// The window under a click is looked up only when the keep-frames and the dock's menus
    /// have not already kept the summon up.
    func testTheWindowUnderAClickIsLookedUpOnlyWhenNeeded() {
        dock.summonKeepFrames = [CGRect(x: 0, y: 0, width: 400, height: 64)]
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        var lookups = 0
        let lookUp = { () -> HUDSummonClick.Owner in lookups += 1; return .init(app: "com.apple.Safari") }
        watch.click?(HUDSummonClick(point: CGPoint(x: 20, y: 30), lookUp: lookUp))
        dock.isMenuOpen = true
        watch.click?(HUDSummonClick(point: CGPoint(x: 900, y: 500), lookUp: lookUp))
        dock.isMenuOpen = false
        XCTAssertEqual(lookups, 0, "kept without the window list")
        XCTAssertEqual(summon.phase, .held)
        watch.click?(HUDSummonClick(point: CGPoint(x: 900, y: 500), lookUp: lookUp))
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(summon.phase, .idle)
    }

    /// Capture, Draw layout, Preview and Park see the desktop as it is: the HUD goes back first.
    /// Apply and the Widgets actions start first, the HUD going back on the next turn.
    func testTheHUDGoesBackBeforeACaptureAndAfterAnApply() {
        let first: [RadialMenu.Outcome] = [.capture(allScreens: false), .drawLayout, .preview(loadout: "Work"), .park(restore: false)]
        let after: [RadialMenu.Outcome] = [.apply(loadout: "Work", clear: true), .widgets(edit: true, on: true)]
        for outcome in first + after {
            widgets.setRevealed(false)
            summon.wheelOpened(at: centre)
            var seen: (dock: Bool, widgets: Bool)?
            summon.wheelClosed(outcome) { seen = (self.dock.summoned, self.widgets.revealed) }
            let up = after.contains(outcome)
            XCTAssertEqual(seen?.dock, up, "\(outcome)")
            XCTAssertEqual(seen?.widgets, up, "\(outcome)")
            runLater()
            XCTAssertFalse(dock.summoned, "\(outcome)")
            XCTAssertEqual(summon.phase, .idle, "\(outcome)")
            XCTAssertEqual(HUDSummon.actsFirst(outcome), up)
        }
        // A cancel's action runs too (it logs), the summon held.
        var ran = false
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled) { ran = true }
        XCTAssertTrue(ran)
        // Without a summon under the wheel the action just runs.
        summon.dismiss()
        ran = false
        summon.wheelClosed(.capture(allScreens: false)) { ran = true }
        XCTAssertTrue(ran)
    }

    /// A loadout applied while the summon is held (a per-loadout hotkey, the menu, a script) ends
    /// it first; the wheel's own Apply leaves it to the wheel's ordering.
    func testApplyingALoadoutEndsAHeldSummon() {
        summon.wheelOpened(at: centre)
        summon.loadoutWillApply()
        XCTAssertEqual(summon.phase, .wheel, "the wheel's Apply puts it back after starting")
        summon.wheelClosed(.cancelled)
        summon.loadoutWillApply()
        XCTAssertEqual(summon.phase, .idle)
        XCTAssertFalse(dock.summoned)
        XCTAssertFalse(widgets.revealed)
    }

    /// Any wheel opened over a held summon carries it on: Esc is the wheel's alone (the watch
    /// stops), and an action release ends the summon.
    func testAWheelOpenedOverAHeldSummonCarriesItOn() {
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.cancelled)
        XCTAssertTrue(watch.watching)
        summon.wheelOpened(at: centre)
        XCTAssertFalse(watch.watching, "no second Esc beside the wheel's")
        summon.wheelClosed(.park(restore: true))
        XCTAssertEqual(summon.phase, .idle)
    }

    /// The widgets' own Esc stands aside before the summon raises them, never registering and
    /// dropping in the same turn.
    func testTheSummonClaimsEscBeforeRaisingTheWidgets() {
        var order: [String] = []
        summon.onActiveChange = { order.append($0 ? "claim Esc" : "give Esc back") }
        widgets.onRevealChange = { order.append(self.widgets.revealed ? "raised" : "lowered") }
        summon.wheelOpened(at: centre)
        summon.wheelClosed(.apply(loadout: "Work", clear: false))
        runLater()
        XCTAssertEqual(order, ["claim Esc", "raised", "lowered", "give Esc back"])
    }
}
