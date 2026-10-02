import BrainKit
import XCTest
@testable import VoiceHostCore

final class ConversationTests: XCTestCase {
    private func snapshot(_ status: String, output: String = "", progress: String = "",
                          approvals: [AgentApproval] = [], error: String? = nil,
                          turn: String? = "t1", thread: String? = "thread-a") -> AgentSessionSnapshot {
        struct Wire: Encodable {
            let threadId: String?, turnId: String?, status: String, output: String, progress: String
            let approvals: [AgentApproval], error: String?, revision: Int
        }
        let data = try! JSONEncoder().encode(Wire(threadId: thread, turnId: turn, status: status, output: output,
                                                   progress: progress, approvals: approvals, error: error, revision: 1))
        return try! JSONDecoder().decode(AgentSessionSnapshot.self, from: data)
    }

    private func kinds(_ log: ConversationLog) -> [ConversationRow.Kind] { log.rows.map(\.kind) }

    // MARK: Turns

    func testAVoiceTurnBecomesAUserRowThenAStreamingReply() {
        var log = ConversationLog(launch: "L")
        log.submitted("What time is it?", source: .voice)
        XCTAssertEqual(log.rows.map(\.text), ["What time is it?"], "shown while the brain takes it")
        log.accepted()
        log.apply(snapshot("running", output: "It is"))
        log.apply(snapshot("running", output: "It is noon."))
        XCTAssertEqual(kinds(log), [.user, .reply])
        XCTAssertEqual(log.rows[0].source, .voice)
        XCTAssertEqual(log.rows[1].text, "It is noon.")
        XCTAssertEqual(log.rows[1].streaming, true)
        log.apply(snapshot("idle", output: "It is noon."))
        XCTAssertEqual(log.rows[1].streaming, false)
        XCTAssertEqual(log.rows[0].turnId, "t1")
    }

    func testATypedTurnKeepsItsSource() {
        var log = ConversationLog(launch: "L")
        log.submitted("list my files", source: .typed)
        log.accepted()
        log.apply(snapshot("idle", output: "Done."))
        XCTAssertEqual(log.rows.first?.source, .typed)
        XCTAssertEqual(log.lastTyped, "list my files")
    }

    func testASnapshotBeforeTheAcceptanceStillFollowsTheUserRow() {
        var log = ConversationLog(launch: "L")
        log.submitted("hello", source: .voice)
        log.apply(snapshot("running", output: "Hi"))
        log.accepted()
        XCTAssertEqual(kinds(log), [.user, .reply])
        XCTAssertEqual(log.rows[1].streaming, true, "the held snapshot is a live turn")
    }

    func testARefusedSubmissionLeavesNoUserRow() {
        var log = ConversationLog(launch: "L")
        log.submitted("hello", source: .typed)
        log.refused()
        XCTAssertTrue(log.rows.isEmpty)
    }

    func testProgressApprovalsAndNotices() {
        var log = ConversationLog(launch: "L")
        log.submitted("clean up", source: .voice)
        log.accepted()
        log.apply(snapshot("running", progress: "Reading folder"))
        let approval = AgentApproval(id: "a1", kind: "command", reason: "Delete build", command: "rm -rf .build")
        log.apply(snapshot("approval", progress: "Reading folder", approvals: [approval]))
        XCTAssertEqual(kinds(log), [.user, .progress, .approval])
        XCTAssertEqual(log.rows[2].approvalId, "a1")
        XCTAssertEqual(log.rows[2].text, "Delete build")
        XCTAssertEqual(log.rows[2].detail, "rm -rf .build")
        XCTAssertEqual(log.rows[2].decision, .pending)
        XCTAssertEqual(log.pendingApprovalIDs, ["a1"])
        log.markDecision(approvalID: "a1", allow: false)
        XCTAssertEqual(log.rows[2].decision, .delivering)
        log.apply(snapshot("interrupted"))
        XCTAssertEqual(log.rows[2].decision, .denied)
        XCTAssertEqual(log.rows.last?.kind, .notice)
        XCTAssertTrue(log.pendingApprovalIDs.isEmpty)
    }

    func testRowIDsAreUniqueAcrossLaunches() {
        var first = ConversationLog(launch: "A")
        first.submitted("one", source: .voice)
        first.accepted()
        first.apply(snapshot("idle", output: "1", turn: "t1"))
        var second = ConversationLog(record: first.record, launch: "B")
        second.submitted("two", source: .voice)
        second.accepted()
        second.apply(snapshot("idle", output: "2", turn: "t2"))
        let ids = second.rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
        XCTAssertEqual(second.rows.map(\.text), ["one", "1", "two", "2"])
    }

    // MARK: Persistence

