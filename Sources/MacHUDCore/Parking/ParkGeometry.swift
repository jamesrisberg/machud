import CoreGraphics
import HUDKit

/// Where a parked window goes. Pure, so the multi-display cases are unit tested.
/// All rects are AppKit screen coordinates (origin bottom-left).
enum ParkGeometry {
    struct Result: Equatable {
        var frame: CGRect
        /// The edge borders another display, so the window was pushed past the far side
        /// of the whole desktop on that axis instead (and shows no peek).
        var crossedDisplay: Bool
    }

    /// `rest` pushed past `edge` of `screen`, leaving `peek` points showing. When another
    /// display sits beyond that edge the window would land on it, so it goes past the
    /// outermost display in that direction instead.
    static func parkedFrame(rest: CGRect, edge: HUDEdge, peek: CGFloat, screen: CGRect,
                            screens: [CGRect]) -> Result {
        let local = HUDParking.offScreenFrame(for: rest, edge: edge, peek: peek, in: screen)
        let others = screens.filter { $0 != screen }
        guard others.contains(where: { ZOrder.overlaps($0, local, tolerance: 0) }) else {
            return Result(frame: local, crossedDisplay: false)
        }
        var f = HUDParking.offScreenFrame(for: rest, edge: edge, peek: 0, in: screen)
        let all = screens.contains(screen) ? screens : screens + [screen]
        switch edge {
        case .left:
            let band = all.filter { $0.maxY > f.minY && $0.minY < f.maxY }
            f.origin.x = (band.map(\.minX).min() ?? screen.minX) - f.width
        case .right:
            let band = all.filter { $0.maxY > f.minY && $0.minY < f.maxY }
            f.origin.x = band.map(\.maxX).max() ?? screen.maxX
        case .bottom:
            let band = all.filter { $0.maxX > f.minX && $0.minX < f.maxX }
            f.origin.y = (band.map(\.minY).min() ?? screen.minY) - f.height
        case .top:
            let band = all.filter { $0.maxX > f.minX && $0.minX < f.maxX }
            f.origin.y = band.map(\.maxY).max() ?? screen.maxY
        }
        return Result(frame: f, crossedDisplay: true)
    }

    /// How many points of `frame` remain visible along `edge`'s axis on any display:
    /// 0 when fully hidden. Records the sliver macOS keeps when it refuses to let a
    /// window go further.
    static func visibleSliver(of frame: CGRect, edge: HUDEdge, screens: [CGRect]) -> CGFloat {
        screens.map { s -> CGFloat in
            let i = s.intersection(frame)
            guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
            return edge == .left || edge == .right ? i.width : i.height
        }.max() ?? 0
    }

    /// The edge of `screen` nearest `frame` (the default when a park names none).
    /// `allowTop` false skips the top edge: macOS keeps other apps' title bars below the
    /// menu bar, so their windows cannot be hidden there.
    static func nearestEdge(for frame: CGRect, in screen: CGRect, allowTop: Bool = true) -> HUDEdge {
        let distances: [(HUDEdge, CGFloat)] = [
            (.left, frame.midX - screen.minX), (.right, screen.maxX - frame.midX),
            (.bottom, frame.midY - screen.minY), (.top, screen.maxY - frame.midY),
        ]
        return distances.filter { allowTop || $0.0 != .top }.min { $0.1 < $1.1 }!.0
    }

    /// Where the orb for `edge` sits by default: against that edge of `visible`, centred
    /// on the parked windows' rest frames along it, and kept inside `visible`.
    static func defaultOrbOrigin(edge: HUDEdge, restUnion: CGRect, visible: CGRect, size: CGFloat,
                                 inset: CGFloat = 6) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX + inset), visible.maxX - size - inset) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY + inset), visible.maxY - size - inset) }
        let midY = restUnion.isNull ? visible.midY : restUnion.midY
        let midX = restUnion.isNull ? visible.midX : restUnion.midX
        switch edge {
        case .left: return CGPoint(x: visible.minX + inset, y: clampY(midY - size / 2))
        case .right: return CGPoint(x: visible.maxX - size - inset, y: clampY(midY - size / 2))
        case .bottom: return CGPoint(x: clampX(midX - size / 2), y: visible.minY + inset)
        case .top: return CGPoint(x: clampX(midX - size / 2), y: visible.maxY - size - inset)
        }
    }
}
