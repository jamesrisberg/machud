import XCTest
import HUDKit
@testable import MacHUDCore

/// The search bar's Stash client against a stand-in Stash: a real socket serving `snippets`.
@MainActor
final class StashSnippetsTests: XCTestCase {
    private var dir: URL!
    private var server: HUDSocketServer!
    private var path: String { dir.appendingPathComponent("stash.sock").path }
    private var received: [[String: String]] = []

    override func setUp() {
        dir = FakeBundles.tempDir("stash")
        received = []
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A Stash whose `snippets` verb answers `reply` (and records what it was asked).
    private func serve(_ reply: [String: Any]?) {
        server = HUDSocketServer(path: path, label: "machud.test.stash")
        if let reply {
            server.register("snippets") { [weak self] args, done in
                self?.received.append(args)
                done(reply)
            }
        }
        XCTAssertTrue(server.start())
    }

    private func list(_ client: StashSnippets, _ query: String) -> [SnippetHit]? {
        var hits: [SnippetHit]?
        client.list(query: query, limit: 5) { hits = $0 }
        XCTAssertTrue(spin { hits != nil })
        return hits
    }

    func testListAsksForTheQueryAndParsesSnippets() throws {
        serve(["ok": true, "snippets": [
            ["id": "a1", "name": "Signature", "keyword": "sig", "collection": "Default", "preview": "Best, J"],
            ["id": "b2", "name": "Address", "keyword": "", "collection": "pkm", "preview": "1 Infinite Loop"],
            ["name": "no id, skipped"],
        ]])
        let hits = try XCTUnwrap(list(StashSnippets(path: { self.path }), "si"))
        XCTAssertEqual(hits, [SnippetHit(id: "a1", name: "Signature", keyword: "sig", collection: "Default", preview: "Best, J"),
                              SnippetHit(id: "b2", name: "Address", keyword: "", collection: "pkm", preview: "1 Infinite Loop")])
        let args = try XCTUnwrap(received.first)
        XCTAssertEqual(args["_"], "list")
        XCTAssertEqual(args["query"], "si")
        XCTAssertEqual(args["limit"], "5")
    }

    func testNoStashMeansNoSnippets() {
        // Nothing listens at the path.
        XCTAssertEqual(list(StashSnippets(path: { self.path }), "si"), [])
    }

    func testAStashWithoutTheVerbMeansNoSnippets() {
        serve(nil)
        XCTAssertEqual(list(StashSnippets(path: { self.path }), "si"), [])
    }

    func testARefusalMeansNoSnippets() {
        serve(["ok": false, "error": "snippets are off"])
        XCTAssertEqual(list(StashSnippets(path: { self.path }), "si"), [])
    }

    func testInsertSendsTheIdAndPassesTheReplyOn() throws {
        serve(["ok": true, "pasted": false, "hint": "Stash needs Accessibility to paste"])
        var reply: [String: Any]?
        StashSnippets(path: { self.path }).insert(id: "a1") { reply = $0 }
        XCTAssertTrue(spin { reply != nil })
        XCTAssertEqual(received.first?["_"], "insert")
        XCTAssertEqual(received.first?["id"], "a1")
        XCTAssertEqual(reply?["pasted"] as? Bool, false)
        XCTAssertEqual(StashSnippets.problem(in: try XCTUnwrap(reply)), "Stash needs Accessibility to paste")
    }

    func testInsertWithoutStashSaysSo() throws {
        var reply: [String: Any]?
        StashSnippets(path: { self.path }).insert(id: "a1") { reply = $0 }
        XCTAssertTrue(spin { reply != nil })
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertNotNil(StashSnippets.problem(in: try XCTUnwrap(reply)))
        XCTAssertNil(StashSnippets.problem(in: ["ok": true, "pasted": true]))
    }

    // MARK: A slow or hung Stash

    /// Holds each request until the test answers it.
    @MainActor
    final class HoldingConnector: SocketConnector {
        var requests: [(args: [String: String], done: (Result<[String: Any], Error>) -> Void)] = []
        func subscribe(path: String, onEvent: @escaping ([String: Any]) -> Void, onClose: @escaping () -> Void,
                       completion: @escaping (Result<SocketSubscription, Error>) -> Void) {}
        func request(path: String, command: String, args: [String: String],
                     completion: @escaping (Result<[String: Any], Error>) -> Void) {
            requests.append((args, completion))
        }
    }

    func testOnlyTheLatestQueryWaitsBehindOneInFlight() {
        let connector = HoldingConnector()
        let client = StashSnippets(path: { "/nowhere.sock" }, lister: connector)
        var answers: [String: [SnippetHit]] = [:]
        for q in ["a", "ab", "abc"] { client.list(query: q, limit: 5) { answers[q] = $0 } }
        XCTAssertEqual(connector.requests.map { $0.args["query"] }, ["a"], "one request at a time")
        XCTAssertEqual(answers["ab"], [], "a query typed over is answered empty, never sent")
        connector.requests[0].done(.failure(HUDSocketError.timeout))
        XCTAssertEqual(answers["a"], [])
        XCTAssertEqual(connector.requests.map { $0.args["query"] }, ["a", "abc"], "the latest goes next")
        connector.requests[1].done(.success(["ok": true, "snippets": [["id": "1", "name": "abc"]]]))
        XCTAssertEqual(answers["abc"]?.map(\.id), ["1"])
    }

    func testNoPathMeansNoSnippets() {
        let connector = HoldingConnector()
        var hits: [SnippetHit]?
        StashSnippets(path: { nil }, lister: connector).list(query: "a", limit: 5) { hits = $0 }
        XCTAssertEqual(hits, [])
        XCTAssertTrue(connector.requests.isEmpty)
    }

    // MARK: Which Stash

    func testWhichStashTheBarAsks() {
        let recorded = { "/Users/u/Library/Application Support/MacHUD/sockets/stash.sock" }
        XCTAssertEqual(SearchServices.stashSocket(environment: [:], recorded: recorded), recorded(),
                       "the real instance asks the Stash the supervisor knows")
        XCTAssertNil(SearchServices.stashSocket(environment: ["MACHUD_SOCKET": "/tmp/t.sock"], recorded: recorded),
                     "an isolated instance asks no Stash")
        XCTAssertEqual(SearchServices.stashSocket(environment: ["MACHUD_SOCKET": "/tmp/t.sock", "MACHUD_STASH_SOCKET": "/tmp/s.sock"],
                                                  recorded: recorded), "/tmp/s.sock")
        XCTAssertNil(SearchServices.stashSocket(environment: [:], recorded: { nil }), "no Stash discovered")
    }
}
