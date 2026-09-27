import CoreGraphics

/// Stacking order for slots. Pure, so the ordering rules are unit tested.
enum ZOrder {
    /// Rects that share more than a hairline: windows that merely touch (a gap of zero
    /// between regions) do not stack.
    static func overlaps(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > tolerance && i.height > tolerance
    }

    static func overlaps(_ a: FractionRect, _ b: FractionRect) -> Bool {
        let ix = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
        let iy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        return ix > 1e-6 && iy > 1e-6
    }

    /// z for windows listed front to back (the window server's order): 0 for a window
    /// nothing overlaps or that is behind everything it overlaps, otherwise one more
    /// than the highest z of the overlapping windows behind it. Raising in ascending z
    /// reproduces the captured order.
    static func captured(frontToBack frames: [CGRect]) -> [Int] {
        var z = Array(repeating: 0, count: frames.count)
        for i in frames.indices.reversed() {
            for j in frames.index(after: i)..<frames.endIndex where overlaps(frames[i], frames[j]) {
                z[i] = max(z[i], z[j] + 1)
            }
        }
        return z
    }

    /// Indices of `zs` in the order to raise them: ascending z, ties in list order.
    static func raiseOrder(_ zs: [Int]) -> [Int] {
        zs.indices.sorted { zs[$0] != zs[$1] ? zs[$0] < zs[$1] : $0 < $1 }
    }

    /// True when raising is needed at all: a loadout with no z anywhere behaves as before.
    static func isStacked(_ zs: [Int]) -> Bool { zs.contains { $0 != 0 } }

    /// The z `id` should take to move one step up (or down) past the regions it overlaps.
    /// nil when it is already frontmost (or backmost) among them.
    static func bumped(_ id: String, up: Bool, rects: [String: FractionRect], z: [String: Int]) -> Int? {
        guard let mine = rects[id] else { return nil }
        let current = z[id] ?? 0
        let others = rects.filter { $0.key != id && overlaps($0.value, mine) }.map { z[$0.key] ?? 0 }
        if up {
            guard let next = others.filter({ $0 >= current }).min() else { return nil }
            return next + 1
        }
        guard let next = others.filter({ $0 <= current }).max() else { return nil }
        return next - 1
    }
}
