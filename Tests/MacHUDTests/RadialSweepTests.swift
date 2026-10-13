import AppKit
import XCTest
@testable import MacHUDCore

/// Straight pointer moves over many wheels: from the centre, between loadouts, from a loadout
/// to each of its actions and between them, back onto a loadout's own name, and to and among
/// Capture's, Park's and Widgets' actions, for 1 to 20 loadouts with short, long, lengthening and
/// mixed names, with and without Widgets. Each move must end on its target with nothing else
/// opened on the way that would stop it; the failures are counted by kind.
@MainActor
final class RadialSweepTests: XCTestCase {
    static let counts = [1, 2, 4, 5, 6, 9, 10, 14, 15, 19, 20]

    static let lengthening: [String] = {
        let words = ["Quarterly", "planning", "review", "with", "the", "design", "and", "research", "team"]
        return (1...20).map { k in words.prefix(min(k, words.count)).joined(separator: " ") + (k > words.count ? " \(k)" : "") }
    }()

    static let mixed: [String] = zip(RadialLayoutTests.short, RadialLayoutTests.long).flatMap { [$0, $1] }

    static let names: [(String, [String])] = [("short", RadialLayoutTests.short), ("long", RadialLayoutTests.long),
                                              ("lengthening", lengthening), ("mixed", mixed)]

    /// The pointer going in a straight line from `a` to `b` (wheel coordinates) in small steps,
    /// starting with `open` selected; the path selected at the end.
    static func walk(_ layout: RadialLayout, from a: CGPoint, to b: CGPoint, open: [String]) -> [String] {
        var selection = open
        let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            selection = layout.selection(at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), open: selection)
        }
        return selection
    }

    static func middle(_ layout: RadialLayout, _ path: [String]) -> CGPoint? {
        layout.word(path).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }

    func testStraightMovesReachWhatTheyAimAt() {
        var failures: [String: Int] = [:]
        var examples: [String: String] = [:]
        var moves = 0
        for count in Self.counts {
            for (label, names) in Self.names {
                for widgets in [true, false] {
                    let tree = RadialLayoutTests.tree(count, names, widgets: widgets ? .init() : nil)
                    let layout = RadialLayout(tree: tree)
                    let what = "\(count) \(label)\(widgets ? "" : ", no widgets")"
                    func check(_ kind: String, from start: CGPoint?, _ open: [String], to target: [String], at end: CGPoint? = nil) {
                        guard let start, let end = end ?? Self.middle(layout, target) else { return }
                        moves += 1
                        let reached = Self.walk(layout, from: start, to: end, open: open)
                        guard reached != target else { return }
                        failures[kind, default: 0] += 1
                        if examples[kind] == nil {
                            examples[kind] = "\(what): \(open.joined(separator: "/")) → \(target.joined(separator: "/")) reached \(reached.joined(separator: "/"))"
                        }
                    }
                    let loadouts = tree[0].children
                    // From the centre to each top petal, and on to the actions of those that have them;
                    // to the loadouts within 45° of straight up and on to their Apply.
                    for top in tree {
                        check("centre → top petal", from: .zero, [], to: [top.id])
                        guard top.kind != .loadouts else { continue }
                        for action in top.children { check("centre → tool action", from: .zero, [], to: [top.id, action.id]) }
                    }
                    for loadout in loadouts where abs(RadialGeometry.difference(loadout.angle, 0)) < .pi / 4 {
                        check("centre → loadout's Apply", from: .zero, [], to: ["loadouts", loadout.id, "apply"])
                    }
                    // From Apply Loadout to each loadout and to Capture, Park and Widgets.
                    let apply = Self.middle(layout, ["loadouts"])
                    for loadout in loadouts { check("Apply Loadout → loadout", from: apply, ["loadouts"], to: ["loadouts", loadout.id]) }
                    for top in tree.dropFirst() { check("Apply Loadout → tool", from: apply, ["loadouts"], to: [top.id]) }
                    // From each branch: to each of its actions, between them and back onto its name;
                    // from a loadout to every other loadout.
                    let branches = loadouts.map { ["loadouts", $0.id] } + tree.dropFirst().map { [$0.id] }
                    for branch in branches {
                        guard let node = RadialMenu.node(at: branch, in: tree) else { continue }
                        let own = Self.middle(layout, branch)
                        for action in node.children {
                            let path = branch + [action.id]
                            check("branch → its action", from: own, branch, to: path)
                            for other in node.children where other.id != action.id {
                                check("action → its sibling", from: Self.middle(layout, path), path, to: branch + [other.id])
                            }
                            check("action → its branch's name", from: Self.middle(layout, path), path, to: branch)
                            check("action → centre", from: Self.middle(layout, path), path, to: [], at: .zero)
                        }
                        guard branch.count == 2 else { continue }
                        for other in loadouts where other.id != branch[1] {
                            check("loadout → loadout", from: own, branch, to: ["loadouts", other.id])
                        }
                    }
                }
            }
        }
        let total = failures.values.reduce(0, +)
        let summary = failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value) (\(examples[$0.key] ?? ""))" }.joined(separator: "\n")
        print("Wheel sweep: \(moves) moves, \(total) failures\n\(summary)")
        XCTAssertEqual(total, 0, "\(total) of \(moves) straight moves miss:\n\(summary)")
    }
}
