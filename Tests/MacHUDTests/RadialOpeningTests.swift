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
                    XCTAssertEqual(menu.releaseOutcome, .cancelled, what)
                    if hypot(menu.center.x - pointer.x, menu.center.y - pointer.y) > 0.5 {
                        XCTAssertEqual(warps, [RadialMenu.displayPoint(menu.center, primaryHeight: display.primaryHeight)], what)
                    } else {
                        XCTAssertEqual(warps, [], what)
                    }
                }
            }
        }
    }

    /// Screen points (y up from the primary display's bottom) become display points (y down
    /// from its top), which is what moving the pointer takes.
    func testThePointerIsMovedInDisplayPoints() {
        XCTAssertEqual(RadialMenu.displayPoint(CGPoint(x: 300, y: 40), primaryHeight: 640), CGPoint(x: 300, y: 600))
        XCTAssertEqual(RadialMenu.displayPoint(CGPoint(x: 1500, y: -60), primaryHeight: 640), CGPoint(x: 1500, y: 700))
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
        menu.pointerMoved(to: target, delta: CGVector(dx: 3, dy: 0))
        XCTAssertEqual(menu.selection, .wedge(index: 2, ring: .middle))
        XCTAssertEqual(menu.releaseOutcome, RadialMenu.outcome(of: wedges[2].kind, ring: .middle))
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
