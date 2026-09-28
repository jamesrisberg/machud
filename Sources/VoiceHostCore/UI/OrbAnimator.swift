import Foundation

/// The orb's continuous values between renders: the morph position, the smoothed input level
/// and a free-running phase for spin, breathe and the spinner. Pure; the presenter advances
/// it from a display timer while anything moves.
struct OrbAnimator: Equatable {
    /// 0 = resting orb, 1 = waveform body.
    private(set) var stretch: CGFloat
    /// Smoothed input level, 0...1.
    private(set) var level: CGFloat = 0
    /// Seconds of running motion; frozen under Reduce Motion.
    private(set) var phase: Double = 0

    /// Rate of the morph's exponential ease, per second.
    static let stretchRate: Double = 11
    static let settleEpsilon: CGFloat = 0.004

    init(stretch: CGFloat = 0) {
        self.stretch = stretch
    }

    /// `other` with the morph pinned at `stretch` (snapshots of the in-between frames).
    init(stretch: CGFloat, copying other: OrbAnimator) {
        self = other
        self.stretch = stretch
    }

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
        if !reduceMotion { phase += dt }
    }

    /// Nothing will change until the next state: the driver timer can stop.
    func isSettled(for scene: OrbScene, reduceMotion: Bool = false) -> Bool {
        guard stretch == Self.target(for: scene) else { return false }
        switch scene.motion {
        case .none: return true
        case .pulse, .bars: return false
        case .spin, .breathe, .spinner: return reduceMotion
        }
    }
}
