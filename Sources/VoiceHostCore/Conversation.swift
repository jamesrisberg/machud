import BrainKit
import Foundation

/// How the user's words reached the agent.
public enum ConversationSource: String, Codable, Equatable, Sendable {
    /// Spoken: an agent take from the orb, the fn gesture, the wake word or the socket's `ask`.
    case voice
    /// Typed in the expanded card, or sent with the socket's `say`.
    case typed
}

/// One row of the conversation with the agent, as the card draws it, `conversation` reports it
/// and the voice host keeps it. Only the fields of its kind are set (and encoded).
public struct ConversationRow: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case user, reply, progress, approval, notice
    }

    /// A progress line's tool state.
    public enum Step: String, Codable, Equatable, Sendable {
        case running, done, failed, denied
    }

    /// Where an approval stands.
    public enum Decision: String, Codable, Equatable, Sendable {
        /// Waiting for the user.
        case pending
        /// Answered here; the brain has not confirmed it yet.
        case delivering
        case allowed
        case denied
        /// Answered elsewhere, or ended with its turn.
        case resolved
        /// The answer could not be delivered; it can be answered again (`error` says why).
        case failed
    }

    public var id: String
    /// The brain's turn the row belongs to; nil for a user row the brain has not started on.
    public var turnId: String?
    public var kind: Kind
    /// What the user said, the reply, the progress line, the approval's reason or the notice.
    public var text: String
    /// User rows.
    public var source: ConversationSource?
    /// Replies: true while the turn is live.
    public var streaming: Bool?
    /// Progress rows.
    public var step: Step?
    /// Approval rows: the brain's id for answering it, the command or folder, and the decision.
    public var approvalId: String?
    public var detail: String?
    public var decision: Decision?
    public var error: String?
    /// Notice rows: a failure rather than an interruption.
    public var isError: Bool?

    public init(id: String, turnId: String? = nil, kind: Kind, text: String, source: ConversationSource? = nil,
                streaming: Bool? = nil, step: Step? = nil, approvalId: String? = nil, detail: String? = nil,
                decision: Decision? = nil, error: String? = nil, isError: Bool? = nil) {
        self.id = id
        self.turnId = turnId
        self.kind = kind
        self.text = text
        self.source = source
        self.streaming = streaming
        self.step = step
        self.approvalId = approvalId
        self.detail = detail
        self.decision = decision
        self.error = error
        self.isError = isError
    }

    public static func user(id: String, text: String, source: ConversationSource, turnId: String? = nil) -> ConversationRow {
        ConversationRow(id: id, turnId: turnId, kind: .user, text: text, source: source)
    }

    /// An approval the user can still answer.
    public var isPendingApproval: Bool {
        kind == .approval && [.pending, .failed].contains(decision ?? .pending)
    }
}

/// What the voice host keeps of the conversation between launches: the brain's conversation
/// (`threadId`) and its newest rows.
public struct ConversationRecord: Codable, Equatable, Sendable {
    /// A kept row's text is cut to this many characters (a reply can be 64 KB).
    public static let textLimit = 20_000

    public var threadId: String?
    public var rows: [ConversationRow]

    public init(threadId: String?, rows: [ConversationRow]) {
        self.threadId = threadId
        self.rows = rows
    }
}

/// Keeps the conversation record.
@MainActor
protocol ConversationStoring: AnyObject {
    func load() -> ConversationRecord?
    func save(_ record: ConversationRecord)
}

/// `conversation.json` in the voice host's support folder.
@MainActor
final class ConversationFile: ConversationStoring {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> ConversationRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ConversationRecord.self, from: data)
    }

    func save(_ record: ConversationRecord) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            NSLog("MacHUDVoice: could not save the conversation: %@", error.localizedDescription)
        }
    }
}

/// The conversation with the agent: rows kept from earlier launches, then this launch's rows,
/// which BrainKit's `TranscriptModel` reduces from the brain's snapshots and what the user said.
///
/// A submission shows as a user row at once. Until the brain takes it, snapshots are held back,
/// so the user row always comes before the turn it starts; a refused submission leaves no row.
///
/// The conversation belongs to the brain's conversation (`threadId`): a snapshot naming another
/// one (a new session, another workspace or runtime) starts it again. Kept rows come back
/// settled (nothing streams or waits for an answer); the brain reports whatever is still live
/// again, and a kept reply or approval it reports again is shown once.
struct ConversationLog: Equatable {
    static let maxRows = 200

    private(set) var threadID: String?
    private var restored: [ConversationRow]
    private var model = TranscriptModel()
    /// How each of this launch's user rows reached the agent, by `TranscriptModel` row id.
    private var sources: [String: ConversationSource] = [:]
    private var pending: Pending?
    /// The latest snapshot while a submission waits for the brain.
    private var held: AgentSessionSnapshot?
    /// Prefixes this launch's row ids, which `TranscriptModel` numbers from 1 each launch.
    private let launch: String

    private struct Pending: Equatable {
        var text: String
        var source: ConversationSource
    }

    init(record: ConversationRecord? = nil, launch: String = String(UUID().uuidString.prefix(8))) {
        threadID = record?.threadId
        restored = (record?.rows ?? []).map(Self.settled)
        self.launch = launch
        model.maxRows = Self.maxRows
    }

    // MARK: Rows

