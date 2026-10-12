import AppKit
import XCTest
@testable import MacHUDCore

final class RadialGeometryTests: XCTestCase {
    private let tau = 2 * Double.pi

    func testAngleIsClockwiseFromStraightUp() {
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: 0, y: 10)), 0, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: 10, y: 0)), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: 0, y: -10)), .pi, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.angle(of: CGPoint(x: -10, y: 0)), 3 * .pi / 2, accuracy: 1e-9)
    }

    func testAngleIsAlwaysInRange() {
        for degrees in stride(from: -720, through: 720, by: 7) {
            let a = Double(degrees) * .pi / 180
            let value = RadialGeometry.angle(of: RadialGeometry.point(100, a))
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, tau)
        }
    }

    func testTheDifferenceOfTwoAnglesIsTheShortWayRound() {
        XCTAssertEqual(RadialGeometry.difference(0.1, tau - 0.1), 0.2, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.difference(tau - 0.1, 0.1), -0.2, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.difference(.pi / 2, 0), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(RadialGeometry.normalized(-.pi / 2), 3 * .pi / 2, accuracy: 1e-9)
    }
}

/// The wheel's tree: what each petal holds, says and does, and where it points.
@MainActor
final class RadialTreeTests: XCTestCase {
    static func tree(_ names: [String], allScreens: Bool = false, park: RadialMenu.ParkTargets = .init(),
                     widgets: RadialMenu.WidgetsState? = .init()) -> [RadialNode] {
        RadialMenu.tree(loadouts: names.map { .init(name: $0) }, offersAllScreens: allScreens, park: park, widgets: widgets)
    }

    private func degrees(_ a: Double) -> Double { (a * 180 / .pi * 1000).rounded() / 1000 }

    /// Four top petals, each always in the same direction: Apply Loadout up, Capture right, Park
    /// down, Widgets left; without widgets the others stay where they were.
    func testTheTopPetalsKeepTheirDirections() {
        let tree = Self.tree(["Code", "Mail"])
        XCTAssertEqual(tree.map(\.id), ["loadouts", "capture", "park", "widgets"])
        XCTAssertEqual(tree.map(\.name), ["Apply Loadout", "Capture", "Park", "Widgets"])
        XCTAssertEqual(tree.map { degrees($0.angle) }, [0, 90, 180, 270])
        let without = Self.tree(["Code", "Mail"], widgets: nil)
        XCTAssertEqual(without.map(\.id), ["loadouts", "capture", "park"])
        XCTAssertEqual(without.map { degrees($0.angle) }, [0, 90, 180])
    }

    /// The loadouts unfold in the top sector, between Widgets and Capture and well clear of their
    /// directions: the first straight up, then alternately clockwise and anticlockwise. A row
    /// holds five (straight up, 30° and 60° each side); the next row, further out, four between
    /// them (15° and 45° each side); then five again, and so on. A loadout added at the end moves
    /// none of the others, so each is always in the same direction on the same row.
    func testLoadoutsStayInTheTopSectorInRowsAndKeepTheirPlaces() {
        let three = Self.tree(["Code", "Mail", "Focus"])[0].children
        XCTAssertEqual(three.map { degrees($0.angle) }, [0, 30, 330])
        XCTAssertEqual(three.map(\.row), [0, 0, 0])
        let fourteen = Self.tree((0..<14).map { "L\($0)" })[0].children
        XCTAssertEqual(fourteen.map(\.row), [0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2])
        XCTAssertEqual(fourteen.map { degrees($0.angle) }, [0, 30, 330, 60, 300, 15, 345, 45, 315, 0, 30, 330, 60, 300])
        for count in 1...20 {
            let names = (0..<count).map { "L\($0)" }
            let loadouts = Self.tree(names)[0].children
            let fewer = Self.tree(Array(names.dropLast()))[0].children
            XCTAssertEqual(Array(loadouts.prefix(fewer.count)).map(\.angle), fewer.map(\.angle), "\(count) loadouts")
            XCTAssertEqual(Array(loadouts.prefix(fewer.count)).map(\.row), fewer.map(\.row), "\(count) loadouts")
            for loadout in loadouts {
                XCTAssertLessThanOrEqual(abs(RadialGeometry.difference(loadout.angle, 0)), RadialMenu.loadoutSector + 1e-9,
                                         "\(count) loadouts: \(loadout.id) stays in the top sector")
            }
            let places = loadouts.map { "\($0.row) \(degrees($0.angle))" }
            XCTAssertEqual(Set(places).count, count, "no two share a row and a direction")
        }
        XCTAssertLessThanOrEqual(RadialMenu.loadoutSector + RadialMenu.loadoutStep / 2, .pi / 2 - .pi / 12 + 1e-9,
                                 "the loadouts' arc stays at least 15° from Capture's and Widgets' directions")
    }

