import AppKit
import HUDKit

/// The orb's shape at one point of the morph between the resting orb and the dictation
/// waveform body, in the orb window's top-down coordinates.
struct OrbShape: Equatable {
    var size: CGSize
    /// Gap between the anchor edge (notch or menu bar) and the top of the shape.
    var topOffset: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
}

/// Geometry for the notch orb and its card. Pure, so the morph and anchoring are testable
/// without a display. The waveform body matches SpeakFree's notch treatment
/// (`OverlayLayout.notchBodyPath`, `RecordingOverlay.drawNotchBody`): black, never narrower
/// than the camera housing, square top corners when it is exactly the housing's width so it
/// reads as the notch extending downward.
enum OrbLayout {
    static let orbDiameter: CGFloat = 22
    static let orbTopGap: CGFloat = 5
    /// Agent listening grows the orb by up to this fraction of its diameter at full level.
    static let pulseMax: CGFloat = 0.3

    static let waveformHeight: CGFloat = 32
    static let waveformMinWidth: CGFloat = 150
    static let waveformBottomRadius: CGFloat = 14
    static let waveformTopRadius: CGFloat = 8

    static let barCount = 16
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 3
    static let barMaxHeight: CGFloat = 20
    static let barMinHeight: CGFloat = 1
    static let recordDotRadius: CGFloat = 4
    static let recordDotGap: CGFloat = 8

    static let cardWidth: CGFloat = 340
    static let cardMaxHeight: CGFloat = 380
    static let cardGap: CGFloat = 6
    static let cardCornerRadius: CGFloat = 16

    static func waveformWidth(geometry: HUDNotchGeometry) -> CGFloat {
        max(waveformMinWidth, geometry.hasNotch ? geometry.notchWidth ?? 0 : 0)
    }

    /// The shape at `stretch` (0 = resting orb, 1 = waveform body).
    static func shape(stretch: CGFloat, geometry: HUDNotchGeometry) -> OrbShape {
        let t = min(max(stretch, 0), 1)
        let bodyWidth = waveformWidth(geometry: geometry)
        let flush = geometry.hasNotch && bodyWidth <= (geometry.notchWidth ?? 0) + 1
        let width = lerp(orbDiameter, bodyWidth, t)
        let height = lerp(orbDiameter, waveformHeight, t)
        let bottom = min(lerp(orbDiameter / 2, waveformBottomRadius, t), height / 2)
        let top = min(lerp(orbDiameter / 2, flush ? 0 : waveformTopRadius, t), height / 2)
        return OrbShape(size: CGSize(width: width, height: height), topOffset: lerp(orbTopGap, 0, t),
                        topRadius: top, bottomRadius: bottom)
    }

    /// Room the pulse needs beyond the shape; fades out as the orb stretches.
    static func pulseRoom(stretch: CGFloat) -> CGFloat {
        orbDiameter * pulseMax * (1 - min(max(stretch, 0), 1))
    }

    /// The orb window's size: the shape plus room for the pulse, which scales about the
    /// shape's center. The window follows the shape so the empty space beside a resting orb
    /// never takes clicks meant for the window underneath.
    static func windowSize(stretch: CGFloat, geometry: HUDNotchGeometry) -> CGSize {
        let s = shape(stretch: stretch, geometry: geometry)
        let room = pulseRoom(stretch: stretch)
        return CGSize(width: ceil(s.size.width + room), height: ceil(s.topOffset + s.size.height + room / 2))
    }

    /// The card's frame in screen coordinates: centered under the resting orb, height capped.
    static func cardFrame(size: CGSize, geometry: HUDNotchGeometry) -> CGRect {
        let height = min(size.height, cardMaxHeight)
        let top = geometry.topAnchorY - orbTopGap - orbDiameter - cardGap
        var x = geometry.screenFrame.midX - size.width / 2
        x = min(max(x, geometry.visibleFrame.minX), geometry.visibleFrame.maxX - size.width)
        return CGRect(x: x, y: top - height, width: size.width, height: height)
    }

    /// Where the card grows from: a sliver at its top edge, as wide as the orb.
    static func collapsed(_ frame: CGRect) -> CGRect {
        let width = min(frame.width, orbDiameter * 2)
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - 1, width: width, height: 1)
    }

    /// Bar heights for levels (0...1, oldest first), with SpeakFree's edge softening so the
    /// body's ends taper.
    static func barHeights(_ levels: [Double]) -> [CGFloat] {
        levels.enumerated().map { i, level in
            let edge = min(i, levels.count - 1 - i)
            let clamp: CGFloat = edge == 0 ? 0.8 : edge == 1 ? 0.88 : edge == 2 ? 0.95 : 1
            let l = CGFloat(min(max(level, 0), 1)) * clamp
            return barMinHeight + (barMaxHeight - barMinHeight) * l
        }
    }

    /// The shape as a path in a top-down (flipped) rect.
    static func path(in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        path.move(to: CGPoint(x: minX, y: minY + topRadius))
        if topRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + topRadius, y: minY), radius: topRadius)
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + topRadius), radius: topRadius)
        } else {
            path.addLine(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: minY))
        }
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - bottomRadius, y: maxY), radius: bottomRadius)
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - bottomRadius), radius: bottomRadius)
        path.closeSubpath()
        return path
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
