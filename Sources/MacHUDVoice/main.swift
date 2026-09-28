import Foundation
import VoiceHostCore

// Entry point for MacHUD's voice host (Contents/Helpers/MacHUDVoice). MACHUD_VOICE_HEADLESS=1
// runs without the orb, for isolated test runs that must not put windows on screen.
MainActor.assumeIsolated {
    if ProcessInfo.processInfo.environment["MACHUD_VOICE_HEADLESS"] == "1" {
        VoiceHostMain.run(makePresenter: { _ in HeadlessVoicePresenter() })
    } else {
        VoiceHostMain.run(makePresenter: { actions in VoiceOrbPresenter(actions: actions) })
    }
}
