import Foundation
import os

/// One line of the take journal: a take that ended, or one the host refused to start, with what
/// started it and what became of it. Never the words: only how many characters went where.
public struct VoiceTakeRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        /// Sent to the brain, which took it as a turn.
        case sent
        /// Typed at the cursor: a dictation, or an agent take the brain could not take then
        /// (`reason` says why).
        case typed
        /// Thrown away: no speech was heard, or the words came out empty.
        case nothingHeard
        /// Never recorded (the host or the dictation refused it), or the brain refused the turn;
        /// `reason` says why.
        case refused
        /// Thrown away: `action cancel`, mute, a discarded fn tap or a change to the fn key setup.
        case cancelled
        /// The dictation failed (`reason`).
        case failed
    }

    /// When the take started, or was refused: ISO 8601 in local time with its offset.
    public var date: String
    public var trigger: VoiceTakeTrigger
    /// Where its words were meant to go.
    public var mode: VoiceMode
    /// How long it recorded; nil for a take that never did.
    public var seconds: TimeInterval?
    /// Why recording ended; nil for a take that never recorded.
    public var end: VoiceTakeEnd.Reason?
    public var outcome: Outcome
    public var reason: String?
    /// How many characters were sent or typed; nil when nothing was.
    public var characters: Int?

    public init(date: String, trigger: VoiceTakeTrigger, mode: VoiceMode, seconds: TimeInterval? = nil,
                end: VoiceTakeEnd.Reason? = nil, outcome: Outcome, reason: String? = nil, characters: Int? = nil) {
        self.date = date
        self.trigger = trigger
        self.mode = mode
        self.seconds = seconds.map { ($0 * 100).rounded() / 100 }
        self.end = end
        self.outcome = outcome
        self.reason = reason
        self.characters = characters
    }

    /// `date` for a moment: `2026-10-03T12:04:07-04:00`.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
    }

    /// For the log: `typed (The agent is still working — pasted instead), 812 characters:
    /// wake word "Hey Jarvis" (score 0.973), agent, take 72.5 s ended by pause`.
    public var summary: String {
        var text = outcome.rawValue
        if let reason { text += " (\(reason))" }
        if let characters { text += ", \(characters) characters" }
        text += ": \(trigger.summary), \(mode.rawValue)"
        if let seconds { text += String(format: ", take %.1f s", seconds) }
        if let end { text += " ended by \(end.rawValue)" }
        return text
    }
}

/// Keeps the take journal.
@MainActor
protocol TakeJournaling: AnyObject {
    func append(_ record: VoiceTakeRecord)
    /// The newest `limit` records, oldest first.
    func recent(limit: Int) -> [VoiceTakeRecord]
}

/// `takes.jsonl` beside the conversation: one JSON object per line, oldest first, the newest
/// `capacity` lines kept, readable by the user only. A line that does not decode (a newer
/// host's) is skipped when read and kept as it is when the journal is trimmed. A file that is not
/// a journal at all (not text, or no line decodes) is never written over: the next append moves
/// it aside to `takes.jsonl.unreadable-<date>` and starts a new one.
@MainActor
final class TakeJournalFile: TakeJournaling {
    nonisolated static let defaultCapacity = 1000

    let url: URL
    let capacity: Int
    private let now: () -> Date

    init(url: URL, capacity: Int = TakeJournalFile.defaultCapacity, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.capacity = capacity
        self.now = now
    }

    /// The journal beside a conversation file, so an isolated host keeps it beside its own state:
    /// `takes.jsonl` beside `conversation.json`, `<name>-takes.jsonl` beside
    /// `<name>-conversation.json`, else `<file name>-takes.jsonl`.
    static func url(besideConversation conversation: URL) -> URL {
        let name = conversation.deletingPathExtension().lastPathComponent
        let base: String
        if name == "conversation" {
            base = "takes"
        } else if name.hasSuffix("-conversation") {
            base = String(name.dropLast("conversation".count)) + "takes"
        } else {
            base = name + "-takes"
        }
        return conversation.deletingLastPathComponent().appendingPathComponent(base + ".jsonl")
    }

    func append(_ record: VoiceTakeRecord) {
        do {
            let encoder = JSONEncoder()
            // The same key order on every line, so lines read and compare alike.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encoded = try encoder.encode(record)
            guard let line = String(data: encoded, encoding: .utf8) else { return }
            var kept: [String] = []
            switch read() {
            case .missing: break
            case .journal(let lines, _): kept = lines
            case .unreadable(let why): try moveAside(because: why)
            }
            // When and how the user spoke is theirs alone, like the conversation.
            try PrivateFile.write(Data(((kept + [line]).suffix(capacity).joined(separator: "\n") + "\n").utf8), to: url)
        } catch {
            TakeLog.logger.error("could not save the take journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recent(limit: Int) -> [VoiceTakeRecord] {
        guard case .journal(_, let records) = read() else { return [] }
        return Array(records.suffix(max(limit, 0)))
    }

    private enum Contents {
        case missing
        /// Every line as it is, and the records among them.
        case journal([String], [VoiceTakeRecord])
        case unreadable(String)
    }

    private func read() -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable("it is not UTF-8 text") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let decoder = JSONDecoder()
        let records = lines.compactMap { try? decoder.decode(VoiceTakeRecord.self, from: Data($0.utf8)) }
        if !lines.isEmpty, records.isEmpty { return .unreadable("none of its \(lines.count) lines is a take") }
        return .journal(lines, records)
    }

    /// Keeps a file that is not a journal beside it, under a name of its own, for whoever wants
    /// to see what it was.
    private func moveAside(because why: String) throws {
        // Local time, as in the journal's dates: `20261003T120407`.
        let stamp = now().formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard,
                                                            timeSeparator: .omitted, timeZone: .current)
            .year().month().day().time(includingFractionalSeconds: false))
        var aside = url.appendingPathExtension("unreadable-\(stamp)")
        var n = 2
        while FileManager.default.fileExists(atPath: aside.path) {
            aside = url.appendingPathExtension("unreadable-\(stamp)-\(n)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: aside)
        TakeLog.logger.error("""
            the take journal could not be read (\(why, privacy: .public)); kept as \
            \(aside.lastPathComponent, privacy: .public) and started again
            """)
    }
}

/// The voice host's account of its takes in the unified log: subsystem
/// `com.jrisberg.machud.voice`, category `take`. Every value is public, so the log reads the
/// same after the fact; nothing logged here carries what was said.
enum TakeLog {
    static let logger = Logger(subsystem: VoiceHostMain.secretsService, category: "take")

    static func notice(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}
