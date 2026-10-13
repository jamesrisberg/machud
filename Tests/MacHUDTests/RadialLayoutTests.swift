import AppKit
import XCTest
@testable import MacHUDCore

/// The path-based wheel's words, upright: where each sits and which one the pointer selects.
@MainActor
final class RadialLayoutTests: XCTestCase {
    static let counts = [0, 1, 3, 6, 10, 14]
    static let short = ["Code", "Mail", "Focus", "Notes", "Music", "Chat", "Docs", "Plan", "Read", "Write", "Draw", "Sketch",
                        "Talk", "Build"]
    static let long = ["Morning research and writing", "dev: Browsers", "Messaging", "Quarterly planning review",
                       "Supercalifragilisticexpialidocious research", "Customer support rotation",
                       "https://intranet.example.com/teams/design/reviews/weekly", "Design critique", "Evening reading"]

    /// `count` loadouts named from `names` (made distinct), then Capture, Park and, unless
    /// `widgets` is nil, Widgets.
    static func tree(_ count: Int, _ names: [String], allScreens: Bool = false, icons: Int = 3,
                     widgets: RadialMenu.WidgetsState? = .init(), park: RadialMenu.ParkTargets = .init()) -> [RadialNode] {
        let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        let entries = (0..<count).map { i -> RadialMenu.LoadoutEntry in
            let name = i < names.count ? names[i] : "\(names[i % names.count]) \(i / names.count + 1)"
            return .init(name: name, icons: Array(repeating: image, count: icons))
        }
        return RadialMenu.tree(loadouts: entries, offersAllScreens: allScreens, park: park, widgets: widgets)
    }

    /// Every case, laid out once for all the tests: 0, 1, 3, 6, 10 and 14 loadouts with short
    /// and long names, with and without All screens, with and without Widgets, at full size;
    /// and some drawn at 0.79 (a wheel fitted to a smaller screen).
    private static let cases: [(layout: RadialLayout, tree: [RadialNode], what: String)] = {
        var out: [(RadialLayout, [RadialNode], String)] = []
        for count in counts {
            for (label, names) in [("short", short), ("long", long)] {
                for (allScreens, widgets) in [(false, true), (true, false)] {
                    let tree = tree(count, names, allScreens: allScreens, widgets: widgets ? .init() : nil)
                    out.append((RadialLayout(tree: tree), tree,
                                "\(count) loadouts, \(label) names\(allScreens ? ", all screens" : "")\(widgets ? "" : ", no widgets")"))
                }
            }
        }
        for count in [3, 10] {
            for (label, names) in [("short", short), ("long", long)] {
                let tree = tree(count, names)
                out.append((RadialLayout(tree: tree, scale: 0.79), tree, "\(count) loadouts, \(label) names, at 0.79"))
            }
        }
        return out
    }()

    private func everyLayout(_ body: (RadialLayout, [RadialNode], String) -> Void) {
        for (layout, tree, what) in Self.cases { body(layout, tree, what) }
    }

    /// Every branch of `layout` with the petals that show while it is open.
    private static func states(_ layout: RadialLayout) -> [(open: [String], showing: [[String]])] {
        layout.branches.map { ($0, layout.showing(open: $0)) }
    }

    private static func distance(to rect: CGRect) -> CGFloat { RadialLayout.distance(to: rect) }

    private static func farthest(_ rect: CGRect) -> CGFloat {
        hypot(max(abs(rect.minX), abs(rect.maxX)), max(abs(rect.minY), abs(rect.maxY)))
    }

    private static func fixed(_ layout: RadialLayout) -> [RadialLayout.Word] { layout.words.filter { $0.role.path == nil } }

    // MARK: What shows

    /// The wheel opens on the top petals alone; reaching a petal with children unfolds them
    /// beyond it, and a branch's children show while it, or anything under it, is highlighted.
    func testOnlyThePathShows() {
        let tree = Self.tree(3, Self.short)
        let layout = RadialLayout(tree: tree)
        XCTAssertEqual(layout.showing(open: []), [["loadouts"], ["capture"], ["park"], ["widgets"]])
        XCTAssertEqual(layout.showing(open: layout.openBranch(["loadouts"])).count, 4 + 3)
        let deep = layout.showing(open: layout.openBranch(["loadouts", "Mail", "apply"]))
        XCTAssertEqual(deep.count, 4 + 3 + 3)
        XCTAssertTrue(deep.contains(["loadouts", "Mail", "clear"]))
        XCTAssertFalse(deep.contains(["loadouts", "Code", "apply"]), "only the loadout on the path unfolds")
        XCTAssertFalse(deep.contains(["capture", "screen"]))
        XCTAssertEqual(layout.openBranch(["capture", "draw"]), ["capture"])
        XCTAssertEqual(layout.openBranch(["loadouts"]), ["loadouts"])
        XCTAssertEqual(RadialLayout(tree: Self.tree(0, Self.short)).openBranch(["loadouts"]), [], "nothing to unfold")
    }