    /// A loadout's actions: Preview, Apply straight on, Clear + Apply; each says what releasing
    /// does with the loadout's name, and does it.
    func testALoadoutUnfoldsPreviewApplyAndClearApply() throws {
        let code = try XCTUnwrap(Self.tree(["Code", "Mail"])[0].children.last)
        XCTAssertEqual(code.id, "Mail")
        XCTAssertEqual(code.kind, .loadout("Mail"))
        XCTAssertEqual(code.children.map(\.id), ["preview", "apply", "clear"])
        XCTAssertEqual(code.children.map(\.name), ["Preview", "Apply", "Clear + Apply"])
        XCTAssertEqual(code.children.map(\.hint), ["Preview Mail", "Apply Mail", "Clear this screen and apply Mail"])
        XCTAssertEqual(code.children.map(\.outcome), [.preview(loadout: "Mail"), .apply(loadout: "Mail", clear: false),
                                                      .apply(loadout: "Mail", clear: true)])
        XCTAssertEqual(code.children[1].angle, code.angle, accuracy: 1e-9, "Apply is straight on")
        XCTAssertEqual(code.hint, "Move out to preview or apply Mail")
    }

    /// Capture unfolds This screen / Draw layout, with All screens between them while
    /// multi-desktop loadouts are on.
    func testCaptureUnfoldsThisScreenAndDrawLayout() throws {
        let one = Self.tree([])[1]
        XCTAssertEqual(one.kind, .capture(offersAllScreens: false))
        XCTAssertEqual(one.children.map(\.name), ["This screen", "Draw layout"])
        XCTAssertEqual(one.children.map(\.outcome), [.capture(allScreens: false), .drawLayout])
        XCTAssertEqual(one.children.map(\.hint), ["Capture this screen as a loadout", "Draw a new layout"])
        let every = Self.tree([], allScreens: true)[1]
        XCTAssertEqual(every.children.map(\.id), ["screen", "all", "draw"])
        XCTAssertEqual(every.children.map(\.name), ["This screen", "All screens", "Draw layout"])
        XCTAssertEqual(every.children[1].outcome, .capture(allScreens: true))
        XCTAssertEqual(every.children[1].hint, "Capture every screen as a loadout")
    }

    /// Park unfolds Park and Restore, whose hints name the window parked or the ones brought back.
    func testParkUnfoldsParkAndRestoreNamingTheWindows() {
        func hints(_ focused: String?, _ parked: [String]) -> [String] {
            Self.tree([], park: .init(focused: focused, parked: parked))[2].children.map(\.hint)
        }
        XCTAssertEqual(Self.tree([])[2].children.map(\.name), ["Park", "Restore"])
        XCTAssertEqual(Self.tree([])[2].children.map(\.outcome), [.park(restore: false), .park(restore: true)])
        XCTAssertEqual(hints(nil, []), ["Focus a window to park", "Focus a window to park"])
        XCTAssertEqual(hints("Safari · Docs", []), ["Park Safari · Docs", "Nothing is parked"])
        XCTAssertEqual(hints("Safari · Docs", ["Mail · Inbox"]), ["Park Safari · Docs", "Restore Mail · Inbox"])
        XCTAssertEqual(hints(nil, ["Mail · Inbox", "Notes", "Terminal"]), ["Focus a window to park", "Restore 3 parked windows"])
    }

