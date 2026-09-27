import Foundation
import CoreGraphics

/// Pure matching maths shared by the loadout engine: how well a window fills a
/// region, which of an app's windows a slot means, and what a captured window
/// becomes. Kept free of AppKit state so it can be unit tested.
enum WindowMatch {
    /// Intersection over union of two rects (0 = disjoint, 1 = identical).
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let i = Double(inter.width) * Double(inter.height)
        let union = Double(a.width) * Double(a.height) + Double(b.width) * Double(b.height) - i
        guard union > 0 else { return 0 }
        return i / union
    }

    /// Index of the frame that best fills `rect`, if it reaches `minimum` IoU.
    static func best(frames: [CGRect], in rect: CGRect, minimum: Double) -> (index: Int, iou: Double)? {
        var best: (index: Int, iou: Double)?
        for (i, f) in frames.enumerated() {
            let score = iou(f, rect)
            if score >= minimum, best == nil || score > best!.iou { best = (i, score) }
        }
        return best
    }

    /// `titleMatch` is a case-insensitive regular expression; an invalid pattern
    /// falls back to a substring test so a hand-written config still works.
    static func titleMatches(_ title: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return title.range(of: pattern, options: [.caseInsensitive]) != nil
        }
        return re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// A pattern that matches exactly this title and nothing else.
    static func titlePattern(for title: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: title) + "$"
    }

    /// One of an app's windows, reduced to the properties selection depends on.
    struct Candidate: Equatable {
        var title: String = ""
        var isMain: Bool = false
        var isStandard: Bool = true
        var isPlaceable: Bool = true
        var isMinimized: Bool = false
    }

    /// Which of an app's windows a slot means. Candidates are in front-to-back
    /// order. Non-standard windows (borderless portals and the like) stay usable
    /// but lose to a standard window when the app has one.
    static func choose(_ candidates: [Candidate], titleMatch: String?) -> Int? {
        var pool = candidates.indices.filter { candidates[$0].isPlaceable }
        guard !pool.isEmpty else { return nil }
        if pool.contains(where: { candidates[$0].isStandard }) {
            pool = pool.filter { candidates[$0].isStandard }
        }
        if let pattern = titleMatch, !pattern.isEmpty {
            let matching = pool.filter { titleMatches(candidates[$0].title, pattern: pattern) }
            return matching.first { !candidates[$0].isMinimized } ?? matching.first
        }
        if let main = pool.first(where: { candidates[$0].isMain && !candidates[$0].isMinimized }) { return main }
        return pool.first { !candidates[$0].isMinimized } ?? pool.first
    }

    /// What is known about a window found sitting in a region during capture.
    struct CaptureInput {
        var bundleID: String?
        var title: String = ""
        /// Set when the window is a MacHUD `WebPanel`.
        var builtinWebURL: String?
        /// Set when the window is a browser window MacHUD opened, or one whose
        /// page a browser was willing to name.
        var browserURL: String?
        var browserHost: WebHost = .chromeApp
        /// Set when the window belongs to one of MacHUD's other panels.
        var panelID: String?
        /// How many on-screen windows the owning app has.
        var appWindowCount: Int = 1
    }

    static func captureOccupant(_ input: CaptureInput) -> Occupant? {
        if let url = input.builtinWebURL { return .web(url: url, host: .builtin) }
        if let url = input.browserURL { return .web(url: url, host: input.browserHost) }
        if let id = input.panelID { return .panel(id: id) }
        guard let bundleID = input.bundleID, !bundleID.isEmpty else { return nil }
        let needsTitle = input.appWindowCount > 1 && !input.title.isEmpty
        return .app(bundleID: bundleID, titleMatch: needsTitle ? titlePattern(for: input.title) : nil)
    }
}
