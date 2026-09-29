import AppKit
import AVFoundation

/// Microphone access as macOS reports it for MacHUD (the voice host uses MacHUD's).
enum MicrophoneAccess: String, Equatable {
    case granted, denied, notAsked, restricted
}

/// The two privacy grants the onboarding checks and asks for. Tests use a fake, so no prompt
/// or System Settings pane ever opens from a test.
@MainActor
protocol OnboardingPermissions: AnyObject {
    var accessibility: Bool { get }
    var microphone: MicrophoneAccess { get }
    /// Shows macOS's Accessibility prompt. Returns a note when it cannot.
    func requestAccessibility() -> String?
    /// Asks for the microphone (macOS prompts once), then reports the answer.
    func requestMicrophone(_ done: @escaping @MainActor (MicrophoneAccess) -> Void) -> String?
    func openAccessibilitySettings() -> String?
    func openMicrophoneSettings() -> String?
}

/// The real grants. An isolated instance (`Env.isIsolated`) reads them but never prompts or
/// opens System Settings: grants belong to the user at the Mac.
@MainActor
final class LiveOnboardingPermissions: OnboardingPermissions {
    private let isolated: Bool
    private var askedAccessibility = false
    static let isolatedNote = "A test instance of MacHUD does not ask macOS for permissions."

    init(isolated: Bool = Env.isIsolated) { self.isolated = isolated }

    var accessibility: Bool { Accessibility.isTrusted }

    var microphone: MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notAsked
        }
    }

    func requestAccessibility() -> String? {
        guard !isolated else { return Self.isolatedNote }
        // macOS shows its prompt once per app; after that only System Settings changes it.
        if askedAccessibility { Accessibility.openSettings() } else { Accessibility.requestTrust() }
        askedAccessibility = true
        return nil
    }

    func requestMicrophone(_ done: @escaping @MainActor (MicrophoneAccess) -> Void) -> String? {
        guard !isolated else { return Self.isolatedNote }
        guard microphone == .notAsked else { return openMicrophoneSettings() }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted ? .granted : .denied) } }
        }
        return nil
    }

    func openAccessibilitySettings() -> String? {
        guard !isolated else { return Self.isolatedNote }
        Accessibility.openSettings()
        return nil
    }

    func openMicrophoneSettings() -> String? {
        guard !isolated else { return Self.isolatedNote }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