    /// Widgets unfolds Reveal (Lower while revealed) and Edit (Done while editing); each does
    /// what it says, whatever the widgets do by the release: the target is the one shown.
    func testWidgetsUnfoldRevealAndEditAndDoWhatTheySay() {
        func widgets(_ state: RadialMenu.WidgetsState) -> RadialNode { Self.tree([], widgets: state)[3] }
        XCTAssertEqual(widgets(.init()).children.map(\.name), ["Reveal", "Edit"])
        XCTAssertEqual(widgets(.init(revealed: true)).children.map(\.name), ["Lower", "Edit"])
        XCTAssertEqual(widgets(.init(editing: true)).children.map(\.name), ["Reveal", "Done"])
        XCTAssertEqual(widgets(.init(editing: true)).children.map(\.hint), ["Reveal widgets", "Finish editing widgets"])
        XCTAssertEqual(widgets(.init(revealed: true)).children.map(\.hint), ["Lower widgets", "Edit widgets"])
        for revealed in [false, true] {
            for editing in [false, true] {
                let actions = widgets(.init(revealed: revealed, editing: editing)).children
                XCTAssertEqual(actions.map(\.id), ["reveal", "edit"], "the ids stay whatever the words")
                XCTAssertEqual(actions[0].outcome, .widgets(edit: false, on: actions[0].name == "Reveal"))
                XCTAssertEqual(actions[1].outcome, .widgets(edit: true, on: actions[1].name == "Edit"))
            }
        }
    }

    /// The line under the wheel says what releasing does, or where to go on from a petal that
    /// has children; an action's hint has no section name, no dash and no ellipsis.
    func testTheHintSaysWhatReleasingDoesOrWhereToGo() {
        let tree = Self.tree(["Code"])
        XCTAssertEqual(RadialMenu.hint(for: [], in: tree), "Release on an action · centre cancels")
        XCTAssertEqual(RadialMenu.hint(for: ["loadouts"], in: tree), "Move out to a loadout")
        XCTAssertEqual(RadialMenu.hint(for: ["loadouts"], in: Self.tree([])), "No loadouts yet: capture one")
        XCTAssertEqual(RadialMenu.hint(for: ["loadouts", "Code"], in: tree), "Move out to preview or apply Code")
        XCTAssertEqual(RadialMenu.hint(for: ["loadouts", "Code", "apply"], in: tree), "Apply Code")
        XCTAssertEqual(RadialMenu.hint(for: ["widgets"], in: tree), "Move out to reveal or edit widgets")
        XCTAssertEqual(RadialMenu.hint(for: ["nowhere"], in: tree), RadialMenu.idleHint)
        func leaves(_ nodes: [RadialNode]) -> [RadialNode] { nodes.flatMap { $0.isLeaf ? [$0] : leaves($0.children) } }
        for leaf in leaves(tree) {
            XCTAssertFalse(leaf.hint.contains("—") || leaf.hint.contains(" · ") || leaf.hint.contains("…"), leaf.hint)
        }
    }

    /// Releasing does the action on the path; on a petal with children, on nothing or off the
    /// tree it cancels.
    func testReleasingCommitsOnlyOnAnAction() {
        let tree = Self.tree(["Code"])
        XCTAssertEqual(RadialMenu.outcome(of: ["loadouts", "Code", "clear"], in: tree), .apply(loadout: "Code", clear: true))
        XCTAssertEqual(RadialMenu.outcome(of: ["capture", "draw"], in: tree), .drawLayout)
        XCTAssertEqual(RadialMenu.outcome(of: ["loadouts", "Code"], in: tree), .cancelled)
        XCTAssertEqual(RadialMenu.outcome(of: ["loadouts"], in: tree), .cancelled)
        XCTAssertEqual(RadialMenu.outcome(of: [], in: tree), .cancelled)
        XCTAssertEqual(RadialMenu.outcome(of: ["loadouts", "Gone", "apply"], in: tree), .cancelled)
    }

    /// A path is written with slashes; a loadout's name may hold one, and the longest id that
    /// matches wins.
    func testAPathIsReadFromItsSlashedForm() {
        let tree = Self.tree(["Code", "dev/web", "dev"])
        XCTAssertEqual(RadialMenu.path("loadouts/Code/apply", in: tree), ["loadouts", "Code", "apply"])
        XCTAssertEqual(RadialMenu.path("/loadouts/dev/web/preview/", in: tree), ["loadouts", "dev/web", "preview"])
        XCTAssertEqual(RadialMenu.path("loadouts/dev/clear", in: tree), ["loadouts", "dev", "clear"])
        XCTAssertEqual(RadialMenu.path("park", in: tree), ["park"])
        XCTAssertNil(RadialMenu.path("loadouts/Nope", in: tree))
        XCTAssertNil(RadialMenu.path("", in: tree))
    }

