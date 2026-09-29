import Foundation
import SpeakFreeLib

/// The fn key through SpeakFree's `HotkeyManager` (its event tap, phantom-release guard and
/// gesture recognizer), reporting only gesture intents.
@MainActor
final class FnKeySource: VoiceKeySource {
    private var manager: HotkeyManager?

    func start(mode: KeyGestureRecognizer.Mode, configuration: KeyGestureRecognizer.Configuration,
               isSessionActive: @escaping () -> Bool,
               onIntent: @escaping (KeyGestureRecognizer.Intent) -> Void,
               onRelease: @escaping () -> Void) {
        stop()
        let manager = HotkeyManager(keyCode: Config.defaultConfig.hotkey.keyCode)
        manager.start(
            onKeyDown: {}, onKeyUp: onRelease,
            // A real key pressed with fn held is a keyboard shortcut: drop the take. The manager
            // has already reset its recognizer.
            onAbort: { onIntent(.discard) },
            gestures: HotkeyManager.Gestures(
                mode: mode, configuration: configuration,
                isSessionActive: isSessionActive, onIntent: onIntent))
        self.manager = manager
    }

    func stop() {
        manager?.stop()
        manager = nil
    }
}