    // MARK: Words

    /// No two words that show together overlap, nor touch that state's hint.
    func testNoTwoWordsShowingTogetherOverlap() {
        everyLayout { layout, _, what in
            for (open, showing) in Self.states(layout) {
                let words = Self.fixed(layout) + showing.compactMap { layout.word($0) }
                for (a, first) in words.enumerated() {
                    for second in words[(a + 1)...] {
                        XCTAssertFalse(first.frame.intersects(second.frame), "\(what), open \(open): \(first.role) and \(second.role)")
                    }
                    XCTAssertFalse(first.frame.intersects(layout.hintZone(open: open)), "\(what), open \(open): \(first.role) and the hint")
                }
            }
        }
    }

    /// Petals lie wholly outside the dead zone; the centre's word and the digits wholly inside it.
    func testNoWordCrossesTheDeadZone() {
        everyLayout { layout, _, what in
            for word in layout.words {
                switch word.role {
                case .centre, .digit:
                    XCTAssertLessThanOrEqual(Self.farthest(word.frame), layout.deadZone, "\(what): \(word.role)")
                case .node:
                    XCTAssertGreaterThanOrEqual(Self.distance(to: word.frame), layout.deadZone, "\(what): \(word.role)")
                }
            }
        }
    }

    /// Points over `frame`, a quarter point inside its edges: corners, edges and within.
    private static func over(_ frame: CGRect) -> [CGPoint] {
        let inner = frame.insetBy(dx: 0.25, dy: 0.25)
        var points: [CGPoint] = []
        for u in 0...8 {
            for v in 0...4 {
                points.append(CGPoint(x: inner.minX + inner.width * CGFloat(u) / 8, y: inner.minY + inner.height * CGFloat(v) / 4))
            }
        }
        return points
    }

    /// Where the words keep the pointer while an open petal holds it at `p`
    /// (`RadialLayout.Hold.scope`); nil when no open petal holds it.
    private static func scope(_ layout: RadialLayout, open: [String], at p: CGPoint) -> [String]? {
        layout.hold(open, radius: RadialGeometry.radius(of: p), angle: RadialGeometry.angle(of: p))?.scope
    }

    /// Wherever on a word showing the pointer is, that word is the one selected, unless an open
    /// petal holds the pointer there and the word is not among the ones it keeps
    /// (`RadialLayout.Hold.scope`), when what is selected is that petal or among them; and where
    /// the pointer is on the highlighted word grown under it, that word stays selected.
    func testTheWordUnderThePointerIsTheOneThatLights() {
        everyLayout { layout, _, what in
            for (open, showing) in Self.states(layout) {
                for path in showing {
                    guard let word = layout.word(path) else { return XCTFail("\(what): no word for \(path)") }
                    for p in Self.over(word.frame) {
                        let selected = layout.selection(at: p, open: open)
                        func within(_ path: [String], _ scope: [String]) -> Bool { path.count > scope.count && path.starts(with: scope) }
                        if path != open, let scope = Self.scope(layout, open: open, at: p), !within(path, scope) {
                            if !selected.starts(with: scope) || selected.isEmpty {
                                XCTFail("\(what), open \(open): \(path) at \(p), held under \(scope), selects \(selected)")
                                break
                            }
                        } else if selected != path {
                            XCTFail("\(what), open \(open): \(path) at \(p) selects \(selected)")
                            break
                        }
                    }
                    for p in Self.over(word.grownFrame) where layout.selection(at: p, open: path) != path {
                        XCTFail("\(what): \(path) grown at \(p) selects \(layout.selection(at: p, open: path))")
                        break
                    }
                }
            }
            XCTAssertEqual(layout.selection(at: .zero, open: ["loadouts"]), [], "\(what): the centre selects nothing")
        }
    }

    /// The highlighted petal grows from its anchor (away from the centre) and still touches no
    /// other word showing with it, its children included.
    func testAGrownPetalTouchesNoOtherWordShowingWithIt() {
        everyLayout { layout, _, what in
            for word in layout.words {
                guard let path = word.role.path else { continue }
                XCTAssertGreaterThanOrEqual(word.grow, 1, "\(what): \(path)")
                XCTAssertLessThanOrEqual(word.grow, RadialWheelView.grow, "\(what): \(path)")
                let others = Self.fixed(layout) + layout.showing(open: layout.openBranch(path)).filter { $0 != path }.compactMap { layout.word($0) }
                for other in others {
                    XCTAssertFalse(word.grownFrame.intersects(other.frame), "\(what): \(path) grown and \(other.role)")
                }
                XCTAssertGreaterThanOrEqual(Self.distance(to: word.grownFrame), layout.deadZone, "\(what): \(path) grown")
            }
        }
    }

