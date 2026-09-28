import Foundation
import HUDKit

/// Where the voice host lives and how MacHUD reaches it.
enum VoiceHostPaths {
    /// The helper executable: `Contents/Helpers/MacHUDVoice` in the app, beside `MacHUD` in `.build`.
    static let helperName = "MacHUDVoice"
    /// The contract socket name (`machud-voice.sock` in HUDKit's socket directory).
    static let socketName = "machud-voice"

    /// `$MACHUD_VOICE_SOCKET`; else, for an isolated instance (`MACHUD_SOCKET` or `MACHUD_CONFIG`
    /// set), a socket of its own beside its control socket or config, so a test instance never
    /// reaches the real voice host; else HUDKit's `machud-voice.sock`.
    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = Env.value("VOICE_SOCKET", in: environment), !path.isEmpty {
            return (path as NSString).expandingTildeInPath
        }
        if let control = Env.value("SOCKET", in: environment), !control.isEmpty {
            let base = control.hasSuffix(".sock") ? String(control.dropLast(5)) : control
            return base + "-voice.sock"
        }
        if let config = Env.value("CONFIG", in: environment), !config.isEmpty {
            let dir = URL(fileURLWithPath: (config as NSString).expandingTildeInPath).deletingLastPathComponent()
            return dir.appendingPathComponent(socketName + ".sock").path
        }
        return HUDSocket.path(for: socketName)
    }

    /// The helper for the MacHUD binary at `executable`: `../Helpers/MacHUDVoice` in a bundle,
    /// else `MacHUDVoice` beside it (`swift build` puts both products in one directory).
    static func helperURL(executable: URL?, fileManager: FileManager = .default) -> URL? {
        guard let dir = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let candidates = [dir.appendingPathComponent("../Helpers/\(helperName)").standardizedFileURL,
                          dir.appendingPathComponent(helperName)]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// `voice.json` beside MacHUD's `layouts.json`. The voice host owns the file; MacHUD only
    /// reads `enabled` from it, to decide whether to start the host at all.
    static func settingsURL(configDirectory: URL = LayoutStore.configDirectory) -> URL {
        configDirectory.appendingPathComponent("voice.json")
    }

    /// `enabled` in voice.json. Missing or unreadable reads as on, the host's own default.
    static func isEnabled(settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return object["enabled"] as? Bool ?? true
    }
}