    /// The digits pick among the petals showing at the open branch: the top petals, a branch's
    /// children once it is reached, an action's siblings while it is highlighted.
    func testTheDigitsPickAtTheOpenBranch() {
        let tree = Self.tree(["Code", "Mail"])
        XCTAssertEqual(RadialMenu.digitLevel(for: [], in: tree).ids, ["loadouts", "capture", "park", "widgets"])
        XCTAssertEqual(RadialMenu.digitLevel(for: ["loadouts"], in: tree).ids, ["Code", "Mail"])
        XCTAssertEqual(RadialMenu.digitLevel(for: ["loadouts", "Mail"], in: tree).branch, ["loadouts", "Mail"])
        XCTAssertEqual(RadialMenu.digitLevel(for: ["loadouts", "Mail", "apply"], in: tree).ids, ["preview", "apply", "clear"])
        XCTAssertEqual(RadialMenu.digitLevel(for: ["loadouts"], in: Self.tree([])).ids, ["loadouts", "capture", "park", "widgets"],
                       "Apply Loadout with no loadouts opens nothing")
    }

    /// The park petal's targets are asked for again as it is reached, and an answer replaces
    /// them, so the hints name the window a release would park even after a click under the
    /// wheel changed the focus.
    func testTheParkPetalAsksForItsTargetsWhenReached() {
        let tree = Self.tree(["Code"], park: .init(focused: "Safari · Docs"))
        XCTAssertFalse(RadialMenu.asksForParkTargets(highlighting: ["loadouts"], from: []))
        XCTAssertFalse(RadialMenu.asksForParkTargets(highlighting: ["park", "restore"], from: ["park"]), "only as it is reached")
        XCTAssertTrue(RadialMenu.asksForParkTargets(highlighting: ["park"], from: ["capture"]))
        XCTAssertTrue(RadialMenu.asksForParkTargets(highlighting: ["park", "park"], from: []))
        let now = RadialMenu.ParkTargets(focused: "Notes · Groceries", parked: ["Mail · Inbox"])
        let fresh = RadialMenu.refreshed(tree, park: now)
        XCTAssertEqual(fresh?[2].kind, .park(now))
        XCTAssertEqual(fresh?[0], tree[0])
        XCTAssertEqual(fresh.map { RadialMenu.hint(for: ["park", "park"], in: $0) }, "Park Notes · Groceries")
        XCTAssertNil(RadialMenu.refreshed(fresh ?? [], park: now), "unchanged targets")
    }

