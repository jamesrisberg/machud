import AppKit
import XCTest
@testable import MacHUDCore

/// What the wheel does as it opens, before the pointer moves: it opens in the middle of the
/// screen the pointer is on and moves the pointer to its centre, so a gesture means the same
/// direction from the centre every time; nothing is lit and releasing cancels. The wheel is
/// prepared without a window or any event monitor, and the pointer's move is only recorded.
@MainActor
final class RadialOpeningTests: XCTestCase {
    /// A 13-inch display at Larger Text (its menu bar above), and a 1440 by 900 one with a Dock,
    /// to the right of it (the primary display, whose height turns screen points into display ones).
    private static let displays = [
        RadialMenu.Display(frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                           visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 616), primaryHeight: 640),
        RadialMenu.Display(frame: CGRect(x: 1024, y: -100, width: 1440, height: 900),
                           visibleFrame: CGRect(x: 1024, y: -30, width: 1440, height: 805), primaryHeight: 640),
    ]

    private func menu(warps: @escaping (CGPoint) -> Void = { _ in }) -> RadialMenu {
        let menu = RadialMenu()
        menu.warpPointer = warps
        return menu
    }

    /// Seven columns by five rows over `frame`, its corners and edges included.
    private static func grid(_ frame: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        for column in 0...6 {
            for row in 0...4 {
                let x: CGFloat = frame.minX + 1 + (frame.width - 2) * CGFloat(column) / 6
                let y: CGFloat = frame.minY + 1 + (frame.height - 2) * CGFloat(row) / 4
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    /// Wherever the pointer is when the wheel opens, the wheel opens in the middle of that screen,
    /// at the same place however many loadouts there are, and the pointer is moved to its
    /// centre, once (left alone only where it already was there). Nothing is lit and releasing
    /// cancels, and a pointer event that did not move changes nothing either.
    func testItOpensInTheMiddleOfTheScreenAndMovesThePointerThere() {
        for display in Self.displays {
            let middle = RadialMenu.place(tree: RadialLayoutTests.tree(0, RadialLayoutTests.long), visibleFrame: display.visibleFrame).center
            XCTAssertTrue(display.visibleFrame.contains(middle))
            for count in [3, 10, 14] {
                let tree = RadialLayoutTests.tree(count, RadialLayoutTests.long)
                var warps: [CGPoint] = []
                let menu = menu(warps: { warps.append($0) })
                for pointer in Self.grid(display.frame) + [middle] {
                    warps = []
                    menu.prepare(tree: tree, at: pointer, on: display, movesPointer: true)
                    let what = "\(count) loadouts at \(pointer) on \(display.frame)"
                    XCTAssertEqual(menu.center, middle, "\(what): the wheel opens in the middle of the screen")
                    XCTAssertEqual(menu.selection, [], what)
                    XCTAssertEqual(menu.releaseOutcome, .cancelled, what)
                    menu.pointerMoved(to: pointer, delta: .zero)
                    XCTAssertEqual(menu.selection, [], "\(what), after an event that did not move")
                    // A pen or a remotely driven pointer reports where it really is, away from
                    // the centre the pointer was moved to, with a delta: still nothing.
                    menu.pointerMoved(to: CGPoint(x: pointer.x + 2, y: pointer.y - 1), delta: CGVector(dx: 2, dy: 1))
                    XCTAssertEqual(menu.selection, [], "\(what), after a first event that moved")
                    menu.pointerMoved(to: CGPoint(x: pointer.x + 6, y: pointer.y + 1), delta: CGVector(dx: 4, dy: -2))
                    XCTAssertEqual(menu.selection, [], "\(what), within a few points of the first event")
                    XCTAssertEqual(menu.releaseOutcome, .cancelled, what)
                    if hypot(menu.center.x - pointer.x, menu.center.y - pointer.y) > 0.5 {
                        XCTAssertEqual(warps, [ScreenCoords.axPoint(fromCocoa: menu.center, primaryHeight: display.primaryHeight)], what)
                    } else {
                        XCTAssertEqual(warps, [], what)
                    }
                }
            }
        }
    }

    /// The park petal's targets are read again as it is reached without waiting for the
    /// answer: the hints keep what they said until the answer comes, which is used only while
    /// the park petal is still on the path in the same opening of the wheel.
    func testTheParkPetalRereadsItsTargetsWithoutWaiting() {
        let menu = menu()
        var asked: [(RadialMenu.ParkTargets) -> Void] = []
        menu.readParkTargets = { answer in asked.append(answer) }
        let display = Self.displays[1]
        let tree = RadialLayoutTests.tree(3, RadialLayoutTests.short, park: .init(focused: "Safari · Docs"))
        let at = CGPoint(x: display.frame.midX, y: display.frame.midY)
        menu.prepare(tree: tree, at: at, on: display, movesPointer: true)
        func hint() -> String { RadialMenu.hint(for: ["park", "park"], in: menu.tree) }
        XCTAssertTrue(asked.isEmpty)
        menu.select(path: ["park"])
        XCTAssertEqual(asked.count, 1, "asked as it was reached")
        XCTAssertEqual(hint(), "Park Safari · Docs", "unchanged until the answer")
        menu.select(path: ["park", "restore"])
        XCTAssertEqual(asked.count, 1, "still on the path: not asked again")
        asked[0](.init(focused: "Notes · Groceries"))
        XCTAssertEqual(hint(), "Park Notes · Groceries", "the answer, while the park petal is on the path")

        menu.select(path: ["loadouts"])
        menu.select(path: ["park"])
        XCTAssertEqual(asked.count, 2)
        menu.select(path: ["capture"])
        asked[1](.init(focused: "Terminal"))
        menu.select(path: ["park"])
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(hint(), "Park Notes · Groceries", "an answer that came after the park petal was left is not used")

        menu.prepare(tree: tree, at: at, on: display, movesPointer: true)
        menu.select(path: ["park"])
        asked[2](.init(focused: "Mail · Inbox"))
        XCTAssertEqual(hint(), "Park Safari · Docs", "an answer from an earlier opening is not used")
    }

    /// Park left and reached again while a read is still out: that read's answer is older
    /// than the highlight, so it is not used, and the wheel asks again as it lands.
    func testAReturnAsksAgainRatherThanUseAnOlderAnswer() {
        let menu = menu()
        var asked: [(RadialMenu.ParkTargets) -> Void] = []
        menu.readParkTargets = { answer in asked.append(answer) }
        let display = Self.displays[1]
        let tree = RadialLayoutTests.tree(3, RadialLayoutTests.short, park: .init(focused: "Safari · Docs"))
        menu.prepare(tree: tree, at: CGPoint(x: display.frame.midX, y: display.frame.midY), on: display, movesPointer: true)
        func hint() -> String { RadialMenu.hint(for: ["park", "park"], in: menu.tree) }
        menu.select(path: ["park"])
        menu.select(path: ["loadouts"])
        menu.select(path: ["park"])
        XCTAssertEqual(asked.count, 1, "one read out at a time")
        asked[0](.init(focused: "Notes · Groceries"))
        XCTAssertEqual(hint(), "Park Safari · Docs", "the older answer is not used")
        XCTAssertEqual(asked.count, 2, "asked again as it landed")
        asked[1](.init(focused: "Terminal"))
        XCTAssertEqual(hint(), "Park Terminal")

        // Left again before the older answer lands: it is not used, and nothing is asked until
        // Park is reached again.
        menu.select(path: ["loadouts"])
        menu.select(path: ["park"])
        XCTAssertEqual(asked.count, 3)
        menu.select(path: ["loadouts"])
        menu.select(path: ["park"])
        menu.select(path: ["loadouts"])
        asked[2](.init(focused: "Mail · Inbox"))
        XCTAssertEqual(asked.count, 3)
        menu.select(path: ["park"])
        XCTAssertEqual(asked.count, 4)
        XCTAssertEqual(hint(), "Park Terminal")
    }

    /// A wheel opened again with the same words in the same room reuses its layout; any other
    /// words (a widgets action that reads Lower now) or room lay it out anew.
    func testALayoutIsReusedOnlyForTheSameWordsAndRoom() {
        let menu = menu()
        let display = Self.displays[1]
        let at = CGPoint(x: display.frame.midX, y: display.frame.midY)
        func reveal() -> [String]? { menu.layout.word(["widgets", "reveal"])?.fit.lines }
        menu.prepare(tree: RadialLayoutTests.tree(6, RadialLayoutTests.short), at: at, on: display, movesPointer: true)
        XCTAssertEqual(reveal(), ["Reveal"])
        let first = menu.layout
        menu.prepare(tree: RadialLayoutTests.tree(6, RadialLayoutTests.short), at: at, on: display, movesPointer: true)
        XCTAssertEqual(menu.layout, first)
        menu.prepare(tree: RadialLayoutTests.tree(6, RadialLayoutTests.short, widgets: .init(revealed: true)), at: at, on: display,
                     movesPointer: true)
        XCTAssertEqual(reveal(), ["Lower"])
        menu.prepare(tree: RadialLayoutTests.tree(14, RadialLayoutTests.long), at: CGPoint(x: 100, y: 100), on: Self.displays[0],
                     movesPointer: true)
        XCTAssertLessThan(menu.layout.scale, 1, "the small screen's room")
    }

    /// Screen points (y up from the primary display's bottom) become display points (y down
    /// from its top), which is what moving the pointer takes.
    func testThePointerIsMovedInDisplayPoints() {
        XCTAssertEqual(ScreenCoords.axPoint(fromCocoa: CGPoint(x: 300, y: 40), primaryHeight: 640), CGPoint(x: 300, y: 600))
        XCTAssertEqual(ScreenCoords.axPoint(fromCocoa: CGPoint(x: 1500, y: -60), primaryHeight: 640), CGPoint(x: 1500, y: 700))
    }

    /// A wheel opened by a script opens in the middle of the screen too, but does not move the
    /// user's pointer; nothing is lit there until the pointer moves.
    func testAWheelOpenedByAScriptLeavesThePointerAlone() {
        var warps: [CGPoint] = []
        let menu = menu(warps: { warps.append($0) })
        let display = Self.displays[0]
        menu.prepare(tree: RadialLayoutTests.tree(8, RadialLayoutTests.short), at: CGPoint(x: 5, y: 5), on: display,
                     movesPointer: false)
        XCTAssertEqual(warps, [])
        XCTAssertEqual(menu.center, RadialMenu.place(tree: RadialLayoutTests.tree(8, RadialLayoutTests.short),
                                                     visibleFrame: display.visibleFrame).center)
        XCTAssertEqual(menu.selection, [])
    }

    /// The pointer moved by `offset` from the centre, as one event from the last place.
    private func move(_ menu: RadialMenu, to offset: CGPoint) {
        menu.pointerMoved(to: CGPoint(x: menu.center.x + offset.x, y: menu.center.y + offset.y), delta: CGVector(dx: 3, dy: 0))
    }

    /// Once the pointer has really moved, the wheel follows its path: onto Apply Loadout (the
    /// loadouts unfold), onto a loadout (its actions unfold, nothing is previewed), out to Apply;
    /// releasing there applies, releasing on a petal with children cancels.
    func testOnceThePointerMovesTheWheelFollowsItsPath() throws {
        let menu = menu()
        let display = Self.displays[1]
        let tree = RadialLayoutTests.tree(3, RadialLayoutTests.short)
        menu.prepare(tree: tree, at: CGPoint(x: display.frame.midX, y: display.frame.midY), on: display, movesPointer: true)
        var outcomes: [RadialMenu.Outcome] = []
        menu.onCommit = { outcomes.append($0) }
        move(menu, to: CGPoint(x: 1, y: 0))
        XCTAssertEqual(menu.selection, [])
        let top = try XCTUnwrap(menu.layout.word(["loadouts"]))
        move(menu, to: CGPoint(x: top.frame.midX, y: top.frame.midY))
        XCTAssertEqual(menu.selection, ["loadouts"])
        XCTAssertEqual(menu.releaseOutcome, .cancelled, "a petal with children")
        let mail = try XCTUnwrap(menu.layout.word(["loadouts", "Mail"]))
        move(menu, to: CGPoint(x: mail.frame.midX, y: mail.frame.midY))
        XCTAssertEqual(menu.selection, ["loadouts", "Mail"])
        XCTAssertEqual(menu.releaseOutcome, .cancelled, "hovering a loadout does not preview it")
        XCTAssertTrue(outcomes.isEmpty)
        let apply = try XCTUnwrap(menu.layout.word(["loadouts", "Mail", "apply"]))
        move(menu, to: CGPoint(x: apply.frame.midX, y: apply.frame.midY))
        XCTAssertEqual(menu.selection, ["loadouts", "Mail", "apply"])
        XCTAssertEqual(menu.releaseOutcome, .apply(loadout: "Mail", clear: false))
        move(menu, to: CGPoint(x: 0, y: 2))
        XCTAssertEqual(menu.selection, [], "back in the centre")
    }

    /// With Apply Loadout open, the pointer going straight from its word to any loadout's word,
    /// on any row, stays among the loadouts and lands on it; back in the centre nothing is lit at
    /// once, and moving out from there opens the top petal that way.
    func testAStraightMoveFromApplyLoadoutToAnyLoadoutStaysAmongTheLoadouts() throws {
        for names in [RadialLayoutTests.short, RadialLayoutTests.long] {
            let tree = RadialLayoutTests.tree(14, names)
            let menu = menu()
            for loadout in tree[0].children {
                let display = Self.displays[1]
                menu.prepare(tree: tree, at: CGPoint(x: display.frame.midX, y: display.frame.midY), on: display, movesPointer: true)
                let from = try XCTUnwrap(menu.layout.word(["loadouts"])).frame
                let to = try XCTUnwrap(menu.layout.word(["loadouts", loadout.id])).frame
                let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
                move(menu, to: CGPoint(x: 1, y: 0))
                move(menu, to: start)
                XCTAssertEqual(menu.selection, ["loadouts"])
                let steps = Int(hypot(end.x - start.x, end.y - start.y) / 3)
                for k in 1...steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    move(menu, to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                    if menu.selection.first != "loadouts" {
                        XCTFail("toward \(loadout.id) the wheel shows \(menu.selection)")
                        break
                    }
                }
                XCTAssertEqual(menu.selection, ["loadouts", loadout.id])
                move(menu, to: CGPoint(x: 0, y: 4))
                XCTAssertEqual(menu.selection, [], "the centre resets at once")
                let park = try XCTUnwrap(menu.layout.word(["park"])).frame
                move(menu, to: CGPoint(x: park.midX, y: park.midY))
                XCTAssertEqual(menu.selection, ["park"])
            }
        }
    }

    /// Where the pointer's first report after the wheel opens is far from the centre (a
    /// hovering pen, a remotely driven pointer: moving the pointer did not stick), nothing
    /// lights there; once the pointer has gone on a few points from that first report, the
    /// wheel lights what is under it.
    func testAFirstReportAwayFromTheCentreLightsNothingUntilThePointerGoesOn() throws {
        let menu = menu()
        let display = Self.displays[1]
        menu.prepare(tree: RadialLayoutTests.tree(6, RadialLayoutTests.short), at: CGPoint(x: display.frame.minX + 3, y: display.frame.minY + 3),
                     on: display, movesPointer: true)
        let capture = try XCTUnwrap(menu.layout.word(["capture"]))
        let pen = CGPoint(x: menu.center.x + capture.frame.midX, y: menu.center.y + capture.frame.midY)
        menu.pointerMoved(to: pen, delta: CGVector(dx: 140, dy: -90))
        XCTAssertEqual(menu.selection, [], "the first report, far from the centre")
        XCTAssertEqual(menu.releaseOutcome, .cancelled)
        menu.pointerMoved(to: CGPoint(x: pen.x + 3, y: pen.y), delta: CGVector(dx: 3, dy: 0))
        XCTAssertEqual(menu.selection, [], "a few points on")
        menu.pointerMoved(to: CGPoint(x: pen.x + 6, y: pen.y), delta: CGVector(dx: 3, dy: 0))
        XCTAssertEqual(menu.selection, ["capture"], "past the threshold it lights what is under the pointer")
    }

    /// The keyboard works with no pointer movement: a digit picks a petal among those showing
    /// at the open branch, and P previews the loadout on the path.
    func testTheKeyboardWorksWithoutMovingThePointer() {
        let menu = menu()
        let tree = RadialLayoutTests.tree(3, RadialLayoutTests.short)
        menu.prepare(tree: tree, at: CGPoint(x: 1000, y: 30), on: Self.displays[0], movesPointer: true)
        func press(_ key: String) { XCTAssertTrue(menu.handleKeyCode(HotKeyCenter.keyCode(for: key)!), key) }
        press("1")
        XCTAssertEqual(menu.selection, ["loadouts"])
        press("3")
        XCTAssertEqual(menu.selection, ["loadouts", "Focus"])
        press("2")
        XCTAssertEqual(menu.selection, ["loadouts", "Focus", "apply"])
        press("3")
        XCTAssertEqual(menu.selection, ["loadouts", "Focus", "clear"], "an action's siblings")
        press("9")
        XCTAssertEqual(menu.selection, ["loadouts", "Focus", "clear"], "a digit past the petals is swallowed")
        // The pointer moving inside the dead zone leaves the keyboard's choice.
        move(menu, to: CGPoint(x: 3, y: 0))
        move(menu, to: CGPoint(x: 12, y: 0))
        XCTAssertEqual(menu.selection, ["loadouts", "Focus", "clear"])
        var outcomes: [RadialMenu.Outcome] = []
        menu.onCommit = { outcomes.append($0) }
        press("p")
        XCTAssertEqual(outcomes, [.preview(loadout: "Focus")])
    }

    /// P with no loadout on the path previews the active loadout (nil); the socket's `select`
    /// takes a path and refuses one the tree does not have.
    func testPWithoutALoadoutAndSelectingByPath() {
        let menu = menu()
        menu.prepare(tree: RadialLayoutTests.tree(3, RadialLayoutTests.short), at: CGPoint(x: 500, y: 300), on: Self.displays[0],
                     movesPointer: true)
        XCTAssertTrue(menu.select(path: ["capture", "draw"]))
        XCTAssertEqual(menu.releaseOutcome, .drawLayout)
        XCTAssertFalse(menu.select(path: ["capture", "nope"]))
        XCTAssertEqual(menu.selection, ["capture", "draw"])
        var outcomes: [RadialMenu.Outcome] = []
        menu.onCommit = { outcomes.append($0) }
        XCTAssertTrue(menu.handleKeyCode(HotKeyCenter.keyCode(for: "p")!))
        XCTAssertEqual(outcomes, [.preview(loadout: nil)])
        let json = menu.json
        XCTAssertEqual((json["selection"] as? [String: Any])?["path"] as? String, "capture/draw")
    }
}