    var rows: [ConversationRow] {
        var live = model.rows.map(row)
        if let pending {
            live.append(.user(id: "\(launch):pending", text: pending.text, source: pending.source))
        }
        let liveReplies = Set(live.compactMap { $0.kind == .reply ? $0.turnId : nil })
        let liveApprovals = Set(live.compactMap(\.approvalId))
        let kept = restored.filter { row in
            switch row.kind {
            case .reply: return !(row.turnId.map(liveReplies.contains) ?? false)
            case .approval: return !(row.approvalId.map(liveApprovals.contains) ?? false)
            default: return true
            }
        }
        return Array((kept + live).suffix(Self.maxRows))
    }

    /// What is kept between launches: the rows without a submission still in flight, each text
    /// cut to `ConversationRecord.textLimit`.
    var record: ConversationRecord {
        var copy = self
        copy.pending = nil
        return ConversationRecord(threadId: threadID, rows: copy.rows.map { row in
            guard row.text.count > ConversationRecord.textLimit else { return row }
            var cut = row
            cut.text = String(row.text.prefix(ConversationRecord.textLimit)) + "…"
            return cut
        })
    }

    var pendingApprovalIDs: [String] {
        rows.filter(\.isPendingApproval).compactMap(\.approvalId)
    }

    /// The newest typed message (↑ in an empty field recalls it).
    var lastTyped: String? {
        rows.last { $0.kind == .user && $0.source == .typed }?.text
    }

    /// The last exchange as the reply card shows it: the newest user row and the reply after it.
    var latestCard: VoiceCard? {
        let rows = self.rows
        guard let index = rows.lastIndex(where: { $0.kind == .user }) else { return nil }
        let reply = rows[index...].last { $0.kind == .reply }?.text ?? ""
        return VoiceCard(prompt: rows[index].text, reply: reply)
    }

    // MARK: Changes

    /// The user's words are on their way to the brain.
    mutating func submitted(_ text: String, source: ConversationSource) {
        pending = Pending(text: text, source: source)
    }

    /// The brain took the submission: the user row is part of the conversation.
    mutating func accepted() {
        guard let pending else { return }
        self.pending = nil
        model.userSaid(pending.text)
        if let last = model.rows.last, case .user = last.kind { sources[last.id] = pending.source }
        releaseHeld()
    }

    /// The brain did not take the submission.
    mutating func refused() {
        pending = nil
        releaseHeld()
    }

    @discardableResult
    mutating func apply(_ snapshot: AgentSessionSnapshot) -> [TranscriptEvent] {
        if let thread = snapshot.threadId {
            if threadID != nil, thread != threadID { reset() }
            threadID = thread
        }
        guard pending == nil else {
            held = snapshot
            return []
        }
        return model.apply(TranscriptInput(snapshot))
    }

    mutating func markDecision(approvalID: String, allow: Bool) {
        model.markDecision(approvalID: approvalID, allow: allow)
    }

    mutating func decisionFailed(approvalID: String, message: String) {
        model.decisionFailed(approvalID: approvalID, message: message)
    }

    /// Starts the conversation again; a submission in flight stays.
    mutating func reset() {
        restored = []
        model.reset()
        model.maxRows = Self.maxRows
        sources = [:]
    }

    private mutating func releaseHeld() {
        guard let held else { return }
        self.held = nil
        apply(held)
    }

    // MARK: Mapping

    private func row(_ row: TranscriptRow) -> ConversationRow {
        let id = "\(launch):\(row.id)"
        switch row.kind {
        case .user(let text):
            return .user(id: id, text: text, source: sources[row.id] ?? .voice, turnId: row.turnId)
        case .reply(let text, let streaming):
            return ConversationRow(id: id, turnId: row.turnId, kind: .reply, text: text, streaming: streaming)
        case .progress(let text, let state):
            return ConversationRow(id: id, turnId: row.turnId, kind: .progress, text: text, step: Self.step(state))
        case .approval(let approval):
            var decision = ConversationRow.Decision.pending
            var error: String?
            switch approval.resolution {
            case nil: decision = .pending
            case .delivering: decision = .delivering
            case .allowed: decision = .allowed
            case .denied: decision = .denied
            case .resolved: decision = .resolved
            case .failed(let message):
                decision = .failed
                error = message
            }
            let detail = approval.command ?? approval.cwd
            return ConversationRow(id: id, turnId: row.turnId, kind: .approval, text: approval.reason,
                                   approvalId: approval.id, detail: detail?.isEmpty == false ? detail : nil,
                                   decision: decision, error: error)
        case .notice(let text, let isError):
            return ConversationRow(id: id, turnId: row.turnId, kind: .notice, text: text, isError: isError)
        }
    }

    private static func step(_ state: TranscriptRow.ToolState) -> ConversationRow.Step {
        switch state {
        case .running: .running
        case .done: .done
        case .failed: .failed
        case .denied: .denied
        }
    }

    /// A kept row as it comes back after a restart: nothing streams, runs or waits.
    private static func settled(_ row: ConversationRow) -> ConversationRow {
        var row = row
        if row.streaming == true { row.streaming = false }
        if row.step == .running { row.step = .done }
        if row.kind == .approval, [.pending, .delivering, .failed].contains(row.decision ?? .pending) {
            row.decision = .resolved
            row.error = nil
        }
        return row
    }
}