    func testTheRecordRestoresTheRowsSettled() throws {
        var log = ConversationLog(launch: "A")
        log.submitted("hello", source: .typed)
        log.accepted()
        let approval = AgentApproval(id: "a1", kind: "command", reason: "Run ls")
        log.apply(snapshot("approval", output: "Let me look", progress: "ls", approvals: [approval]))
        let data = try JSONEncoder().encode(log.record)
        let record = try JSONDecoder().decode(ConversationRecord.self, from: data)
        XCTAssertEqual(record.threadId, "thread-a")
        let restored = ConversationLog(record: record, launch: "B")
        XCTAssertEqual(restored.rows.map(\.text), log.rows.map(\.text))
        let reply = try XCTUnwrap(restored.rows.first { $0.kind == .reply })
        XCTAssertEqual(reply.streaming, false, "nothing streams after a restart")
        XCTAssertEqual(restored.rows.first { $0.kind == .progress }?.step, .done)
        XCTAssertEqual(restored.rows.first { $0.kind == .approval }?.decision, .resolved,
                       "the brain re-reports an approval that is still pending")
        XCTAssertTrue(restored.pendingApprovalIDs.isEmpty)
        XCTAssertEqual(restored.lastTyped, "hello")
    }

    func testTheBrainsReportOfTheLastTurnOnConnectIsNotShownTwice() {
        var log = ConversationLog(launch: "A")
        log.submitted("hello", source: .voice)
        log.accepted()
        log.apply(snapshot("idle", output: "Hi there", turn: "t9"))
        var restored = ConversationLog(record: log.record, launch: "B")
        restored.apply(snapshot("idle", output: "Hi there", turn: "t9"))
        XCTAssertEqual(restored.rows.map(\.text), ["hello", "Hi there"])
    }

    func testANewThreadClearsTheConversation() {
        var log = ConversationLog(launch: "A")
        log.submitted("hello", source: .voice)
        log.accepted()
        log.apply(snapshot("idle", output: "Hi", turn: "t1", thread: "thread-a"))
        log.apply(snapshot("idle", turn: nil, thread: nil))
        XCTAssertEqual(log.rows.count, 2, "a snapshot without a thread changes nothing")
        log.apply(snapshot("idle", turn: nil, thread: "thread-b"))
        XCTAssertTrue(log.rows.isEmpty)
        XCTAssertEqual(log.record.threadId, "thread-b")
    }

    func testARestoredConversationAdoptsTheFirstThreadWhenItHadNone() {
        let record = ConversationRecord(threadId: nil, rows: [.user(id: "x:1", text: "hi", source: .voice)])
        var log = ConversationLog(record: record, launch: "B")
        log.apply(snapshot("idle", turn: nil, thread: "thread-a"))
        XCTAssertEqual(log.rows.map(\.text), ["hi"])
        XCTAssertEqual(log.record.threadId, "thread-a")
    }

    func testTheConversationKeepsTheNewestRows() {
        var record = ConversationRecord(threadId: "thread-a", rows: [])
        for i in 0..<ConversationLog.maxRows {
            record.rows.append(.user(id: "old:\(i)", text: "old \(i)", source: .voice))
        }
        var log = ConversationLog(record: record, launch: "B")
        log.submitted("new", source: .typed)
        log.accepted()
        XCTAssertEqual(log.rows.count, ConversationLog.maxRows)
        XCTAssertEqual(log.rows.last?.text, "new")
        XCTAssertEqual(log.rows.first?.text, "old 1")
    }

    func testVeryLongRowsAreShortenedWhenKept() {
        var log = ConversationLog(launch: "A")
        log.submitted("essay", source: .voice)
        log.accepted()
        log.apply(snapshot("idle", output: String(repeating: "a", count: ConversationRecord.textLimit + 500)))
        let kept = log.record.rows.last?.text ?? ""
        XCTAssertLessThanOrEqual(kept.count, ConversationRecord.textLimit + 1)
        XCTAssertTrue(kept.hasSuffix("…"))
    }

    func testTheLatestCardComesFromTheLastExchange() {
        var log = ConversationLog(launch: "A")
        XCTAssertNil(log.latestCard)
        log.submitted("first", source: .voice)
        log.accepted()
        log.apply(snapshot("idle", output: "one", turn: "t1"))
        log.submitted("second", source: .typed)
        log.accepted()
        log.apply(snapshot("idle", output: "two", turn: "t2"))
        XCTAssertEqual(log.latestCard, VoiceCard(prompt: "second", reply: "two"))
    }

    @MainActor
    func testTheFileStoreRoundTripsAndToleratesAMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationFile(url: dir.appendingPathComponent("conversation.json"))
        XCTAssertNil(store.load())
        let record = ConversationRecord(threadId: "t", rows: [.user(id: "a", text: "hi", source: .typed)])
        store.save(record)
        XCTAssertEqual(store.load(), record)
    }

    func testRowsEncodeOnlyTheFieldsTheirKindHas() throws {
        let row = ConversationRow.user(id: "a", text: "hi", source: .typed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "text", "source"])
    }
}
