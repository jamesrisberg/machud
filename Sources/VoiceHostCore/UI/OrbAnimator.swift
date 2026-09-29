import Foundation

/// The orb's continuous values between renders: the morph position, the smoothed input level,
/// how much of the resting float is on, and a free-running phase for spin, breathe, the
/// spinner and the float. Pure; the presenter advances it from a display timer while anything
/// moves.
struct OrbAnimator: Equatable {
    /// 0 = resting orb, 1 = waveform body.
    private(set) var stretch: CGFloat
    /// Smoothed input level, 0...1.
    private(set) var level: CGFloat = 0
    /// How much of the resting float applies, 0...1: eases in when the orb rests and out when
    /// anything else takes over, so the orb never jumps back to its rest position.
    private(set) var float: CGFloat
    /// Seconds of running motion; frozen under Reduce Motion.
    private(set) var phase: Double = 0
    /// How much of the armed look applies, 0...1: it eases in while the fn gesture is
    /// undecided and out as the orb commits, so the swell, ring and neutral tint hand over to
    /// the waveform or the agent's pulse without a jump.
    private(set) var armed: CGFloat = 0

    /// Rate of the morph's exponential ease, per second.
    static let stretchRate: Double = 11
    /// Rate of the float's ease in and out, per second.
    static let floatRate: Double = 4
    /// Rate of the armed look's ease in and out, per second.
    static let armedRate: Double = 14
    static let settleEpsilon: CGFloat = 0.004

    init(stretch: CGFloat = 0, float: CGFloat = 0) {
        self.stretch = stretch
        self.float = float
    }

    /// The orb's downward drift now: the float's cycle scaled by how much of it is on.
    var bobOffset: CGFloat { OrbLayout.bob(phase: phase) * float }

    /// The float runs while the orb rests with nothing under it (no card, no message).
    static func floatTarget(for scene: OrbScene, reduceMotion: Bool) -> CGFloat {
        scene.motion == .idle && scene.card == nil && scene.errorMessage == nil && !reduceMotion ? 1 : 0
    }

    /// `other` with the morph pinned at `stretch` and the armed look at `armed` (snapshots of
    /// the in-between frames).
    init(stretch: CGFloat? = nil, armed: CGFloat? = nil, copying other: OrbAnimator) {
        self = other
        if let stretch { self.stretch = stretch }
        if let armed { self.armed = armed }
    }

    static func armedTarget(for scene: OrbScene) -> CGFloat { scene.motion == .armed ? 1 : 0 }

    static func target(for scene: OrbScene) -> CGFloat { scene.form == .waveform ? 1 : 0 }

    mutating func advance(dt: Double, scene: OrbScene, level input: Double, reduceMotion: Bool) {
        let target = Self.target(for: scene)
        if reduceMotion {
            stretch = target
        } else {
            stretch += (target - stretch) * CGFloat(1 - exp(-dt * Self.stretchRate))
            if abs(target - stretch) < Self.settleEpsilon { stretch = target }
        }
        // Fast attack, gentler release (SpeakFree's bars use the same shape).
        let goal = CGFloat(min(max(input, 0), 1))
        let rate: Double = goal > level ? 50 : 12
        level += (goal - level) * CGFloat(1 - exp(-dt * rate))
        let floatGoal = Self.floatTarget(for: scene, reduceMotion: reduceMotion)
        if reduceMotion {
            float = floatGoal
        } else {
            float += (floatGoal - float) * CGFloat(1 - exp(-dt * Self.floatRate))
            if abs(floatGoal - float) < Self.settleEpsilon { float = floatGoal }
        }
        let armedGoal = Self.armedTarget(for: scene)
        if reduceMotion {
            armed = armedGoal
        } else {
            armed += (armedGoal - armed) * CGFloat(1 - exp(-dt * Self.armedRate))
            if abs(armedGoal - armed) < Self.settleEpsilon { armed = armedGoal }
        }
        if !reduceMotion { phase += dt }
    }

    /// Nothing will change until the next state: the driver timer can stop.
    func isSettled(for scene: OrbScene, reduceMotion: Bool = false) -> Bool {
        guard stretch == Self.target(for: scene), float == Self.floatTarget(for: scene, reduceMotion: reduceMotion),
              armed == Self.armedTarget(for: scene)
        else { return false }
        switch scene.motion {
        case .none: return true
        case .pulse, .bars: return false
        // The armed ring follows the level; under Reduce Motion the look is a still brightening.
        case .spin, .breathe, .spinner, .idle, .armed: return reduceMotion
        }
    }
}

/// The card's grow out of the orb, 0 (folded into the orb) to 1 (open), advanced linearly
/// over `OrbLayout.cardOpenDuration` or `cardCloseDuration`; `OrbLayout.growEase` shapes it.
/// Reversing mid-way continues from where it is.
struct CardGrow: Equatable {
    private(set) var progress: CGFloat = 0
    var target: CGFloat = 0

    var isSettled: Bool { progress == target }

    mutating func advance(dt: Double, reduceMotion: Bool) {
        guard !reduceMotion else { progress = target; return }
        let duration = target > progress ? OrbLayout.cardOpenDuration : OrbLayout.cardCloseDuration
        let step = CGFloat(dt / duration)
        progress = target > progress ? min(target, progress + step) : max(target, progress - step)
    }
}
