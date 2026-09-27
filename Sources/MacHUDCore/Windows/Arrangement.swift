import AppKit

/// Turns the windows on a screen into a layout (one grid-snapped region per
/// window) plus the loadout that fills it. Pure maths, so it is testable.
enum Arrangement {
    struct Input {
        var frame: CGRect          // Cocoa screen coordinates
        var name: String           // region name candidate (app name)
    }

    struct Placed {
        var region: Region
        var inputIndex: Int
    }

    /// The region rect maths from `LoadoutEngine.regionRect`, inverted: which
    /// fraction rect would produce `rect` on this visible frame with this gap.
    static func fraction(of rect: CGRect, visible: CGRect, gap: CGFloat) -> FractionRect {
        let inset = visible.insetBy(dx: gap / 2, dy: gap / 2)
        let outer = rect.insetBy(dx: -gap / 2, dy: -gap / 2)
        guard inset.width > 0, inset.height > 0 else { return FractionRect(x: 0, y: 0, w: 1, h: 1) }
        return FractionRect(
            x: Double((outer.minX - inset.minX) / inset.width),
            y: Double((inset.maxY - outer.maxY) / inset.height),
            w: Double(outer.width / inset.width),
            h: Double(outer.height / inset.height))
    }

    /// Snap a fraction rect's edges to the grid and keep it inside the screen,
    /// at least one cell in each direction.
    static func snap(_ f: FractionRect, grid: GridSize) -> FractionRect {
        let cols = Double(max(grid.cols, 1)), rows = Double(max(grid.rows, 1))
        func cell(_ v: Double, _ n: Double) -> Double { (v * n).rounded() / n }
        var left = min(max(cell(f.x, cols), 0), 1)
        var top = min(max(cell(f.y, rows), 0), 1)
        var right = min(max(cell(f.x + f.w, cols), 0), 1)
        var bottom = min(max(cell(f.y + f.h, rows), 0), 1)
        if right - left < 1 / cols { right = min(left + 1 / cols, 1); left = right - 1 / cols }
        if bottom - top < 1 / rows { bottom = min(top + 1 / rows, 1); top = bottom - 1 / rows }
        left = max(left, 0); top = max(top, 0)
        return FractionRect(x: left, y: top, w: right - left, h: bottom - top)
    }

    /// Keep a captured rect inside the screen, to the nearest millionth so the JSON stays
    /// readable; a window's frame round-trips to within a point.
    static func exact(_ f: FractionRect) -> FractionRect {
        func r(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
        let left = min(max(r(f.x), 0), 1), top = min(max(r(f.y), 0), 1)
        let right = min(max(r(f.x + f.w), left), 1), bottom = min(max(r(f.y + f.h), top), 1)
        return FractionRect(x: left, y: top, w: right - left, h: bottom - top)
    }

    /// Build regions for `inputs`. A region of `existing` whose rect overlaps a
    /// captured window rect by IoU ≥ `reuse` keeps its id, name and hit zone, so
    /// hand-tuned layouts survive a recapture. Overlapping windows each get their
    /// own region; stacking is deliberate.
    static func regions(for inputs: [Input], visible: CGRect, gap: CGFloat, grid: GridSize,
                        existing: [Region], reuse: Double = 0.6) -> [Placed] {
        var out: [Placed] = []
        var usedExisting = Set<String>()
        var usedNames = Set<String>()
        for (i, input) in inputs.enumerated() {
            // Exact, not grid-snapped: snapping moved each edge up to half a cell, which
            // turned windows overlapping by less than that into neighbours (and resized
            // every window on apply). The editor snaps a region once it is edited.
            let snapped = exact(fraction(of: input.frame, visible: visible, gap: gap))
            var region: Region
            if let match = existing
                .filter({ $0.id != nil && !usedExisting.contains($0.id!) })
                .map({ ($0, iou($0.frame, snapped)) })
                .filter({ $0.1 >= reuse })
                .max(by: { $0.1 < $1.1 })?.0 {
                usedExisting.insert(match.id!)
                region = match
                region.x = snapped.x; region.y = snapped.y; region.w = snapped.w; region.h = snapped.h
                if let hit = region.hit, containment(of: hit, in: snapped) < 0.5 { region.hit = nil }
            } else {
                region = Region(id: UUID().uuidString.lowercased(), name: nil,
                                x: snapped.x, y: snapped.y, w: snapped.w, h: snapped.h, hit: nil)
            }
            let base = region.name ?? (input.name.isEmpty ? "Window" : input.name)
            var name = base
            var n = 2
            while usedNames.contains(name) { name = "\(base) \(n)"; n += 1 }
            usedNames.insert(name)
            region.name = name
            out.append(Placed(region: region, inputIndex: i))
        }
        return out
    }

    /// The layout name for one pass of a capture: the loadout's name on its
    /// own for a single screen, qualified by display (and desktop) otherwise.
    static func layoutName(_ base: String, screen: String?, desktop: Int?) -> String {
        var name = base
        if let screen, !screen.isEmpty { name += " · \(screen)" }
        if let desktop { name += " · Desktop \(desktop)" }
        return name
    }

    /// Drop from each desktop pass the windows an earlier pass already
    /// captured: an app set to "all desktops" shows up on every one of them and
    /// belongs to the first desktop it was seen on.
    static func firstSeen<T>(_ passes: [[T]], number: (T) -> Int) -> [[T]] {
        var seen = Set<Int>()
        return passes.map { pass in
            pass.filter { seen.insert(number($0)).inserted }
        }
    }

    /// Fraction of `a`'s area that lies inside `b`.
    static func containment(of a: FractionRect, in b: FractionRect) -> Double {
        let ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
        let iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
        let area = a.w * a.h
        return area > 0 ? ix * iy / area : 0
    }

    static func iou(_ a: FractionRect, _ b: FractionRect) -> Double {
        let ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
        let iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
        let inter = ix * iy
        let union = a.w * a.h + b.w * b.h - inter
        return union > 0 ? inter / union : 0
    }
}
