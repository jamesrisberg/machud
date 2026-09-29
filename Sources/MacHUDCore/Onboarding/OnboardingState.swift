import Foundation

/// The onboarding's steps, in order: the welcome checklist, one step per section, then done.
enum OnboardingStep: String, CaseIterable, Codable, Equatable {
    case welcome, permissions, voice, brain, apps
    case toolDock = "tooldock"
    case loadout, radial, done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .voice: return "Voice"
        case .brain: return "Brain"
        case .apps: return "Apps"
        case .toolDock: return "Tool dock"
        case .loadout: return "First loadout"
        case .radial: return "Radial menu"
        case .done: return "Done"
        }
    }

    /// What the section sets up, one line for the checklist.
    var summary: String {
        switch self {
        case .welcome: return ""
        case .permissions: return "Accessibility and the microphone"
        case .voice: return "Dictate anywhere with the fn key"
        case .brain: return "The agent, its folder and its voice"
        case .apps: return "HUD apps for the tool dock"
        case .toolDock: return "Where your HUD apps live"
        case .loadout: return "Save a window arrangement"
        case .radial: return "Apply it with a flick"
        case .done: return ""
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "sparkles"
        case .permissions: return "lock.shield"
        case .voice: return "waveform"
        case .brain: return "brain"
        case .apps: return "square.grid.2x2"
        case .toolDock: return "dock.rectangle"
        case .loadout: return "rectangle.split.3x1"
        case .radial: return "circle.circle"
        case .done: return "checkmark.seal"
        }
    }

    /// The steps the checklist tracks (all but welcome and done).
    static let sections: [OnboardingStep] = allCases.filter(\.isSection)
    var isSection: Bool { self != .welcome && self != .done }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var next: OnboardingStep? { index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil }
    var previous: OnboardingStep? { index > 0 ? Self.allCases[index - 1] : nil }
}

/// Where a checklist section stands.
enum OnboardingSectionStatus: String, Codable, Equatable {
    case todo, done, skipped

    var title: String {
        switch self {
        case .todo: return "To do"
        case .done: return "Done"
        case .skipped: return "Skipped"
        }
    }
}

/// What the user did with the onboarding, kept in `state/onboarding.json` beside layouts.json.
struct OnboardingRecord: Codable, Equatable {
    enum Status: String, Codable {
        /// Started and left with "Finish later": shown again at the next launch, at `step`.
        case inProgress
        /// Went through to the end.
        case completed
        /// "Skip setup": never shown again by itself.
        case skipped
    }

    var status: Status
    var step: OnboardingStep
    var updatedAt: String?
    /// Sections marked done or skipped by the user (`OnboardingStep` raw value → status).
    var sections: [String: OnboardingSectionStatus]?
    /// The loadout made in the First loadout section.
    var loadout: String?

    init(status: Status, step: OnboardingStep, updatedAt: String? = nil,
         sections: [String: OnboardingSectionStatus]? = nil, loadout: String? = nil) {
        self.status = status
        self.step = step
        self.updatedAt = updatedAt
        self.sections = sections
        self.loadout = loadout
    }

    private enum CodingKeys: String, CodingKey { case status, step, updatedAt, sections, loadout }

    /// A step or section this build does not know (a record from another version) reads as the
    /// start, and is dropped from `sections`, rather than making the whole record unreadable,
    /// which would show the onboarding again to someone who finished it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Status.self, forKey: .status)
        step = (try? c.decode(String.self, forKey: .step)).flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .sections)) ?? nil
        sections = raw.map { raw in
            raw.reduce(into: [:]) { out, pair in
                guard OnboardingStep(rawValue: pair.key)?.isSection == true,
                      let status = OnboardingSectionStatus(rawValue: pair.value) else { return }
                out[pair.key] = status
            }
        }
        loadout = try c.decodeIfPresent(String.self, forKey: .loadout)
    }

    var json: [String: Any] {
        ["status": status.rawValue, "step": step.rawValue, "updatedAt": updatedAt.map { $0 as Any } ?? NSNull(),
         "sections": (sections ?? [:]).mapValues(\.rawValue), "loadout": loadout.map { $0 as Any } ?? NSNull()]
    }
}

/// Reads and writes the onboarding record. A missing file means onboarding never ran.
struct OnboardingStore {
    let url: URL

    init(url: URL = LayoutStore.configDirectory.appendingPathComponent("state/onboarding.json")) {
        self.url = url
    }

    func load() -> OnboardingRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OnboardingRecord.self, from: data)
    }

    /// Saves `status` at `step`; `sections` and `loadout` nil keep what the record has.
    func save(_ status: OnboardingRecord.Status, step: OnboardingStep, sections: [String: OnboardingSectionStatus]? = nil,
              loadout: String? = nil, now: Date = Date()) {
        let previous = load()
        let record = OnboardingRecord(status: status, step: step, updatedAt: ISO8601DateFormatter().string(from: now),
                                      sections: sections ?? previous?.sections, loadout: loadout ?? previous?.loadout)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch {
            NSLog("MacHUD: could not save the onboarding state: %@", "\(error)")
        }
    }

    func reset() { try? FileManager.default.removeItem(at: url) }

    /// Shown at launch when it never ran or was left unfinished.
    var wantsLaunch: Bool { load().map { $0.status == .inProgress } ?? true }
}

/// The voice host's `brain status` reply: whether the brain is up, why not, the workspace and
/// which runtimes are installed.
struct BrainStatus: Equatable {
    struct Runtime: Equatable {
        var id: String
        var installed: Bool
        var path: String?
    }

