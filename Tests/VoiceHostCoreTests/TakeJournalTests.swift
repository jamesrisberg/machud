import XCTest
@testable import VoiceHostCore

/// `takes.jsonl`: one line per take, the newest kept, readable by the user only, never the words.
@MainActor
final class TakeJournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("takes-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ n: Int, outcome: VoiceTakeRecord.Outcome = .sent) -> VoiceTakeRecord {
        VoiceTakeRecord(date: "2026-10-03T12:04:0\(n % 10)-04:00", trigger: .orb, mode: .agent,
                        seconds: Double(n), end: .pause, outcome: outcome, characters: n)
    }

    func testRecordsComeBackNewestLastAndAMissingFileIsEmpty() {
        let journal = TakeJournalFile(url: directory.appendingPathComponent("takes.jsonl"))
        XCTAssertEqual(journal.recent(limit: 20), [])
        for n in 1...3 { journal.append(record(n)) }
        XCTAssertEqual(journal.recent(limit: 20), [record(1), record(2), record(3)])
        XCTAssertEqual(journal.recent(limit: 2), [record(2), record(3)])
        let first = try? String(contentsOf: journal.url, encoding: .utf8).split(separator: "\n").first
        XCTAssertEqual(first.map(String.init), #"{"characters":1,"date":"2026-10-03T12:04:01-04:00","end":"pause","#
                       + #""mode":"agent","outcome":"sent","seconds":1,"trigger":{"source":"orb"}}"#,
                       "every line has its keys in one order")
        let mode = try? FileManager.default.attributesOfItem(atPath: journal.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "only the user can read the journal")
    }

    func testOnlyTheNewestLinesAreKept() throws {
        XCTAssertEqual(TakeJournalFile.defaultCapacity, 1000)
        let journal = TakeJournalFile(url: directory.appendingPathComponent("takes.jsonl"), capacity: 5)
        for n in 1...8 { journal.append(record(n)) }
        let text = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 5)
        XCTAssertEqual(journal.recent(limit: 100).map(\.characters), [4, 5, 6, 7, 8])
    }

    func testALineThatDoesNotDecodeIsSkippedAndKept() throws {
        let url = directory.appendingPathComponent("takes.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = String(data: try JSONEncoder().encode(record(1)), encoding: .utf8)!
        try Data((line + "\n{\"date\":\"torn\n").utf8).write(to: url)
        let journal = TakeJournalFile(url: url)
        XCTAssertEqual(journal.recent(limit: 20), [record(1)])
        journal.append(record(2))
        XCTAssertEqual(journal.recent(limit: 20), [record(1), record(2)])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("torn"))
    }

    func testAnUnreadableJournalIsMovedAsideNotReplaced() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("takes.jsonl")
        for (n, unreadable) in [Data([0xFF, 0xFE, 0x00, 0x80]), Data("not a take journal\n".utf8)].enumerated() {
            try? FileManager.default.removeItem(at: url)
            try unreadable.write(to: url)
            let journal = TakeJournalFile(url: url)
            XCTAssertEqual(journal.recent(limit: 5), [])
            XCTAssertEqual(try Data(contentsOf: url), unreadable, "reading moves nothing")
            journal.append(record(1))
            XCTAssertEqual(journal.recent(limit: 5), [record(1)])
            let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("takes.jsonl.unreadable-") }
            XCTAssertEqual(aside.count, n + 1, "\(aside)")
            let kept = try aside.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
            XCTAssertTrue(kept.contains(unreadable), "the unreadable file is kept as it was")
        }
    }

    func testAMissingJournalIsEmptyAndMovesNothing() throws {
        let journal = TakeJournalFile(url: directory.appendingPathComponent("takes.jsonl"))
        journal.append(record(1))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["takes.jsonl"])
    }

    func testAPrivateFileIsWrittenWholeAndReadableByTheUserOnly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("conversation.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try PrivateFile.write(Data("new".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["conversation.json"],
                       "no temporary file is left behind")
    }

    func testALineHasNoWordsOnlyACount() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            VoiceTakeRecord(date: "2026-10-03T12:04:07-04:00", trigger: .wake(score: 0.973, phrase: "Hey Jarvis"),
                            mode: .agent, seconds: 72.53, end: .pause, outcome: .typed,
                            reason: "The agent is still working — pasted instead", characters: 706))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["date", "trigger", "mode", "seconds", "end", "outcome", "reason", "characters"])
        let refused = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            VoiceTakeRecord(date: "d", trigger: .orb, mode: .agent, outcome: .refused, reason: "Voice is off"))) as? [String: Any])
        XCTAssertEqual(Set(refused.keys), ["date", "trigger", "mode", "outcome", "reason"])
        XCTAssertEqual(VoiceTakeRecord(date: "d", trigger: .orb, mode: .agent, seconds: 3.14159, outcome: .sent).seconds, 3.14)
    }

    func testTheDateIsISO8601InLocalTime() throws {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(VoiceTakeRecord.timestamp(date, timeZone: newYork), "2026-10-03T00:00:00-04:00")
        XCTAssertEqual(try Date.ISO8601FormatStyle().parse(VoiceTakeRecord.timestamp(date)), date)
    }

    func testTheJournalSitsBesideTheConversation() {
        func beside(_ path: String) -> String { TakeJournalFile.url(besideConversation: URL(fileURLWithPath: path)).path }
        XCTAssertEqual(beside("/Users/u/Library/Application Support/MacHUD/Voice/conversation.json"),
                       "/Users/u/Library/Application Support/MacHUD/Voice/takes.jsonl")
        XCTAssertEqual(beside("/tmp/mh-1-voice-conversation.json"), "/tmp/mh-1-voice-takes.jsonl",
                       "an isolated host's, beside its socket")
        XCTAssertEqual(beside("/tmp/c.json"), "/tmp/c-takes.jsonl")
    }

    func testAControllersJournalNeverHoldsTheWords() async throws {
        let journal = TakeJournalFile(url: directory.appendingPathComponent("takes.jsonl"))
        let dictation = FakeDictation()
        let brain = FakeBrain()
        let controller = VoiceHostController(
            settings: VoiceHostSettings(), dictation: dictation, keys: nil, brain: brain, speaker: nil, wake: nil,
            brainStateRoot: directory, detectRuntimes: FakeRuntimes.detect(), schedule: { _, _ in },
            takeJournal: journal)
        controller.log = { _ in }
        controller.start()
        controller.perform(.start(.agent), trigger: .socket(action: "ask"))
        controller.perform(.stop)
        dictation.finish("the combination is 4 8 15")
        await controller.pendingWork?.value
        XCTAssertEqual(journal.recent(limit: 1).map(\.outcome), [.sent])
        XCTAssertEqual(journal.recent(limit: 1).first?.characters, 25)
        let text = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertFalse(text.contains("combination"), text)
    }
}
