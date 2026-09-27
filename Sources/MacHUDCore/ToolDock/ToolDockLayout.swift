import AppKit
import HUDKit

/// Where the tool dock and everything hanging off it go. Pure geometry in Cocoa screen
/// coordinates (origin bottom-left), so it is unit tested.
///
/// The strip itself is HUDKit's: `HUDDockStyle.standard` (at `iconSize`) measures it and
/// `HUDDockStyle.placement` lays it out. Buttons come in two groups, hover apps then
/// windowed apps, with a thin divider between them when both are present. At one of the
/// four edge positions the dock is a single row (left to right) or column (top to bottom)
/// centred on that edge. In a corner it is an L (`HUDDockLayout.lShape`): the hover group
/// runs along the vertical arm, starting in the corner, and the windowed group along the
/// horizontal arm, starting just past the corner with the divider in between. With one
/// group empty the L is just that group's arm.
struct ToolDockLayout: Equatable {
    /// Gap between the dock and the edge of the visible frame.
    static let margin: CGFloat = 6
    /// Gap between the dock and a panel revealed from it.
    static let panelGap: CGFloat = 8
    /// Diameter of the running indicator.
    static let dotSize: CGFloat = HUDDockStyle.standard.indicatorSize
    /// How far the icon under the pointer grows.
    static let magnification: CGFloat = HUDDockStyle.standard.magnification
    /// Points of an auto-hidden dock left on screen.
    static let hiddenPeek: CGFloat = 1

    typealias Placement = HUDDockPlacement

    var position: HUDDockPosition
    var iconSize: CGFloat

    init(position: HUDDockPosition, iconSize: CGFloat) {
        self.position = position
        self.iconSize = iconSize
    }

    /// The strip's look at this icon size.
    var style: HUDDockStyle { HUDDockStyle.standard.withItemSize(iconSize) }

    /// Space around the icons (10 pt for 44 pt icons); the indicator sits in it.
    var padding: CGFloat { style.padding }
    var spacing: CGFloat { style.spacing }
    /// Across an arm: 64 pt for 44 pt icons.
    var thickness: CGFloat { style.thickness }

    static var insets: NSEdgeInsets { NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin) }

    /// Length of a straight run of `groups` (counts), dividers between non-empty ones.
    func length(groups: [Int]) -> CGFloat { style.runLength(groups: groups) }

    // MARK: - On screen

    /// The dock at its position inside `visible`: the arms, every button, the dividers.
    /// `groups` is `[hover count, windowed count]`.
    func place(groups: [Int], visible: CGRect) -> Placement {
        let hover = groups.first ?? 0, windowed = groups.count > 1 ? groups[1] : 0
        return style.placement(groups: [hover, windowed], position: position, insets: Self.insets, in: visible)
    }

    /// The arms' lengths (vertical, horizontal) for `groups`, before clamping to the screen.
    func armLengths(groups: [Int]) -> (vertical: CGFloat, horizontal: CGFloat) {
        style.armLengths(groups: Array(groups.prefix(2)), position: position)
    }

    /// This layout with the icons shrunk (never grown) so every arm fits `visible`.
    func fitted(groups: [Int], visible: CGRect) -> ToolDockLayout {
        let span = CGSize(width: visible.width - 2 * Self.margin, height: visible.height - 2 * Self.margin)
        var l = self
        l.iconSize = style.fitted(groups: Array(groups.prefix(2)), position: position, span: span).itemSize
        return l
    }

    // MARK: - Buttons

    /// The running indicator's centre for a button: in the padding on the screen-edge side
    /// of its arm, as the Dock draws it.
    func dotCentre(for button: CGRect, edge: HUDEdge) -> CGPoint { style.indicatorCentre(for: button, edge: edge) }

    /// A button grown by `scale` away from its screen edge (its edge side stays put).
    static func magnified(_ button: CGRect, edge: HUDEdge, scale: CGFloat = ToolDockLayout.magnification) -> CGRect {
        HUDDockStyle.standard.magnified(button, edge: edge, scale: scale)
    }

    // MARK: - Auto-hide

    /// The edge an auto-hidden dock slides past: its own, or a corner's top/bottom edge.
    var hideEdge: HUDEdge { position.edges[0] }

    /// Where an auto-hidden dock waits: past `hideEdge` of `screen`, `hiddenPeek` showing.
    func hiddenFrame(_ dock: CGRect, screen: CGRect) -> CGRect {
        HUDParking.offScreenFrame(for: dock, edge: hideEdge, peek: Self.hiddenPeek, in: screen)
    }

    /// The strip along the screen edge that brings an auto-hidden dock back: the dock's
    /// span, a few points deep.
    func revealZone(_ dock: CGRect, screen: CGRect, depth: CGFloat = 4) -> CGRect {
        switch hideEdge {
        case .bottom: return CGRect(x: dock.minX, y: screen.minY, width: dock.width, height: depth)
        case .top: return CGRect(x: dock.minX, y: screen.maxY - depth, width: dock.width, height: depth)
        case .left: return CGRect(x: screen.minX, y: dock.minY, width: depth, height: dock.height)
        case .right: return CGRect(x: screen.maxX - depth, y: dock.minY, width: depth, height: dock.height)
        }
    }

    // MARK: - Panels next to the dock

    /// A panel of `size` sliding out of the button whose hit area is `slot` on an arm
    /// against `edge`, clear of every arm in `dock` (`HUDDockLayout.panelFrame(dockFrames:)`):
    /// in a corner it sits in the crook of the L, past the vertical arm and on the open side
    /// of the horizontal one. Shrunk only if the room left inside `visible` (less `margin`)
    /// is smaller than it, never slid over the dock.
    static func panelFrame(size: CGSize, slot: CGRect, edge: HUDEdge, dock: [CGRect], visible: CGRect) -> CGRect {
        let inner = visible.insetBy(dx: margin, dy: margin)
        return HUDDockLayout.panelFrame(size: size, anchor: slot, dockFrames: dock, from: edge, gap: panelGap, in: inner)
    }
}