    /// A petal is anchored on its direction and grows away from the centre: on the right half
    /// it starts at its anchor, on the left half it ends there, at the top and the bottom it is
    /// centred on it; above the centre it sits above its anchor, below it under it.
    func testPetalsGrowAwayFromTheCentre() {
        everyLayout { layout, tree, what in
            for word in layout.words {
                guard let path = word.role.path, let node = RadialMenu.node(at: path, in: tree) else { continue }
                // An action sits beside its branch instead (`testABranchsActionsSitAsLeavesJustBeyondIt`).
                if node.isLeaf { continue }
                let a = node.angle
                XCTAssertEqual(RadialGeometry.angle(of: word.anchor), RadialGeometry.normalized(a), accuracy: 1e-6, "\(what): \(path)")
                let f = word.frame, anchor = word.anchor
                if sin(a) > 0.6 { XCTAssertEqual(f.minX, anchor.x, accuracy: 0.01, "\(what): right half starts at its anchor") }
                if sin(a) < -0.6 { XCTAssertEqual(f.maxX, anchor.x, accuracy: 0.01, "\(what): left half ends at its anchor") }
                if abs(sin(a)) < 0.01 { XCTAssertEqual(f.midX, anchor.x, accuracy: 0.01, "\(what): centred at the top or bottom") }
                if cos(a) > 0.6 { XCTAssertEqual(f.minY, anchor.y, accuracy: 0.01, "\(what): above its anchor") }
                if cos(a) < -0.6 { XCTAssertEqual(f.maxY, anchor.y, accuracy: 0.01, "\(what): under its anchor") }
            }
        }
    }

    /// A branch's actions sit as leaves just beyond it: all past the same edge of its grown word
    /// (above or below a loadout or Park, beside Capture or Widgets), the nearest a stem's length
    /// and both bubbles from its word grown and no further than three of those, the others
    /// packed close behind it.
    func testABranchsActionsSitAsLeavesJustBeyondIt() {
        everyLayout { layout, tree, what in
            for branch in layout.branches where !branch.isEmpty {
                guard let node = RadialMenu.node(at: branch, in: tree), let parent = layout.word(branch),
                      node.children.allSatisfy(\.isLeaf) else { continue }
                let s = layout.scale
                let room = (2 * RadialGlass.padding.width + RadialLayout.stem) * s
                let words = node.children.compactMap { layout.word(branch + [$0.id]) }
                let g = parent.grownFrame
                let edges: [(String, (CGRect) -> Bool)] = [("above", { $0.minY >= g.maxY }), ("below", { $0.maxY <= g.minY }),
                                                          ("right", { $0.minX >= g.maxX }), ("left", { $0.maxX <= g.minX })]
                XCTAssertTrue(edges.contains { _, beyond in words.allSatisfy { beyond($0.frame) } }, "\(what): \(branch) past one edge")
                func apart(_ f: CGRect) -> CGFloat { max(f.minY - g.maxY, g.minY - f.maxY, f.minX - g.maxX, g.minX - f.maxX) }
                for word in words {
                    XCTAssertFalse(g.insetBy(dx: -room + 0.01, dy: -room + 0.01).intersects(word.frame), "\(what): \(word.role) keeps a stem's room")
                }
                let gaps = words.map { apart($0.frame) }
                // Three rooms: a loadout at a row's edge has its neighbour's place above it.
                XCTAssertLessThan(gaps.min() ?? 0, 3 * room, "\(what): \(branch)'s nearest action is near it")
                let step = (words.map(\.frame.height).max() ?? 0) + 2 * RadialGlass.padding.height * s + RadialLayout.wordGap * s
                XCTAssertLessThanOrEqual((gaps.max() ?? 0) - (gaps.min() ?? 0), CGFloat(words.count - 1) * step + 0.5,
                                         "\(what): \(branch)'s actions packed close")
            }
        }
    }

    /// The loadouts sit on one circle per row, beyond Apply Loadout's anchor, each row further
    /// out than the one before and clear of the actions the row inside it unfolds.
    func testTheLoadoutsSitOnACirclePerRowBeyondApplyLoadout() {
        everyLayout { layout, tree, what in
            for branch in layout.branches where branch == [RadialMenu.loadoutsID] {
                guard let node = RadialMenu.node(at: branch, in: tree), let parent = layout.word(branch) else { continue }
                var previous = RadialGeometry.radius(of: parent.anchor)
                for row in Set(node.children.map(\.row)).sorted() {
                    let radii = node.children.filter { $0.row == row }.compactMap { layout.word(branch + [$0.id]) }
                        .map { RadialGeometry.radius(of: $0.anchor) }
                    XCTAssertLessThan((radii.max() ?? 0) - (radii.min() ?? 0), 0.01, "\(what): \(branch) row \(row)")
                    XCTAssertGreaterThan(radii.min() ?? 0, previous, "\(what): \(branch) row \(row)")
                    previous = radii.max() ?? previous
                }
                // An inner row's actions keep clear of the next row's places.
                for child in node.children where node.children.contains(where: { $0.row > child.row }) {
                    let next = node.children.filter { $0.row == child.row + 1 }.compactMap { layout.word(branch + [$0.id]) }
                    for action in child.children {
                        let frame = layout.word(branch + [child.id, action.id])?.grownFrame ?? .null
                        XCTAssertFalse(next.contains { $0.frame.intersects(frame) }, "\(what): \(child.id)/\(action.id)")
                    }
                }
            }
        }
    }

