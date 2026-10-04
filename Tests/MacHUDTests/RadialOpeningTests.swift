import AppKit
import XCTest
@testable import MacHUDCore

/// What the wheel does as it opens, before the pointer moves: nothing is lit and releasing
/// cancels, wherever the pointer is; where the wheel could not open around the pointer, the
/// pointer is moved to the wheel's centre, so a gesture means the same everywhere. The wheel is
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

    private func menu(warps: @escaping (CGPoint) -> Void = { _ in }, shift: Bool = false) -> RadialMenu {
        let menu = RadialMenu()
        menu.warpPointer = warps
        menu.modifiers = { shift ? [.shift] : [] }
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

    /// Wherever the pointer is when the wheel opens, nothing is lit and releasing cancels,
    /// a modifier change (Shift among them) leaves it so, and a pointer event that did not move
    /// changes nothing either. Where the centre is not at the pointer, the pointer was moved to
    /// the centre, once; where it is, the pointer was left alone.
    func testAtOpenNothingIsLitAndReleasingCancelsWhereverThePointerIs() {
        for display in Self.displays {
            for count in [3, 8, 12] {
                let wedges = RadialLayoutTests.wedges(count, RadialLayoutTests.long)
                var warps: [CGPoint] = []
                let menu = menu(warps: { warps.append($0) }, shift: true)
                for pointer in Self.grid(display.frame) {
                    warps = []
                    menu.prepare(wedges: wedges, at: pointer, on: display, movesPointer: true)
                    let what = "\(count) wedges at \(pointer) on \(display.frame)"
                    XCTAssertEqual(menu.selection, .cancel, what)
                    XCTAssertEqual(menu.releaseOutcome, .cancelled, what)
                    menu.modifiersChanged()
                    XCTAssertEqual(menu.selection, .cancel, "\(what), after a modifier change")
                    menu.pointerMoved(to: pointer, delta: .zero)
                    XCTAssertEqual(menu.selection, .cancel, "\(what), after an event that did not move")
                    // A pen or a remotely driven pointer reports where it really is, away from
                    // the centre the pointer was moved to, with a delta: still nothing.
                    menu.pointerMoved(to: CGPoint(x: pointer.x + 2, y: pointer.y - 1), delta: CGVector(dx: 2, dy: 1))
                    XCTAssertEqual(menu.selection, .cancel, "\(what), after a first event that moved")
                    menu.pointerMoved(to: CGPoint(x: pointer.x + 6, y: pointer.y + 1), delta: CGVector(dx: 4, dy: -2))
                    XCTAssertEqual(menu.selection, .cancel, "\(what), within a few points of the first event")
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

    /// The wheel opens on the screen the pointer is on, a screen's top edge included: a pointer
    /// pinned at the top of a screen (just after using its menu bar) is on that screen, not on
    /// the one above it. Its left edge is in it, its right edge in the next one; a point on no
    /// screen goes to the nearest.
    func testTheWheelOpensOnTheScreenThePointerIsOn() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func on(_ p: CGPoint, _ frames: [CGRect]) -> Int? { RadialMenu.screenIndex(containing: p, frames: frames) }
        // One screen: its top edge and its corners.
        for p in [CGPoint(x: 720, y: 900), CGPoint(x: 0, y: 900), CGPoint(x: 1439, y: 900), CGPoint(x: 0, y: 1), CGPoint(x: 1439, y: 1)] {
            XCTAssertEqual(on(p, [main]), 0, "\(p)")
        }
        // Two side by side, the second taller.
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(on(CGPoint(x: 700, y: 900), [main, right]), 0, "the first's top edge")
        XCTAssertEqual(on(CGPoint(x: 1439, y: 900), [main, right]), 0, "the first's top right corner")
        XCTAssertEqual(on(CGPoint(x: 1440, y: 500), [main, right]), 1, "the second's left edge")
        XCTAssertEqual(on(CGPoint(x: 1440, y: 1080), [main, right]), 1, "the second's top left corner")
        XCTAssertEqual(on(CGPoint(x: 3359, y: 1080), [main, right]), 1, "the second's top right corner")
        // One above the other: the lower one's top edge is the upper one's bottom edge.
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        XCTAssertEqual(on(CGPoint(x: 700, y: 900), [main, above]), 0, "the lower one's top edge")
        XCTAssertEqual(on(CGPoint(x: 700, y: 900), [above, main]), 1, "whichever order the screens come in")
        XCTAssertEqual(on(CGPoint(x: 0, y: 900), [main, above]), 0, "the lower one's top left corner")
        XCTAssertEqual(on(CGPoint(x: 700, y: 901), [main, above]), 1)
        XCTAssertEqual(on(CGPoint(x: 700, y: 1800), [main, above]), 1, "the upper one's top edge")
        XCTAssertEqual(on(CGPoint(x: 1439, y: 1800), [main, above]), 1, "the upper one's top right corner")
        // On no screen: the nearest.
        XCTAssertEqual(on(CGPoint(x: 3500, y: 200), [main, right]), 1)
        XCTAssertEqual(on(CGPoint(x: -20, y: 1700), [main, above]), 1)
        XCTAssertNil(on(.zero, []))
    }

    /// Screen points (y up from the primary display's bottom) become display points (y down
    /// from its top), which is what moving the pointer takes.
    func testThePointerIsMovedInDisplayPoints() {
        XCTAssertEqual(ScreenCoords.axPoint(fromCocoa: CGPoint(x: 300, y: 40), primaryHeight: 640), CGPoint(x: 300, y: 600))
        XCTAssertEqual(ScreenCoords.axPoint(fromCocoa: CGPoint(x: 1500, y: -60), primaryHeight: 640), CGPoint(x: 1500, y: 700))
    }

    /// A wheel opened by a script at a given point does not move the user's pointer; nothing is
    /// lit there either until the pointer moves.
    func testAWheelOpenedElsewhereLeavesThePointerAlone() {
        var warps: [CGPoint] = []
        let menu = menu(warps: { warps.append($0) })
        let display = Self.displays[0]
        menu.prepare(wedges: RadialLayoutTests.wedges(8, RadialLayoutTests.short), at: CGPoint(x: 5, y: 5), on: display,
                     movesPointer: false)
        XCTAssertEqual(warps, [])
        XCTAssertEqual(menu.selection, .cancel)
    }

    /// Once the pointer has really moved, the wheel follows it from the centre.
    func testOnceThePointerMovesTheWheelFollowsIt() {
        let menu = menu()
        let display = Self.displays[1]
        let wedges = RadialLayoutTests.wedges(8, RadialLayoutTests.short)
        menu.prepare(wedges: wedges, at: CGPoint(x: display.frame.midX, y: display.frame.midY), on: display, movesPointer: true)
        let g = menu.geometry
        let band = g.band(.middle, of: 2)
        let r = (band.r0 + band.r1) / 2
        let a = g.centerAngle(of: 2)
        let target = CGPoint(x: menu.center.x + r * CGFloat(sin(a)), y: menu.center.y + r * CGFloat(cos(a)))
        menu.pointerMoved(to: CGPoint(x: menu.center.x + 1, y: menu.center.y), delta: CGVector(dx: 1, dy: 0))
        XCTAssertEqual(menu.selection, .cancel)
        menu.pointerMoved(to: target, delta: CGVector(dx: 3, dy: 0))
        XCTAssertEqual(menu.selection, .wedge(index: 2, ring: .middle))
        XCTAssertEqual(menu.releaseOutcome, RadialMenu.outcome(of: wedges[2].kind, ring: .middle))
    }

    /// Where the pointer's first report after the wheel opens is far from the centre (a
    /// hovering pen, a remotely driven pointer: moving the pointer did not stick), nothing
    /// lights there; once the pointer has gone on a few points from that first report, the
    /// wheel lights what is under it.
    func testAFirstReportAwayFromTheCentreLightsNothingUntilThePointerGoesOn() {
        let menu = menu()
        let display = Self.displays[1]
        let wedges = RadialLayoutTests.wedges(8, RadialLayoutTests.short)
        menu.prepare(wedges: wedges, at: CGPoint(x: display.frame.minX + 3, y: display.frame.minY + 3), on: display, movesPointer: true)
        let g = menu.geometry
        let band = g.band(.outer, of: 1)
        let r = (band.r0 + band.r1) / 2
        let a = g.centerAngle(of: 1)
        let pen = CGPoint(x: menu.center.x + r * CGFloat(sin(a)), y: menu.center.y + r * CGFloat(cos(a)))
        menu.pointerMoved(to: pen, delta: CGVector(dx: 140, dy: -90))
        XCTAssertEqual(menu.selection, .cancel, "the first report, far from the centre")
        XCTAssertEqual(menu.releaseOutcome, .cancelled)
        menu.pointerMoved(to: CGPoint(x: pen.x + 3, y: pen.y + 3), delta: CGVector(dx: 3, dy: 3))
        XCTAssertEqual(menu.selection, .cancel, "a few points on")
        let on = CGPoint(x: pen.x + 6 * CGFloat(sin(a)), y: pen.y + 6 * CGFloat(cos(a)))
        menu.pointerMoved(to: on, delta: CGVector(dx: 3, dy: 3))
        XCTAssertEqual(menu.selection, g.selection(at: CGPoint(x: on.x - menu.center.x, y: on.y - menu.center.y)))
        XCTAssertEqual(menu.selection, .wedge(index: 1, ring: .outer), "past the threshold it lights what is under the pointer")
    }

    /// The keyboard works with no pointer movement: a digit picks a wedge's inner ring, Shift
    /// its last ring, P previews the highlighted loadout.
    func testTheKeyboardWorksWithoutMovingThePointer() {
        let menu = menu(shift: false)
        let display = Self.displays[0]
        let wedges = RadialLayoutTests.wedges(8, RadialLayoutTests.short)
        menu.prepare(wedges: wedges, at: CGPoint(x: 1000, y: 30), on: display, movesPointer: true)
        XCTAssertTrue(menu.handleKeyCode(HotKeyCenter.keyCode(for: "3")!))
        XCTAssertEqual(menu.selection, .wedge(index: 2, ring: .inner))
        menu.modifiers = { [.shift] }
        menu.modifiersChanged()
        XCTAssertEqual(menu.selection, .wedge(index: 2, ring: .outer))
        var outcomes: [RadialMenu.Outcome] = []
        menu.onCommit = { outcomes.append($0) }
        XCTAssertTrue(menu.handleKeyCode(HotKeyCenter.keyCode(for: "p")!))
        guard case .loadout(let name) = wedges[2].kind else { return XCTFail("wedge 2 is a loadout") }
        XCTAssertEqual(outcomes, [.preview(loadout: name)])
    }
}
