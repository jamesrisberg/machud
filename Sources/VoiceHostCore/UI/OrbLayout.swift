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
    /// The armed orb (fn gesture undecided) is this fraction larger than the resting one.
    static let armedSwell: CGFloat = 0.06

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
    /// shape's center, and for the resting float below it. The window follows the shape so the
    /// empty space beside a resting orb never takes clicks meant for the window underneath.
    static func windowSize(stretch: CGFloat, geometry: HUDNotchGeometry) -> CGSize {
        let s = shape(stretch: stretch, geometry: geometry)
        let room = pulseRoom(stretch: stretch)
        return CGSize(width: ceil(s.size.width + room),
                      height: ceil(s.topOffset + s.size.height + max(room / 2, bobRoom(stretch: stretch))))
    }

    // MARK: Resting float

    /// How far the resting orb drifts down from its rest position. It only ever drifts down,
    /// so it never rises into the camera housing or the menu bar.
    static let bobAmplitude: CGFloat = 3
    /// One slow down-and-back cycle of the float, in seconds.
    static let bobPeriod: Double = 3.6
    /// One breath of the resting glow, in seconds (a little longer than the float, so the two
    /// do not lock step).
    static let breathPeriod: Double = 4.8

    /// The float's downward offset at `phase` seconds: 0 at rest, `bobAmplitude` at the bottom,
    /// eased in and out (a cosine).
    static func bob(phase: Double) -> CGFloat {
        bobAmplitude * CGFloat(1 - cos(2 * .pi * phase / bobPeriod)) / 2
    }

    /// The glow's breath at `phase` seconds, 0...1, eased in and out.
    static func breath(phase: Double) -> CGFloat {
        CGFloat(1 - cos(2 * .pi * phase / breathPeriod)) / 2
    }

    /// Room the float needs below the shape; none once the orb stretches into the waveform.
    static func bobRoom(stretch: CGFloat) -> CGFloat {
        bobAmplitude * (1 - min(max(stretch, 0), 1))
    }

    /// The resting orb in screen coordinates, `bob` points below its rest position.
    static func orbFrame(geometry: HUDNotchGeometry, bob: CGFloat = 0) -> CGRect {
        let midX = geometry.anchorFrame(for: CGSize(width: orbDiameter, height: orbDiameter)).midX
        return CGRect(x: midX - orbDiameter / 2, y: geometry.topAnchorY - orbTopGap - bob - orbDiameter,
                      width: orbDiameter, height: orbDiameter)
    }

    /// The card's frame in screen coordinates: centered under the resting orb, height capped.
    static func cardFrame(size: CGSize, geometry: HUDNotchGeometry) -> CGRect {
        let height = min(size.height, cardMaxHeight)
        let top = cardTop(geometry: geometry)
        var x = geometry.screenFrame.midX - size.width / 2
        x = min(max(x, geometry.visibleFrame.minX), geometry.visibleFrame.maxX - size.width)
        return CGRect(x: x, y: top - height, width: size.width, height: height)
    }

    // MARK: Conversation

    /// The pinned card: the whole conversation, scrollable, where the card hangs.
    static let pinnedWidth: CGFloat = 400
    static let pinnedMinHeight: CGFloat = 120
    /// The pinned card is never taller than this, nor more than `pinnedScreenFraction` of the
    /// visible screen.
    static let pinnedMaxHeightCap: CGFloat = 560
    static let pinnedScreenFraction: CGFloat = 0.6
    /// The expanded card: about 640 points wide and 70% of the screen's height.
    static let expandedWidth: CGFloat = 640
    static let expandedHeightFraction: CGFloat = 0.7
    /// The least room kept between the expanded card and the screen's edges.
    static let expandedMargin: CGFloat = 16

    /// The top of the card (and of the pinned and expanded conversation) in screen coordinates.
    static func cardTop(geometry: HUDNotchGeometry) -> CGFloat {
        geometry.topAnchorY - orbTopGap - orbDiameter - cardGap
    }

    static func pinnedMaxHeight(geometry: HUDNotchGeometry) -> CGFloat {
        let room = cardTop(geometry: geometry) - geometry.visibleFrame.minY - expandedMargin
        return max(pinnedMinHeight, floor(min(pinnedMaxHeightCap, geometry.visibleFrame.height * pinnedScreenFraction, room)))
    }

    /// The pinned conversation for content `contentHeight` tall: centered under the orb, its
    /// top where the card's is, between `pinnedMinHeight` and `pinnedMaxHeight`.
    static func pinnedFrame(contentHeight: CGFloat, geometry: HUDNotchGeometry) -> CGRect {
        let height = min(max(ceil(contentHeight), pinnedMinHeight), pinnedMaxHeight(geometry: geometry))
        return centeredUnderOrb(size: CGSize(width: pinnedWidth, height: height), geometry: geometry)
    }

    /// The expanded conversation: centered under the notch, its top where the card's is, as
    /// large as `expandedWidth` × `expandedHeightFraction` of the screen while that fits.
    static func expandedFrame(geometry: HUDNotchGeometry) -> CGRect {
        let width = min(expandedWidth, geometry.visibleFrame.width - expandedMargin * 2)
        let room = cardTop(geometry: geometry) - geometry.visibleFrame.minY - expandedMargin
        let height = min((geometry.screenFrame.height * expandedHeightFraction).rounded(), room)
        return centeredUnderOrb(size: CGSize(width: width, height: height), geometry: geometry)
    }

    private static func centeredUnderOrb(size: CGSize, geometry: HUDNotchGeometry) -> CGRect {
        let top = cardTop(geometry: geometry)
        var x = geometry.screenFrame.midX - size.width / 2
        x = min(max(x, geometry.visibleFrame.minX), geometry.visibleFrame.maxX - size.width)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: Card grow

    /// Seconds for the card to grow out of the orb, and to fold back into it.
    static let cardOpenDuration: Double = 0.32
    static let cardCloseDuration: Double = 0.22
    /// Grow progress after which the card's content fades in (the shape is mostly open).
    static let contentFadeStart: CGFloat = 0.6

    /// Cubic ease in and out, so the collapse is the open played backwards.
    static func growEase(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The card's shape at grow progress `t` (0 = the orb, 1 = the card), in screen
    /// coordinates: its top edge travels from the orb's top down to the card's, its width and
    /// height open around the orb's center line, and its corners ease from a circle to the
    /// card's radius.
    static func growShape(progress t: CGFloat, orb: CGRect, card: CGRect) -> (rect: CGRect, radius: CGFloat) {
        let e = growEase(t)
        let width = lerp(orb.width, card.width, e)
        let height = lerp(orb.height, card.height, e)
        let top = lerp(orb.maxY, card.maxY, e)
        let midX = lerp(orb.midX, card.midX, e)
        let rect = CGRect(x: midX - width / 2, y: top - height, width: width, height: height)
        let radius = min(lerp(orb.width / 2, cardRadius(card.size), e), width / 2, height / 2)
        return (rect, radius)
    }

    /// The card's corner radius: `cardCornerRadius`, or a pill's for a one-line message.
    static func cardRadius(_ size: CGSize) -> CGFloat {
        min(cardCornerRadius, size.height / 2)
    }

    /// The card window's frame at grow progress `t`: the card and the orb together while the
    /// shape travels between them, only the card once it is open, so nothing but the card
    /// takes clicks.
    static func growWindowFrame(progress t: CGFloat, orb: CGRect, card: CGRect) -> CGRect {
        t >= 1 ? card : card.union(orb)
    }

    /// The card content's opacity at grow progress `t`: none until the shape is mostly open.
    static func contentAlpha(progress t: CGFloat) -> CGFloat {
        min(max((t - contentFadeStart) / (1 - contentFadeStart), 0), 1)
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

    /// The shape as a path in a top-down (flipped) rect: `HUDNotchGeometry`'s notch-body path
    /// (the same shape SpeakFree's `OverlayLayout.notchBodyPath` draws), which the orb also uses
    /// for its round resting state and every point of the morph, not only the flush waveform.
    static func path(in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        HUDNotchGeometry.bodyPath(in: rect, topRadius: topRadius, bottomRadius: bottomRadius)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