    /// Short names and every action read whole at full size, on one line; a long name shrinks
    /// and then ends in an ellipsis within its place; every line of every word lies inside its
    /// frame.
    func testWordsAreWholeWhereTheyFitAndInsideTheirFrames() {
        everyLayout { layout, tree, what in
            for word in layout.words {
                for line in word.fit.lines {
                    XCTAssertLessThanOrEqual(TextFit.width(line, font: word.font), word.frame.width + 0.01, "\(what): \(line)")
                }
                XCTAssertLessThanOrEqual(word.textHeight, word.frame.height + 0.01, "\(what): \(word.role)")
                if let path = word.role.path, RadialMenu.node(at: path, in: tree)?.isLeaf == true {
                    XCTAssertFalse(word.fit.truncated, "\(what): \(word.fit.lines)")
                    XCTAssertEqual(word.fit.lines.count, 1, "\(what): \(word.fit.lines)")
                    if layout.scale == 1 { XCTAssertEqual(word.fit.size, word.style.preferred, "\(what): \(word.fit.lines)") }
                }
            }
        }
        let layout = RadialLayout(tree: Self.tree(3, Self.short))
        for path in layout.showing(open: ["loadouts"]) {
            let word = layout.word(path)
            XCTAssertEqual(word?.fit.lines.count, 1, "\(path)")
            XCTAssertEqual(word?.fit.truncated, false)
        }
        let long = RadialLayout(tree: Self.tree(1, ["Morning research and writing"]))
        let word = long.word(["loadouts", "Morning research and writing"])
        XCTAssertEqual(word?.fit.lines, ["Morning research…"])
        XCTAssertEqual(word?.fit.truncated, true)
    }

    /// The top petals show their symbol; loadouts their apps' icons on wheels of up to eight
    /// loadouts, none beyond.
    func testIconsShowHoweverManyLoadouts() {
        for count in [3, 8, 9, 14] {
            let layout = RadialLayout(tree: Self.tree(count, Self.short, icons: 7))
            let icons = layout.showing(open: ["loadouts"]).filter { $0.count == 2 }.map { layout.icons(of: $0) }
            XCTAssertEqual(Set(icons), [RadialLayout.maxIcons], "\(count) loadouts")
            XCTAssertEqual(layout.icons(of: ["capture"]), 1)
        }
    }

    /// Adding a loadout moves none of the others: each keeps its direction, its row and its
    /// distance from the centre, and so do its actions, whatever the names, from one loadout to
    /// twenty, with or without Widgets. A long name fits its place (on one line, shrinking,
    /// then ending in an ellipsis) rather than pushing the row out.
    func testAddingALoadoutMovesNoneOfTheOthers() {
        for (label, names) in [("short", Self.short), ("long", Self.long)] {
            for widgets in [true, false] {
                func layout(_ count: Int) -> (RadialLayout, [RadialNode]) {
                    let tree = Self.tree(count, names, widgets: widgets ? .init() : nil)
                    return (RadialLayout(tree: tree), tree)
                }
                var (before, beforeTree) = layout(1)
                for count in 2...20 {
                    let (after, afterTree) = layout(count)
                    let what = "\(label) names, \(widgets ? "" : "no widgets, ")\(count - 1) → \(count) loadouts"
                    for (old, new) in zip(beforeTree[0].children, afterTree[0].children) {
                        XCTAssertEqual(old.id, new.id, what)
                        XCTAssertEqual(old.angle, new.angle, accuracy: 1e-12, "\(what): \(old.id)'s direction")
                        XCTAssertEqual(old.row, new.row, "\(what): \(old.id)'s row")
                        for path in [["loadouts", old.id]] + old.children.map({ ["loadouts", old.id, $0.id] }) {
                            let a = before.word(path).map { RadialGeometry.radius(of: $0.anchor) } ?? -1
                            let b = after.word(path).map { RadialGeometry.radius(of: $0.anchor) } ?? -2
                            XCTAssertEqual(a, b, accuracy: 0.001, "\(what): \(path.joined(separator: "/"))'s distance")
                        }
                    }
                    (before, beforeTree) = (after, afterTree)
                }
            }
        }
        // A name wider than its place ends in an ellipsis.
        let long = RadialLayout(tree: Self.tree(1, ["Supercalifragilisticexpialidocious research and development notes"]))
        let word = long.word(["loadouts", "Supercalifragilisticexpialidocious research and development notes"])
        XCTAssertEqual(word?.fit.truncated, true)
        XCTAssertLessThanOrEqual(word?.frame.width ?? .infinity, RadialLayout.loadoutWidth + 0.01)
    }