    /// `menu` describes the tree: each node's id, path, name, kind, hint, direction, digit,
    /// and its children or the action it does; with a selection, the path highlighted and its hint.
    func testTheMenuJSONIsTheTree() throws {
        let tree = Self.tree(["Morning research and writing", "dev/web"], park: .init(focused: "Notes · Groceries"))
        let layout = RadialLayout(tree: tree)
        let json = RadialMenu.json(tree: tree, layout: layout)
        XCTAssertNil(json["wedges"])
        XCTAssertNil(json["rings"])
        XCTAssertEqual(json["deadZone"] as? Double, Double(layout.deadZone))
        let top = try XCTUnwrap(json["tree"] as? [[String: Any]])
        XCTAssertEqual(top.map { $0["id"] as? String }, ["loadouts", "capture", "park", "widgets"])
        XCTAssertEqual(top.map { $0["kind"] as? String }, ["loadouts", "capture", "park", "widgets"])
        XCTAssertEqual(top.map { $0["digit"] as? Int }, [1, 2, 3, 4])
        XCTAssertEqual(top[1]["angle"] as? Double ?? 0, .pi / 2, accuracy: 1e-9)
        XCTAssertNil(top[1]["row"], "only loadouts sit in rows")
        XCTAssertEqual(top[0]["hint"] as? String, "Move out to a loadout")
        let loadouts = try XCTUnwrap(top[0]["children"] as? [[String: Any]])
        XCTAssertEqual(loadouts.map { $0["path"] as? String }, ["loadouts/Morning research and writing", "loadouts/dev/web"])
        XCTAssertEqual(loadouts.map { $0["kind"] as? String }, ["loadout", "loadout"])
        XCTAssertEqual(loadouts.map { $0["row"] as? Int }, [1, 1], "rows count from 1, the innermost")
        let actions = try XCTUnwrap(loadouts[1]["children"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["path"] as? String }, ["loadouts/dev/web/preview", "loadouts/dev/web/apply", "loadouts/dev/web/clear"])
        XCTAssertEqual(actions.map { $0["action"] as? String }, ["preview", "apply", "clearAndApply"])
        XCTAssertEqual(actions.map { $0["kind"] as? String }, ["action", "action", "action"])
        XCTAssertNil(actions[0]["children"], "a leaf has an action, not children")
        XCTAssertEqual(actions[1]["hint"] as? String, "Apply dev/web")
        XCTAssertGreaterThan(actions[1]["radius"] as? Double ?? 0, loadouts[1]["radius"] as? Double ?? .infinity)
        let park = try XCTUnwrap(top[2]["children"] as? [[String: Any]])
        XCTAssertEqual(park.map { $0["action"] as? String }, ["park", "restore"])
        XCTAssertEqual(park.map { $0["hint"] as? String }, ["Park Notes · Groceries", "Nothing is parked"])
        let widgets = try XCTUnwrap(top[3]["children"] as? [[String: Any]])
        XCTAssertEqual(widgets.map { $0["action"] as? String }, ["revealWidgets", "editWidgets"])

        let selected = RadialMenu.json(tree: tree, layout: layout, selection: ["loadouts", "dev/web", "clear"])["selection"] as? [String: Any]
        XCTAssertEqual(selected?["kind"] as? String, "action")
        XCTAssertEqual(selected?["path"] as? String, "loadouts/dev/web/clear")
        XCTAssertEqual(selected?["name"] as? String, "Clear + Apply")
        XCTAssertEqual(selected?["hint"] as? String, "Clear this screen and apply dev/web")
        let branch = RadialMenu.json(tree: tree, layout: layout, selection: ["loadouts"])["selection"] as? [String: Any]
        XCTAssertEqual(branch?["kind"] as? String, "branch")
        let idle = RadialMenu.json(tree: tree, layout: layout, selection: [])["selection"] as? [String: Any]
        XCTAssertEqual(idle?["kind"] as? String, "cancel")
        XCTAssertEqual(idle?["hint"] as? String, "Release on an action · centre cancels")
    }

    /// `icons` counts the icons the wheel draws by a petal: the top petals' symbols, and a
    /// loadout's apps however many loadouts there are.
    func testTheMenuJSONCountsTheIconsDrawn() {
        let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        func icons(_ count: Int) -> [Int] {
            let tree = RadialMenu.tree(loadouts: (0..<count).map { .init(name: "L\($0)", icons: Array(repeating: image, count: 7)) },
                                       offersAllScreens: false, park: .init(), widgets: nil)
            let top = RadialMenu.json(tree: tree, layout: RadialLayout(tree: tree))["tree"] as? [[String: Any]]
            let loadouts = top?.first?["children"] as? [[String: Any]]
            return loadouts?.map { $0["icons"] as? Int ?? 0 } ?? []
        }
        XCTAssertEqual(icons(8), Array(repeating: RadialLayout.maxIcons, count: 8))
        XCTAssertEqual(icons(14), Array(repeating: RadialLayout.maxIcons, count: 14), "every place keeps room for its icons")
    }
}

final class ParkPetalTests: XCTestCase {
    /// Park's release says the front app did not answer when its Accessibility call timed out,
    /// and otherwise why there was nothing to park.
    @MainActor
    func testAnAppThatDoesNotAnswerIsSaidToNotAnswer() {
        XCTAssertEqual(LoadoutEngine.parkRefusal(.cannotComplete, otherwise: "no focused window", appName: "Safari"),
                       "Safari did not answer")
        XCTAssertEqual(LoadoutEngine.parkRefusal(.cannotComplete, otherwise: "window is not placeable", appName: nil),
                       "The app did not answer")
        XCTAssertEqual(LoadoutEngine.parkRefusal(.noValue, otherwise: "no focused window", appName: "Safari"), "no focused window")
        XCTAssertEqual(LoadoutEngine.parkRefusal(.attributeUnsupported, otherwise: "window is not placeable", appName: "Finder"),
                       "window is not placeable")
        XCTAssertEqual(LoadoutEngine.parkRefusal(.success, otherwise: "window is not placeable", appName: "Finder"),
                       "window is not placeable")
    }
}
