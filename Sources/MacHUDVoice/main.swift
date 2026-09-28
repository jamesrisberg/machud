import VoiceHostCore

// Entry point for MacHUD's voice host (Contents/Helpers/MacHUDVoice).
MainActor.assumeIsolated {
    VoiceHostMain.run(makePresenter: { _ in HeadlessVoicePresenter() })
}