    /// On a laptop's screen too, adding a loadout moves none of the others: the wheel's size on a
    /// screen is chosen for the screen alone (fitting `RadialLayout.fittedRows` full rows, Widgets
    /// and All screens included), never for how many loadouts there are, so up to that many rows
    /// every loadout keeps its direction, row and distance. The wheel opens at the same place while
    /// the loadouts fill the rows they are on, and moves only down (and a little sideways on a
    /// narrow screen), as a new row needs the room.
    func testAddingALoadoutMovesNoneOfTheOthersOnALaptopScreen() {
        let most = RadialMenu.loadoutPlaces(1000).filter { $0.row < RadialLayout.fittedRows }.count
        XCTAssertGreaterThanOrEqual(most, 14, "room for at least three rows")
        for screen in [CGRect(x: 0, y: 0, width: 1424, height: 851), CGRect(x: 0, y: 70, width: 1024, height: 546),
                       CGRect(x: 0, y: 0, width: 1024, height: 640)] {
            for (label, names) in [("short", Self.short), ("long", Self.long)] {
                var before = RadialMenu.place(tree: Self.tree(1, names), visibleFrame: screen)
                var beforeTree = Self.tree(1, names)
                for count in 2...most {
                    let tree = Self.tree(count, names, allScreens: count % 2 == 0, widgets: count % 3 == 0 ? nil : .init())
                    let after = RadialMenu.place(tree: tree, visibleFrame: screen)
                    let what = "\(screen.size), \(label) names, \(count - 1) → \(count) loadouts"
                    XCTAssertEqual(after.layout.scale, before.layout.scale, accuracy: 1e-9, "\(what): the size")
                    if tree[0].children.last?.row == beforeTree[0].children.last?.row {
                        XCTAssertEqual(after.center, before.center, "\(what): where it opens")
                    } else {
                        XCTAssertLessThanOrEqual(after.center.y, before.center.y, "\(what): a new row moves it only down")
                    }
                    for (old, new) in zip(beforeTree[0].children, tree[0].children) {
                        XCTAssertEqual(old.angle, new.angle, accuracy: 1e-12, "\(what): \(old.id)'s direction")
                        XCTAssertEqual(old.row, new.row, "\(what): \(old.id)'s row")
                        let a = before.layout.word(["loadouts", old.id]).map { RadialGeometry.radius(of: $0.anchor) } ?? -1
                        let b = after.layout.word(["loadouts", old.id]).map { RadialGeometry.radius(of: $0.anchor) } ?? -2
                        XCTAssertEqual(a, b, accuracy: 0.001, "\(what): \(old.id)'s distance")
                    }
                    (before, beforeTree) = (after, tree)
                }
            }
        }
    }

