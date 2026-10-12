import AppKit
import XCTest
@testable import MacHUDCore

/// The path-based wheel's words, upright, on one soft field: where each sits, which one the
/// pointer selects, and the field behind what shows.
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

    /// A branch's children sit on one circle per row, beyond the branch's own anchor, each row
    /// further out than the one before and clear of the actions its loadouts unfold.
    func testABranchsChildrenSitOnACirclePerRowBeyondIt() {
        everyLayout { layout, tree, what in
            for branch in layout.branches where !branch.isEmpty {
                guard let node = RadialMenu.node(at: branch, in: tree), let parent = layout.word(branch) else { continue }
                var previous = RadialGeometry.radius(of: parent.anchor)
                for row in Set(node.children.map(\.row)).sorted() {
                    let radii = node.children.filter { $0.row == row }.compactMap { layout.word(branch + [$0.id]) }
                        .map { RadialGeometry.radius(of: $0.anchor) }
                    XCTAssertLessThan((radii.max() ?? 0) - (radii.min() ?? 0), 0.01, "\(what): \(branch) row \(row)")
                    XCTAssertGreaterThan(radii.min() ?? 0, previous, "\(what): \(branch) row \(row)")
                    previous = radii.max() ?? previous
                }
                // An inner row's actions lie inside the next row.
                for child in node.children where node.children.contains(where: { $0.row > child.row }) {
                    let next = node.children.filter { $0.row == child.row + 1 }.compactMap { layout.word(branch + [$0.id]) }
                    let innerEdge = next.map { RadialLayout.distance(to: $0.frame) }.min() ?? .infinity
                    for action in child.children {
                        let frame = layout.word(branch + [child.id, action.id])?.grownFrame ?? .null
                        XCTAssertFalse(next.contains { $0.frame.intersects(frame) }, "\(what): \(child.id)/\(action.id)")
                        XCTAssertLessThan(RadialLayout.distance(to: frame), innerEdge, "\(what): \(child.id)/\(action.id)")
                    }
                }
            }
        }
    }

    /// Short names and every action read whole at full size; a long name wraps to two lines;
    /// every line of every word lies inside its frame.
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
        XCTAssertEqual(long.word(["loadouts", "Morning research and writing"])?.fit.lines, ["Morning research", "and writing"])
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
    /// twenty, with or without Widgets. A long name fits its place (wrapping, then shrinking,
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

    /// The loadouts' arc, padding included, keeps clear of Capture's and Widgets' words: no point
    /// of either falls inside it.
    func testTheLoadoutsArcKeepsClearOfCaptureAndWidgets() {
        for count in 1...20 {
            for names in [Self.short, Self.long] {
            let layout = RadialLayout(tree: Self.tree(count, names))
            let what = "\(count) loadouts named like \(names[0])"
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
                    XCTAssertLessThanOrEqual(reach(layout, open: branch), 400 + (rows - 1) * 210, "\(what), \(branch)")
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
    /// out past where the loadouts start and round to the loadout, onto it, out past where its
    /// actions start and round to the action, onto it. Nothing on the way is previewed or
    /// applied: only the release does that.
    func testEveryActionIsReachedAlongItsPath() {
        everyLayout { layout, tree, what in
            guard let ring = layout.petal(["loadouts"])?.start, ring.isFinite else { return }
            for loadout in tree[0].children {
                guard let out = layout.petal(["loadouts", loadout.id])?.start else { return XCTFail(what) }
                for action in loadout.children {
                    let path = ["loadouts", loadout.id, action.id]
                    var points = [Self.middle(layout, ["loadouts"])]
                    points += Self.arc(from: 0, to: loadout.angle, radius: ring + 2)
                    points.append(Self.middle(layout, ["loadouts", loadout.id]))
                    points += Self.arc(from: loadout.angle, to: action.angle, radius: out + 2)
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

    /// The hint sits under every word showing, inside the field, on up to two lines inside its zone.
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

    // MARK: The field

    /// A few cases, every branch's field over the whole wheel's rectangle, built once.
    private static let fieldCases: [(layout: RadialLayout, what: String)] = {
        [(3, short), (10, long), (14, short)].map { count, names in
            (RadialLayout(tree: tree(count, names, allScreens: true)), "\(count) loadouts")
        } + [(RadialLayout(tree: tree(6, long), scale: 0.79), "6 loadouts at 0.79")]
    }()

    private static var fields: [String: (whole: RadialField, open: [[String]: RadialField])] = [:]

    private static func fields(_ layout: RadialLayout, _ what: String, reduced: Bool) -> (whole: RadialField, open: [[String]: RadialField]) {
        let key = "\(what)\(reduced ? ", reduced" : "")"
        if let cached = fields[key] { return cached }
        let whole = RadialField(layout: layout, reduced: reduced)
        var open: [[String]: RadialField] = [:]
        for branch in layout.branches {
            open[branch] = RadialField(shape: RadialField.Shape(layout: layout, open: branch, reduced: reduced), over: whole.support)
        }
        fields[key] = (whole, open)
        return (whole, open)
    }

    private static func samples(_ frame: CGRect) -> [CGPoint] {
        stride(from: frame.minX, through: frame.maxX, by: max(1, frame.width / 8)).flatMap { x in
            stride(from: frame.minY, through: frame.maxY, by: max(1, frame.height / 4)).map { CGPoint(x: x, y: $0) }
        }
    }

    /// Under every word showing (grown, as it is under the pointer) and the hint the blur is
    /// full, so no sharp desktop shows through there, and the tint is strong enough to read on.
    func testUnderEveryWordShowingTheBlurIsFullAndTheTintReads() {
        for (layout, what) in Self.fieldCases {
            for reduced in [false, true] {
                for (open, field) in Self.fields(layout, what, reduced: reduced).open {
                    for frame in RadialField.places(layout, open: open) {
                        for p in Self.samples(frame) {
                            XCTAssertGreaterThanOrEqual(field.blur(at: p), 1 - 1 / 255, "\(what), open \(open)\(reduced ? ", reduced" : "")")
                            XCTAssertGreaterThanOrEqual(field.tint(at: p), RadialField.readable, "\(what), open \(open)\(reduced ? ", reduced" : "")")
                        }
                    }
                }
            }
        }
    }

    /// Every branch's field covers the same rectangle as the whole wheel's, and is 0 at its
    /// edge; so the views keep their frames as branches open and nothing is cut off.
    func testEveryBranchsFieldFitsTheWholeWheelsRectangle() {
        for (layout, what) in Self.fieldCases {
            let (whole, open) = Self.fields(layout, what, reduced: false)
            XCTAssertTrue(whole.support.contains(layout.bounds), what)
            for (branch, field) in open {
                XCTAssertEqual(field.support, whole.support, "\(what), open \(branch)")
                XCTAssertEqual(field.blurImage.width, whole.blurImage.width, "\(what), open \(branch)")
                let s = field.support
                var edge: [CGPoint] = []
                for x in stride(from: s.minX, through: s.maxX, by: 8) { edge += [CGPoint(x: x, y: s.minY), CGPoint(x: x, y: s.maxY)] }
                for y in stride(from: s.minY, through: s.maxY, by: 8) { edge += [CGPoint(x: s.minX, y: y), CGPoint(x: s.maxX, y: y)] }
                for p in edge where field.blur(at: p) != 0 {
                    XCTFail("\(what), open \(branch): not 0 at the edge, \(p)")
                    break
                }
            }
        }
    }

    /// The blur's image, as the backdrop stretches it, is full (within one 8-bit step) over
    /// every word showing, the pixels around it included, since a stretched image blends its
    /// neighbouring pixels.
    func testTheBlurImageIsFullOverEveryWordShowing() {
        for (layout, what) in Self.fieldCases {
            for (open, field) in Self.fields(layout, what, reduced: false).open {
                let image = field.blurImage
                guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return XCTFail(what) }
                let step = field.support.width / CGFloat(image.width)
                for frame in RadialField.places(layout, open: open) {
                    let c0 = max(0, Int(((frame.minX - field.support.minX) / step).rounded(.down)) - 1)
                    let c1 = min(image.width - 1, Int(((frame.maxX - field.support.minX) / step).rounded(.up)) + 1)
                    let r0 = max(0, Int(((field.support.maxY - frame.maxY) / step).rounded(.down)) - 1)
                    let r1 = min(image.height - 1, Int(((field.support.maxY - frame.minY) / step).rounded(.up)) + 1)
                    var least: UInt8 = 255
                    for row in r0...r1 {
                        for column in c0...c1 { least = min(least, bytes[row * image.bytesPerRow + column * 4 + 3]) }
                    }
                    XCTAssertGreaterThanOrEqual(least, 254, "\(what), open \(open)")
                }
            }
        }
    }

    /// Both profiles fade to nothing with no step anywhere along a line out from the centre; the
    /// blur is full in the middle, and so is the tint, which is weaker toward the rim.
    func testTheFieldFadesToNothingWithoutAnEdge() {
        for (layout, what) in Self.fieldCases {
            for reduced in [false, true] {
                for (open, field) in Self.fields(layout, what, reduced: reduced).open {
                    XCTAssertEqual(field.blur(at: .zero), 1, accuracy: 0.001, what)
                    XCTAssertEqual(field.tint(at: .zero), 1, accuracy: 0.001, what)
                    let s = field.support
                    let reach = Double(hypot(max(-s.minX, s.maxX), max(-s.minY, s.maxY)))
                    for a in stride(from: 0.0, to: 2 * .pi, by: .pi / 18) {
                        let start = Double(field.shape.disc) * 0.5
                        var previous = field.shape.profiles(at: CGPoint(x: start * sin(a), y: start * cos(a)))
                        for r in stride(from: start + 2, through: reach, by: 2) {
                            let next = field.shape.profiles(at: CGPoint(x: r * sin(a), y: r * cos(a)))
                            if abs(next.blur - previous.blur) >= 0.08 || abs(next.tint - previous.tint) >= 0.08 {
                                XCTFail("\(what), open \(open): a step at \(Int(a * 180 / .pi))° r \(Int(r))")
                                break
                            }
                            previous = next
                        }
                    }
                }
            }
        }
    }

    /// The wheel's field as it opens is small: it reaches little past the top petals.
    func testTheFieldAsTheWheelOpensIsSmall() {
        let layout = RadialLayout(tree: Self.tree(10, Self.long))
        let shape = RadialField.Shape(layout: layout, open: [], reduced: false)
        let whole = RadialField.Shape(layout: layout, open: nil, reduced: false)
        XCTAssertLessThan(shape.extent.width, whole.extent.width * 0.75)
        XCTAssertEqual(shape.blur(at: CGPoint(x: 0, y: 300)), 0)
    }

    /// With Reduce transparency on, the field is a plain soft disc: both profiles depend on the
    /// distance from the centre only.
    func testWithReduceTransparencyTheFieldIsASoftDisc() {
        let layout = RadialLayout(tree: Self.tree(8, Self.long))
        let field = RadialField(layout: layout, reduced: true)
        for value in [field.blur, field.tint] as [(CGPoint) -> CGFloat] {
            for r in stride(from: 0.0, through: Double(field.support.width / 2), by: 9) {
                let values = stride(from: 0.0, to: 360, by: 15).map { degrees -> CGFloat in
                    let a = degrees * .pi / 180
                    return value(CGPoint(x: r * sin(a), y: r * cos(a)))
                }
                XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 0.001, "radius \(r)")
            }
        }
    }

    /// The blur is full a little past a lit word's glow, and the light under a hovered petal
    /// ends where the full blur around a lone word would: one reach decides all three.
    func testTheGlowTheBlurAndTheLightAgree() {
        XCTAssertGreaterThan(RadialField.pad, RadialWheelView.glowReach)
        XCTAssertEqual(RadialWheelView.lightReach, RadialField.pad)
    }

    /// Each image is its profile in black: the blur's alpha is the blur profile, the tint's the
    /// tint profile, whose strength is the tint view's darkness (`RadialField.darkness`).
    func testTheImagesAreTheProfiles() throws {
        let field = RadialField(layout: RadialLayout(tree: Self.tree(8, Self.long)), reduced: false)
        for (image, value) in [(field.blurImage, field.blur), (field.tintImage, field.tint)] as [(CGImage, (CGPoint) -> CGFloat)] {
            let rep = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(rep.pixelsWide) / field.support.width
            // (-250, -190) lies on the field's steepest fade, where the image's 4-point pixels
            // average a slope of about 0.06 across their width: a looser match there.
            for (p, accuracy) in [(CGPoint(x: 0, y: 0), 0.03), (CGPoint(x: 120, y: -80), 0.03), (CGPoint(x: -200, y: 150), 0.03),
                                  (CGPoint(x: 0, y: -200), 0.03), (CGPoint(x: 230, y: 160), 0.03), (CGPoint(x: -250, y: -190), 0.07)]
                where field.support.contains(p) {
                let pixel = try XCTUnwrap(rep.colorAt(x: Int((p.x - field.support.minX) * scale), y: Int((field.support.maxY - p.y) * scale)))
                XCTAssertEqual(pixel.alphaComponent, value(p), accuracy: CGFloat(accuracy), "\(p)")
                XCTAssertEqual(pixel.redComponent + pixel.greenComponent + pixel.blueComponent, 0, accuracy: 0.01, "black")
            }
        }
    }

    // MARK: The screen

    /// The wheel never outgrows the screen it opens on: on a 1024 by 640 display (a 13-inch at
    /// Larger Text, less the menu bar) or with a Dock at the bottom, with many loadouts and long
    /// names, and wherever the pointer is, every word that can show and the hint are on screen.
    func testTheWheelFitsTheScreenItOpensOn() {
        let screens = [CGRect(x: 0, y: 0, width: 1024, height: 616), CGRect(x: 0, y: 70, width: 1024, height: 546),
                       CGRect(x: 1024, y: -200, width: 1440, height: 875)]
        for visible in screens {
            for count in [3, 10, 22] {
                let tree = Self.tree(count, Self.long, allScreens: true)
                // Where the pointer is moves the wheel, not its size: laid out once, placed for each.
                let layout = RadialMenu.place(tree: tree, at: .zero, visibleFrame: visible).layout
                let room = visible.insetBy(dx: RadialMenu.screenMargin, dy: RadialMenu.screenMargin)
                XCTAssertLessThanOrEqual(layout.scale, 1)
                for pointer in [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.maxY),
                                CGPoint(x: visible.midX, y: visible.minY + 3), CGPoint(x: visible.midX, y: visible.midY)] {
                    let center = RadialMenu.centre(of: layout, at: pointer, room: room)
                    let words = layout.bounds.offsetBy(dx: center.x, dy: center.y)
                    XCTAssertTrue(visible.insetBy(dx: 1, dy: 1).contains(words), "\(count) loadouts at \(pointer) in \(visible): \(words)")
                }
            }
        }
        let roomy = RadialMenu.place(tree: Self.tree(8, Self.long), at: CGPoint(x: 900, y: 500),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1100))
        XCTAssertEqual(roomy.layout.scale, 1, "full size where it fits")
        XCTAssertEqual(roomy.center, CGPoint(x: 900, y: 500), "centred on the pointer where it fits")
    }
}