    var available: Bool
    var problem: String?
    var workspace: String
    var runtimes: [Runtime]

    init(available: Bool, problem: String? = nil, workspace: String = "", runtimes: [Runtime] = []) {
        self.available = available
        self.problem = problem
        self.workspace = workspace
        self.runtimes = runtimes
    }

    /// Nil unless `reply` is an `ok` brain status.
    init?(reply: [String: Any]) {
        guard reply["ok"] as? Bool == true, let available = reply["available"] as? Bool else { return nil }
        self.available = available
        problem = (reply["problem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        workspace = reply["workspace"] as? String ?? ""
        runtimes = (reply["runtimes"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return Runtime(id: id, installed: r["installed"] as? Bool ?? false,
                           path: (r["path"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func runtime(_ id: String) -> Runtime? { runtimes.first { $0.id == id } }
}

/// A runtime the brain can drive, as the onboarding presents it.
struct BrainRuntimeChoice: Equatable, Identifiable {
    var id: String
    var title: String
    var blurb: String

    /// The runtimes `brain.runtime` takes, in the order they are offered.
    static let all = [
        BrainRuntimeChoice(id: "codex", title: "Codex", blurb: "OpenAI's coding agent, run on this Mac."),
        BrainRuntimeChoice(id: "claude", title: "Claude Code", blurb: "Anthropic's coding agent, run on this Mac."),
        BrainRuntimeChoice(id: "hermes", title: "Hermes", blurb: "A Hermes agent server you run, reached by URL."),
        BrainRuntimeChoice(id: "mclaude", title: "mclaude",
                           blurb: "A Claude Code session you can also watch and drive in MechaHUD: one session, two front ends."),
    ]
}

/// The voice host's live `state`, reduced to what the onboarding's "try it" area shows.
struct VoiceLiveState: Equatable {
    var connected = false
    var phase = "idle"
    var mode: String?
    var message: String?
    var partialTranscript = ""
    var inputLevel = 0.0
    var brainAvailable = false
    var brainProblem: String?
    var muted = false

    init() {}

    /// From a `state` object; nil (not connected) gives the default, disconnected.
    init(state: [String: Any]?) {
        guard let state else { return }
        connected = true
        let phase = state["phase"] as? [String: Any]
        self.phase = phase?["name"] as? String ?? "idle"
        mode = phase?["mode"] as? String
        message = phase?["message"] as? String
        partialTranscript = state["partialTranscript"] as? String ?? ""
        inputLevel = (state["inputLevel"] as? NSNumber)?.doubleValue ?? 0
        brainAvailable = state["brainAvailable"] as? Bool ?? false
        brainProblem = (state["brainProblem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        muted = state["muted"] as? Bool ?? false
    }

    /// One line for the "try it" area. `keyMode` is the voice host's `hold` or `toggle`.
    func headline(keyMode: String) -> String {
        guard connected else { return "Voice is not running." }
        if muted { return "Muted. Unmute from the orb's right-click menu." }
        switch phase {
        case "listening": return mode == "agent" ? "Listening for the agent…" : "Listening. Keep talking…"
        case "transcribing": return "Writing down what you said…"
        case "working": return "The agent is working…"
        case "awaitingApproval": return "The agent is waiting for your approval on the orb's card."
        case "speaking": return "Reading the reply aloud…"
        case "failed": return "That did not work: \(message ?? "unknown error")"
        default:
            return keyMode == "toggle" ? "Ready. Tap fn, say something, tap fn again."
                : "Ready. Hold fn, say something, let go."
        }
    }

    /// Something is happening (the meter and transcript are live).
    var isActive: Bool { connected && phase != "idle" && phase != "failed" }
}

/// The hotkeys the onboarding names, as the user has them set.
struct OnboardingHotkeys: Equatable {
    var radialWheel = "⌃⌥Space"
    var toolDock = "⌃⌥D"
}

/// The voice host's `models status` reply for the Kokoro reply voice.
struct KokoroModelStatus: Equatable {
    var installed: Bool
    var downloading: Bool
    /// 0...1 while downloading.
    var progress: Double
    var bytes: Int64?

    /// Nil unless `reply` is an `ok` models status with a `kokoro` object.
    init?(reply: [String: Any]) {
        guard reply["ok"] as? Bool == true, let kokoro = reply["kokoro"] as? [String: Any] else { return nil }
        installed = kokoro["installed"] as? Bool ?? false
        downloading = kokoro["downloading"] as? Bool ?? false
        progress = min(max((kokoro["progress"] as? NSNumber)?.doubleValue ?? 0, 0), 1)
        bytes = (kokoro["bytes"] as? NSNumber)?.int64Value
    }

    init(installed: Bool, downloading: Bool = false, progress: Double = 0, bytes: Int64? = nil) {
        self.installed = installed
        self.downloading = downloading
        self.progress = progress
        self.bytes = bytes
    }

    var json: [String: Any] {
        ["installed": installed, "downloading": downloading, "progress": progress, "bytes": bytes.map { $0 as Any } ?? NSNull()]
    }
}

/// The reply voices `voice.replyVoice` takes, in the order they are offered.
struct ReplyVoiceChoice: Equatable, Identifiable {
    var id: String
    var title: String

    static let all = [
        ReplyVoiceChoice(id: "kokoro", title: "Kokoro (on this Mac)"),
        ReplyVoiceChoice(id: "system", title: "System voice"),
        ReplyVoiceChoice(id: "grok", title: "Grok"),
    ]
}