    /// The loadouts' arc, padding included, keeps clear of Capture's and Widgets' words: no point
    /// of either falls inside it.
    func testTheLoadoutsArcKeepsClearOfCaptureAndWidgets() {
        for count in 1...20 {
            for names in [Self.short, Self.long] {
                for widgets in [true, false] {
                    let layout = RadialLayout(tree: Self.tree(count, names, widgets: widgets ? .init() : nil))
                    let what = "\(count) loadouts named like \(names[0])\(widgets ? "" : ", no widgets")"
                    guard let petal = layout.petal(["loadouts"]), petal.hasChildren else { return XCTFail(what) }
                    for id in ["capture", "widgets"] {
                        guard let word = layout.word([id]) else { continue }
                        for frame in [word.frame, word.grownFrame] {
                            for p in Self.over(frame) where petal.covers(RadialGeometry.angle(of: p)) {
                                XCTFail("\(what): \(id)'s word at \(p) is inside the loadouts' arc")
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Compact

    /// The wheel opens small, however many loadouts there are, and a path shows only its own
    /// petals. The rows sit at the same distances whatever the names and however many loadouts
    /// fill them; up to five loadouts there is one row, and each row further out adds its depth
    /// and the room its places' actions need.
    func testTheWheelStaysCompactHoweverManyLoadouts() {
        func reach(_ layout: RadialLayout, open: [String]) -> CGFloat {
            layout.showing(open: open).compactMap { layout.word($0)?.grownFrame }.map(Self.farthest).max() ?? 0
        }
        let few = RadialLayout(tree: Self.tree(3, Self.short))
        let all = RadialLayout(tree: Self.tree(14, Self.long)).petal(["loadouts"])?.rowStarts ?? []
        for count in [1, 3, 5, 6, 10, 14] {
            for (names, long) in [(Self.short, false), (Self.long, true)] {
                let layout = RadialLayout(tree: Self.tree(count, names))
                let what = "\(count) \(long ? "long" : "short") loadouts"
                XCTAssertEqual(reach(layout, open: []), reach(few, open: []), accuracy: 0.01, "\(what): the top petals do not move")
                XCTAssertLessThanOrEqual(reach(layout, open: []), 150, "\(what): the wheel as it opens")
                let petal = layout.petal(["loadouts"])
                XCTAssertEqual(petal?.rows.count, Set(RadialMenu.loadoutPlaces(count).map(\.row)).count, "\(what): rows")
                for (start, fixed) in zip(petal?.rowStarts ?? [], all) {
                    XCTAssertEqual(start, fixed, accuracy: 0.001, "\(what): each row starts where it always does")
                }
                let rows = CGFloat(petal?.rows.count ?? 1)
                for branch in layout.branches {
                    // A loadout at the sector's edge has its actions beside it, further round.
                    XCTAssertLessThanOrEqual(reach(layout, open: branch), 410 + (rows - 1) * 210, "\(what), \(branch)")
                }
            }
        }
    }

    // MARK: The pointer's path

    /// Where the pointer is, out from the centre along `angles` (one per segment, each to the
    /// radius given), selecting as it goes; the path selected at the end.
    private static func trace(_ layout: RadialLayout, _ legs: [(angle: Double, radius: CGFloat)]) -> [String] {
        var selection: [String] = []
        var r: CGFloat = 0, a = legs.first?.angle ?? 0
        for leg in legs {
            // Round to the leg's angle at the radius reached, then out to its radius.
            let turns = Int(abs(RadialGeometry.difference(leg.angle, a)) / (2 * .pi / 360)) + 1
            for k in 1...turns {
                let t = Double(k) / Double(turns)
                selection = layout.selection(at: RadialGeometry.point(r, a + RadialGeometry.difference(leg.angle, a) * t), open: selection)
            }
            a = leg.angle
            while r < leg.radius {
                r = min(leg.radius, r + 3)
                selection = layout.selection(at: RadialGeometry.point(r, a), open: selection)
            }
        }
        return selection
    }

    /// A straight move from the centre to an action selects it: a loadout's Apply, on any row,
    /// for the loadouts within 45° of straight up (Apply Loadout, the loadout, Apply all lie that
    /// way), and every action of Capture, Park and Widgets.
    func testAStraightMoveSelectsWhatLiesThatWay() {
        everyLayout { layout, tree, what in
            for node in tree[0].children where abs(RadialGeometry.difference(node.angle, 0)) < .pi / 4 {
                let path = ["loadouts", node.id, "apply"]
                XCTAssertEqual(Self.walk(layout, [Self.middle(layout, path)]), path, "\(what): \(node.id)")
            }
            for top in tree.dropFirst() {
                for leaf in top.children {
                    XCTAssertEqual(Self.walk(layout, [Self.middle(layout, [top.id, leaf.id])]), [top.id, leaf.id], "\(what): \(top.id)/\(leaf.id)")
                }
            }
        }
    }

    /// The pointer going from word to word through `points` (wheel coordinates) in small steps,
    /// selecting as it goes; the path selected at the end. With `open`, it starts at the first
    /// point with that path selected; else it starts in the centre with nothing.
    private static func walk(_ layout: RadialLayout, _ points: [CGPoint], from open: [String] = []) -> [String] {
        var selection = open
        var at = open.isEmpty ? CGPoint.zero : points[0]
        for target in open.isEmpty ? points : Array(points.dropFirst()) {
            let steps = max(1, Int(hypot(target.x - at.x, target.y - at.y) / 3))
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps)
                selection = layout.selection(at: CGPoint(x: at.x + (target.x - at.x) * t, y: at.y + (target.y - at.y) * t), open: selection)
            }
            at = target
        }
        return selection
    }

    /// The distance from `p` to the segment from `a` to `b`.
    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let (dx, dy) = (b.x - a.x, b.y - a.y)
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(1e-9, dx * dx + dy * dy)))
        return hypot(a.x + dx * t - p.x, a.y + dy * t - p.y)
    }

    private static func middle(_ layout: RadialLayout, _ path: [String]) -> CGPoint {
        let frame = layout.word(path)?.frame ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Any loadout's actions are reached the way the wheel unfolds them: onto Apply Loadout,
    /// out past where the loadouts start and round to the loadout, onto it, and on to the action
    /// along its branch. Nothing on the way is previewed or applied: only the release does that.
    func testEveryActionIsReachedAlongItsPath() {
        everyLayout { layout, tree, what in
            guard let ring = layout.petal(["loadouts"])?.start, ring.isFinite else { return }
            for loadout in tree[0].children {
                for action in loadout.children {
                    let path = ["loadouts", loadout.id, action.id]
                    var points = [Self.middle(layout, ["loadouts"])]
                    points += Self.arc(from: 0, to: loadout.angle, radius: ring + 2)
                    points.append(Self.middle(layout, ["loadouts", loadout.id]))
                    points.append(Self.middle(layout, path))
                    XCTAssertEqual(Self.walk(layout, points), path, what)
                }
            }
        }
    }

    /// Points round a circle of `radius` from angle `a` to `b` the short way, a degree apart.
    private static func arc(from a: Double, to b: Double, radius: CGFloat) -> [CGPoint] {
        let turn = RadialGeometry.difference(b, a)
        let steps = max(1, Int(abs(turn) * 180 / .pi))
        return (0...steps).map { RadialGeometry.point(radius, a + turn * Double($0) / Double(steps)) }
    }

    /// With Apply Loadout open, a straight move from its word to any loadout's word, on any row,
    /// stays among the loadouts and lands on it: the loadouts sit in the top sector, so the move
    /// never passes the centre, Capture, Park or Widgets, and a release on the way never
    /// captures, parks or changes the widgets.
    func testAStraightMoveFromApplyLoadoutStaysAmongTheLoadouts() {
        everyLayout { layout, tree, what in
            let start = Self.middle(layout, ["loadouts"])
            for loadout in tree[0].children {
                let end = Self.middle(layout, ["loadouts", loadout.id])
                XCTAssertGreaterThan(Self.distance(from: .zero, toSegment: start, end), layout.deadZone,
                                     "\(what): the way to \(loadout.id) passes clear of the centre")
                var selection = ["loadouts"]
                let steps = max(1, Int(hypot(end.x - start.x, end.y - start.y) / 2))
                for k in 1...steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    selection = layout.selection(at: p, open: selection)
                    if selection.first != "loadouts" {
                        XCTFail("\(what): toward \(loadout.id), at \(p) the wheel opened \(selection)")
                        break
                    }
                }
                XCTAssertEqual(selection, ["loadouts", loadout.id], what)
            }
        }
    }

    /// With Apply Loadout open, a straight move from its word to Capture's, Park's or Widgets'
    /// word opens that petal: the loadouts' arc never reaches their directions.
    func testAStraightMoveFromApplyLoadoutOpensCaptureParkOrWidgets() {
        everyLayout { layout, tree, what in
            for top in tree.dropFirst() {
                let reached = Self.walk(layout, [Self.middle(layout, ["loadouts"]), Self.middle(layout, [top.id])], from: ["loadouts"])
                XCTAssertEqual(reached, [top.id], "\(what): toward \(top.id)")
            }
        }
    }

    /// Out among the loadouts the pointer can go round to any of them past where they start,
    /// and they stay open as it passes another top petal's direction or the edge of its word.
    func testTheLoadoutsStayOpenAsThePointerGoesRound() {
        everyLayout { layout, tree, what in
            guard let petal = layout.petal(["loadouts"]), petal.start.isFinite else { return }
            for loadout in tree[0].children {
                let start = petal.rowStarts[loadout.row]
                let path = Self.trace(layout, [(0, start + 1), (loadout.angle, start + 1)])
                XCTAssertEqual(Array(path.prefix(2)), ["loadouts", loadout.id], what)
            }
        }
    }

    /// Back toward the centre the deeper branches close; in the centre nothing is selected.
    func testMovingBackInClosesTheBranchesBeyond() {
        let tree = Self.tree(3, Self.short)
        let layout = RadialLayout(tree: tree)
        let open = ["loadouts", "Code", "apply"]
        let topWord = try! XCTUnwrap(layout.word(["capture"]))
        XCTAssertEqual(layout.selection(at: CGPoint(x: topWord.frame.midX, y: topWord.frame.midY), open: open), ["capture"])
        XCTAssertEqual(layout.selection(at: CGPoint(x: 0, y: layout.deadZone + 2), open: open), ["loadouts"])
        XCTAssertEqual(layout.selection(at: CGPoint(x: 1, y: 1), open: open), [])
    }

    // MARK: The hint

    /// The hint sits under every word showing, on up to two lines inside its zone.
    func testTheHintSitsUnderTheWheelAndIsNeverClipped() {
        everyLayout { layout, _, what in
            for (open, showing) in Self.states(layout) {
                let zone = layout.hintZone(open: open)
                for path in showing {
                    XCTAssertGreaterThanOrEqual(layout.word(path)?.grownFrame.minY ?? 0, zone.maxY, "\(what), open \(open): \(path)")
                }
                for hint in ["Apply Code", RadialMenu.idleHint,
                             "Clear this screen and apply Quarterly planning with the whole design and research team",
                             "Park Safari · " + String(repeating: "A rather long page title ", count: 8)] {
                    let fit = TextFit.fit(hint, style: layout.hintStyle, width: zone.width)
                    XCTAssertLessThanOrEqual(fit.lines.count, 2)
                    XCTAssertLessThanOrEqual(CGFloat(fit.lines.count) * layout.hintLineHeight(fit), zone.height + 0.01)
                }
            }
        }
    }

    // MARK: The screen

    /// The wheel's own centre is the middle of the screen while the rows of loadouts in use fit
    /// around it there (one row always does), and otherwise sits only as far below as their room
    /// needs: the top of that room is then the top of the screen (and, where the rows fill the
    /// screen's width, a side of it). Names never move it.
    func testTheWheelsCentreIsTheMiddleOfTheScreenUnlessItsRowsNeedRoom() {
        let screens = [CGRect(x: 0, y: 0, width: 1024, height: 616), CGRect(x: 0, y: 70, width: 1024, height: 546),
                       CGRect(x: 1024, y: -200, width: 1440, height: 875), CGRect(x: 0, y: 0, width: 1424, height: 851)]
        for visible in screens {
            let room = visible.insetBy(dx: RadialMenu.screenMargin, dy: RadialMenu.screenMargin)
            let middle = CGPoint(x: room.midX.rounded(), y: room.midY.rounded())
            for count in [0, 1, 3, 5] {
                let placed = RadialMenu.place(tree: Self.tree(count, Self.long, allScreens: true), visibleFrame: visible)
                XCTAssertEqual(placed.center, middle, "\(count) loadouts in \(visible): dead centre")
            }
            var shifted = false
            for count in 1...RadialMenu.loadoutPlaces(1000).filter({ $0.row < RadialLayout.fittedRows }).count {
                let short = RadialMenu.place(tree: Self.tree(count, Self.short, allScreens: true), visibleFrame: visible)
                let long = RadialMenu.place(tree: Self.tree(count, Self.long, allScreens: true), visibleFrame: visible)
                XCTAssertEqual(short.center, long.center, "\(count) loadouts in \(visible): names never move it")
                let rows = RadialLayout.fitting(Self.tree(count, Self.long, allScreens: true), in: room.size).extent
                if long.center.y < middle.y {
                    shifted = true
                    XCTAssertEqual(long.center.y + rows.maxY, room.maxY, accuracy: 1,
                                   "\(count) loadouts in \(visible): only as far down as the rows need")
                }
                if long.center.x != middle.x {
                    let edge = min(abs(long.center.x + rows.minX - room.minX), abs(long.center.x + rows.maxX - room.maxX))
                    XCTAssertLessThanOrEqual(edge, 1, "\(count) loadouts in \(visible): across, only as far as the rows need")
                }
            }
            XCTAssertTrue(shifted, "\(visible): four rows do not fit around the middle, so the wheel moves down for them")
        }
    }

    /// The wheel never outgrows the screen it opens on: on a 1024 by 640 display (a 13-inch at
    /// Larger Text, less the menu bar) or with a Dock at the bottom, with many loadouts and long
    /// names, every word that can show and the hint are on screen, inside the margin, the wheel in
    /// the middle of it. Its size is the screen's: full size where the fitted rows fit at full size,
    /// and smaller from the first loadout past the fitted rows.
    func testTheWheelFitsTheScreenItOpensOn() {
        let screens = [CGRect(x: 0, y: 0, width: 1024, height: 616), CGRect(x: 0, y: 70, width: 1024, height: 546),
                       CGRect(x: 1024, y: -200, width: 1440, height: 875), CGRect(x: 0, y: 0, width: 1424, height: 851)]
        for visible in screens {
            let most = RadialMenu.loadoutPlaces(1000).filter { $0.row < RadialLayout.fittedRows }.count
            let margin = RadialMenu.screenMargin - 0.5  // the centre is rounded to whole points
            for count in [0, 1, 3, 5, 6, 9, 10, 14, 15, most, most + 1, most + 5] {
                let placed = RadialMenu.place(tree: Self.tree(count, Self.long, allScreens: true), visibleFrame: visible)
                XCTAssertLessThanOrEqual(placed.layout.scale, 1)
                let words = placed.layout.bounds.offsetBy(dx: placed.center.x, dy: placed.center.y)
                XCTAssertTrue(visible.insetBy(dx: margin, dy: margin).contains(words), "\(count) loadouts in \(visible): \(words)")
                let middle = CGPoint(x: visible.midX, y: visible.midY)
                XCTAssertLessThan(hypot(placed.center.x - middle.x, placed.center.y - middle.y), visible.height / 3,
                                  "\(count) loadouts: near the middle of the screen")
            }
            let full = RadialMenu.place(tree: Self.tree(most, Self.long), visibleFrame: visible).layout.scale
            let past = RadialMenu.place(tree: Self.tree(most + 1, Self.long), visibleFrame: visible).layout.scale
            XCTAssertLessThan(past, full, "\(visible): a loadout past the fitted rows draws the wheel smaller")
        }
        let roomy = RadialMenu.place(tree: Self.tree(8, Self.long), visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1100))
        XCTAssertEqual(roomy.layout.scale, 1, "full size where it fits")
    }
}
