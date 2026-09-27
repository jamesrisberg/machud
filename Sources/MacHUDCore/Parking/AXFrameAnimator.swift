import AppKit
import HUDKit

/// Slides another app's window by setting its AX position at ~60 Hz on a critically
/// damped `HUDSpring`, then snaps to the target once `duration` is up. Best effort: each
/// step is a synchronous round trip to the app, so slow apps look choppy.
@MainActor
final class AXFrameAnimator {
    private let window: AXWindow
    private var x: HUDSpring
    private var y: HUDSpring
    private let target: CGPoint
    private let duration: TimeInterval
    private let began = Date()
    private var timer: Timer?
    private var completion: (() -> Void)?
    private let stiffness: Double

    /// `from`/`to` are Cocoa frames; only the position animates.
    init(window: AXWindow, from: CGRect, to: CGRect, duration: TimeInterval, completion: (() -> Void)?) {
        self.window = window
        let a = ScreenCoords.axRect(fromCocoa: from).origin
        target = ScreenCoords.axRect(fromCocoa: to).origin
        x = HUDSpring(Double(a.x)); x.target = Double(target.x)
        y = HUDSpring(Double(a.y)); y.target = Double(target.y)
        self.duration = duration
        self.completion = completion
        // Critically damped and ~1 % from the target when `duration` runs out.
        stiffness = pow(6 / max(duration, 0.05), 2)
    }

    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Stops where it is, without calling the completion.
    func cancel() {
        timer?.invalidate()
        timer = nil
        completion = nil
    }

    private func tick() {
        let dt = 1.0 / 60
        let doneX = x.step(dt: dt, stiffness: stiffness, damping: 1, epsilon: 0.5)
        let doneY = y.step(dt: dt, stiffness: stiffness, damping: 1, epsilon: 0.5)
        let finished = (doneX && doneY) || Date().timeIntervalSince(began) >= duration
        window.setAXPosition(finished ? target : CGPoint(x: x.value.rounded(), y: y.value.rounded()))
        guard finished else { return }
        timer?.invalidate()
        timer = nil
        let done = completion
        completion = nil
        done?()
    }
}
