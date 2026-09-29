import Foundation
import HUDKit

/// `voice.json` in MacHUD's config directory. The voice host owns the file; MacHUD changes it
/// through the socket's `settings set`.
public struct VoiceHostSettingsStore {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("voice.json")
    }

    /// The saved settings; defaults when the file is missing or unreadable, and per key for a
    /// missing or bad value (`VoiceHostSettings` decodes leniently).
    public func load() -> VoiceHostSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(VoiceHostSettings.self, from: data)
        else { return VoiceHostSettings() }
        return settings
    }

    public func save(_ settings: VoiceHostSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// The process environment the voice host reads: paths and the isolation switches a test
/// instance (or MacHUD's own test runs) sets.
public struct VoiceHostEnvironment: Equatable {
    /// The folder of `$MACHUD_CONFIG` (the path of MacHUD's `layouts.json`), else
    /// `~/.config/machud`: `voice.json` sits beside MacHUD's own config.
    public var configDirectory: URL
    /// `$MACHUD_VOICE_SOCKET`, else `machud-voice.sock` in HUDKit's socket directory.
    public var socketPath: String
    /// `MACHUD_VOICE_NO_MIC=1`: a simulated capture path; the microphone is never opened.
    public var noMicrophone: Bool
    /// `MACHUD_NO_HOTKEYS` set to anything (MacHUD's own rule): no fn event tap.
    public var noHotkeys: Bool
    /// `MACHUD_VOICE_NO_BRAIN=1`: the brain never starts, whatever the settings say.
    public var noBrain: Bool
    /// `MACHUD_VOICE_PARENT_PIPE=1`: exit when stdin reaches end-of-file.
    public var parentPipe: Bool
    /// `$MACHUD_VOICE_KEYCHAIN_SERVICE`, else `com.jrisberg.machud.voice`: the Keychain service
    /// every secret is read from and written to (an isolated instance never sees the real key).
    public var keychainService: String
    /// MacHUD's control socket, where `sessions open` goes: `$MACHUD_SOCKET`, else
    /// `/tmp/machud-<uid>.sock`.
    public var machudSocketPath: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func flag(_ name: String) -> Bool { environment[name] == "1" }
        if let config = environment["MACHUD_CONFIG"], !config.isEmpty {
            configDirectory = URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
                .deletingLastPathComponent()
        } else {
            configDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/machud")
        }
        if let socket = environment["MACHUD_VOICE_SOCKET"], !socket.isEmpty {
            socketPath = socket
        } else {
            socketPath = HUDSocket.directory.appendingPathComponent("machud-voice.sock").path
        }
        noMicrophone = flag("MACHUD_VOICE_NO_MIC")
        noHotkeys = environment["MACHUD_NO_HOTKEYS"] != nil
        noBrain = flag("MACHUD_VOICE_NO_BRAIN")
        parentPipe = flag("MACHUD_VOICE_PARENT_PIPE")
        if let service = environment["MACHUD_VOICE_KEYCHAIN_SERVICE"], !service.isEmpty {
            keychainService = service
        } else {
            keychainService = VoiceHostMain.secretsService
        }
        if let socket = environment["MACHUD_SOCKET"], !socket.isEmpty {
            machudSocketPath = (socket as NSString).expandingTildeInPath
        } else {
            machudSocketPath = "/tmp/machud-\(getuid()).sock"
        }
    }
}
