import AppKit
import Foundation
import SpeakFreeLib

/// The "Keep dictation history" setting (`history` in `voice.json`). Absent means the default
/// rule in `DictationHistoryLocator.plan(for:)`.
public struct DictationHistorySettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Nothing is kept: a take's recording is deleted once it is transcribed.
        case off
        /// The transcript sidecars (`.txt`, `.raw.txt`, `.meta.json`), no audio.
        case text
        /// The recording and its transcript sidecars.
        case textAndAudio
    }

    public var mode: Mode
    /// Keep the history in SpeakFree's recordings folder, so the two apps share one history.
    /// Only takes effect while SpeakFree is installed.
    public var shareWithSpeakFree: Bool

    public init(mode: Mode = .off, shareWithSpeakFree: Bool = false) {
        self.mode = mode
        self.shareWithSpeakFree = shareWithSpeakFree
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .off
        shareWithSpeakFree = (try? c.decode(Bool.self, forKey: .shareWithSpeakFree)) ?? false
    }
}

/// Where finished takes are kept right now: the setting resolved against this Mac.
struct DictationHistoryPlan: Equatable, Sendable {
    var mode: DictationHistorySettings.Mode
    /// The history goes to SpeakFree's recordings folder (asked for, and SpeakFree is installed).
    var shareWithSpeakFree: Bool
    var speakFreeInstalled: Bool
    /// The folder takes are kept in (or would be, while `mode` is off).
    var folder: URL
    /// No `history` setting is saved; the plan follows the default rule.
    var isDefault: Bool

    var keeps: Bool { mode != .off }

    var json: [String: Any] {
        ["mode": mode.rawValue, "shareWithSpeakFree": shareWithSpeakFree, "speakFreeInstalled": speakFreeInstalled,
         "folder": folder.path, "default": isDefault]
    }
}

/// Finds the history's folders and SpeakFree's install, and resolves the setting into a plan.
struct DictationHistoryLocator: Sendable {
    static let speakFreeBundleID = "com.definitelyreal.speakfree"

    /// MacHUD's own history folder (`~/Library/Application Support/MacHUD/Voice/History`).
    let machudFolder: URL
    /// SpeakFree's config folder (`~/.config/speakfree`); its `recordings` folder is SpeakFree's history.
    let speakFreeConfigDirectory: URL
    let isSpeakFreeInstalled: @Sendable () -> Bool

    var speakFreeRecordings: URL { speakFreeConfigDirectory.appendingPathComponent("recordings", isDirectory: true) }

    /// SpeakFree is installed when LaunchServices knows its bundle id, or its config exists (a
    /// build run outside /Applications).
    static func live(machudFolder: URL, speakFreeConfigDirectory: URL) -> DictationHistoryLocator {
        let config = speakFreeConfigDirectory.appendingPathComponent("config.json")
        return DictationHistoryLocator(
            machudFolder: machudFolder, speakFreeConfigDirectory: speakFreeConfigDirectory,
            isSpeakFreeInstalled: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: speakFreeBundleID) != nil
                    || FileManager.default.fileExists(atPath: config.path)
            })
    }

    /// SpeakFree's own "save recordings" choice (`saveRecordings` in its `config.json`); off
    /// when it is not set or the file cannot be read.
    func speakFreeSavesRecordings() -> Bool {
        struct Saved: Decodable { var saveRecordings: FlexBool? }
        let url = speakFreeConfigDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return false }
        return saved.saveRecordings?.value ?? false
    }

    /// The plan for `settings`. With no setting saved: while SpeakFree is installed the history
    /// follows SpeakFree's own `saveRecordings` (recordings and text) and is shared with it, so
    /// there is one history; otherwise it is off. Sharing needs SpeakFree installed; without it
    /// the history stays in MacHUD's folder.
    func plan(for settings: DictationHistorySettings?) -> DictationHistoryPlan {
        let installed = isSpeakFreeInstalled()
        let resolved = settings ?? (installed
            ? DictationHistorySettings(mode: speakFreeSavesRecordings() ? .textAndAudio : .off, shareWithSpeakFree: true)
            : DictationHistorySettings())
        let share = resolved.shareWithSpeakFree && installed
        return DictationHistoryPlan(mode: resolved.mode, shareWithSpeakFree: share, speakFreeInstalled: installed,
                                    folder: share ? speakFreeRecordings : machudFolder, isDefault: settings == nil)
    }
}

/// Files a finished take into the history folder in SpeakFree's `RecordingStore` layout
/// (`recording-<yyyy-MM-dd-HHmmss>-<id>.wav` beside `.txt`, `.raw.txt` and `.meta.json`), so
/// SpeakFree's tools read either folder. The take arrives in the voice host's scratch folder
/// with its sidecars already written by SpeakFree's `finishRecording`.
enum DictationHistoryFiler {
    /// The sidecars, moved before the recording so SpeakFree never sees a recording without its
    /// transcript (its launch sweep offers such a file as a take to recover).
    static let sidecarExtensions = ["txt", "raw.txt", "meta.json"]

    /// Moves the take's files into `plan.folder`: the sidecars, then the recording for
    /// `textAndAudio`; for `text` the recording is deleted. Nothing happens while the plan keeps
    /// nothing (the scratch sweep deletes the take). Returns the files written.
    @discardableResult
    static func file(recording audioURL: URL, plan: DictationHistoryPlan,
                     fileManager: FileManager = .default) -> [URL] {
        guard plan.keeps, fileManager.fileExists(atPath: audioURL.path) else { return [] }
        guard ensureFolder(plan.folder, fileManager: fileManager) else { return [] }
        let stem = audioURL.deletingPathExtension()
        var written: [URL] = []
        for suffix in sidecarExtensions {
            let source = stem.appendingPathExtension(suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = plan.folder.appendingPathComponent(source.lastPathComponent)
            if move(source, to: target, fileManager: fileManager) { written.append(target) }
        }
        if plan.mode == .textAndAudio {
            let target = plan.folder.appendingPathComponent(audioURL.lastPathComponent)
            if move(audioURL, to: target, fileManager: fileManager) { written.append(target) }
        } else {
            try? fileManager.removeItem(at: audioURL)
        }
        return written
    }

    private static func move(_ source: URL, to target: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.moveItem(at: source, to: target)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            NSLog("MacHUDVoice: could not keep %@ in the history: %@", source.lastPathComponent,
                  error.localizedDescription)
            return false
        }
    }

    /// The folder, private to the user and out of backups, as SpeakFree keeps its recordings.
    private static func ensureFolder(_ folder: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("MacHUDVoice: cannot create the history folder %@: %@", folder.path, error.localizedDescription)
            return false
        }
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }
}
