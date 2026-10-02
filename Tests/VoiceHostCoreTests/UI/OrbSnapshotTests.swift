import AppKit
import XCTest
@testable import VoiceHostCore

/// Renders every orb phase to PNGs in `VOICE_ORB_SNAPSHOT_DIR` for visual review. Offscreen
/// only; skipped when the variable is unset.
@MainActor
final class OrbSnapshotTests: XCTestCase {
    func testRenderEveryPhase() throws {
        guard let dir = ProcessInfo.processInfo.environment["VOICE_ORB_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("VOICE_ORB_SNAPSHOT_DIR is not set")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let speech = [0.05, 0.1, 0.3, 0.55, 0.8, 0.6, 0.35, 0.7, 0.95, 0.75, 0.4, 0.2, 0.5, 0.65, 0.3, 0.1]
        let card = VoiceCard(prompt: "What's on my calendar this afternoon?",
                             reply: "You have two things: the design review at 2 pm with Priya, and a dentist appointment at 4:30. "
                                 + "Traffic looks light, so leaving at 4:05 gets you there on time.",
                             progress: ["calendar.list today", "maps.eta Dentist"])
        let approval = VoiceCard(prompt: "Clean up the build folder",
                                 reply: "I can remove the stale build outputs.",
                                 progress: ["fs.du ~/dev/machud/.build"],
                                 approval: VoiceApproval(id: "ap-1", summary: "Delete ~/dev/machud/.build (2.4 GB)?",
                                                         detail: "rm -rf ~/dev/machud/.build"))
        let working = VoiceHostState(phase: .working, card: card, sessionKey: "claude:abc", sessionProvider: "MechaHUD")
        let cases: [(String, VoiceHostState, CGFloat?, [Double], Bool)] = [
            ("01-idle", VoiceHostState(), nil, [], false),
            ("02-idle-muted", VoiceHostState(muted: true), nil, [], false),
            ("03-dictation-morph-halfway", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.5), 0.5, speech, false),
            ("04-dictation-listening", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.6), nil, speech, false),
            ("05-dictation-transcribing", VoiceHostState(phase: .transcribing(.dictation)), nil, [], false),
            ("06-agent-listening-quiet", VoiceHostState(phase: .listening(.agent), inputLevel: 0.05), nil, [], false),
            ("07-agent-listening-loud", VoiceHostState(phase: .listening(.agent), inputLevel: 0.9), nil, [], false),
            ("08-agent-transcribing", VoiceHostState(phase: .transcribing(.agent)), nil, [], false),
            ("09-working-card", VoiceHostState(phase: .working, card: VoiceCard(prompt: card.prompt, progress: ["calendar.list today"])), nil, [], false),
            ("10-awaiting-approval", VoiceHostState(phase: .awaitingApproval, card: approval), nil, [], false),
            ("11-speaking-card", VoiceHostState(phase: .speaking, card: card), nil, [], false),
            ("12-idle-hover-peek", VoiceHostState(card: card), nil, [], true),
            ("13-failed", VoiceHostState(phase: .failed("Speech model not installed")), nil, [], false),
            ("14-hidden-full-screen", VoiceHostState(phase: .working, card: card, hiddenForFullScreen: true), nil, [], false),
        ]
        for (name, state, stretch, levels, hovering) in cases {
            let rep = try XCTUnwrap(OrbSnapshot.render(state, stretch: stretch, levels: levels, hovering: hovering), name)
            let url = out.appendingPathComponent("\(name).png")
            try OrbSnapshot.write(rep, to: url)
            print("orb snapshot: \(url.path)")
        }
        // The resting float at its rest position and at the bottom of its drift.
        for (name, phase) in [("15-idle-float-top", 0.0), ("16-idle-float-bottom", OrbLayout.bobPeriod / 2)] {
            let rep = try XCTUnwrap(OrbSnapshot.render(VoiceHostState(), phaseTime: phase), name)
            let url = out.appendingPathComponent("\(name).png")
            try OrbSnapshot.write(rep, to: url)
            print("orb snapshot: \(url.path)")
        }
        // The armed look while the fn gesture is undecided, then its two commits: into the
        // dictation waveform and into the agent pulse, each midway and settled.
        let armedCases: [(String, VoiceHostState, CGFloat?, CGFloat?, Bool)] = [
            ("18-armed-quiet", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.05, gesturePending: true), nil, nil, false),
            ("19-armed-speaking", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.7, gesturePending: true), nil, nil, false),
            ("20-armed-reduce-motion", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.7, gesturePending: true), nil, nil, true),
            ("21-commit-dictation-midway", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.5), 0.35, 0.55, false),
            ("22-commit-dictation-settled", VoiceHostState(phase: .listening(.dictation), inputLevel: 0.5), nil, nil, false),
            ("23-commit-agent-midway", VoiceHostState(phase: .listening(.agent), inputLevel: 0.5), nil, 0.5, false),
            ("24-commit-agent-settled", VoiceHostState(phase: .listening(.agent), inputLevel: 0.5), nil, nil, false),
        ]
        for (name, state, stretch, armed, reduceMotion) in armedCases {
            let rep = try XCTUnwrap(OrbSnapshot.render(state, stretch: stretch, levels: speech, armed: armed,
                                                       reduceMotion: reduceMotion), name)
            let url = out.appendingPathComponent("\(name).png")
            try OrbSnapshot.write(rep, to: url)
            print("orb snapshot: \(url.path)")
        }
        // The card growing out of the orb, with "Open in …" for the brain's session.
        for progress in [0.0, 0.35, 0.7, 1.0] {
            let name = String(format: "17-card-grow-%03d", Int(progress * 100))
            let rep = try XCTUnwrap(OrbSnapshot.render(working, cardProgress: progress), name)
            let url = out.appendingPathComponent("\(name).png")
            try OrbSnapshot.write(rep, to: url)
            print("orb snapshot: \(url.path)")
        }
    }

    /// The card's three states: the peek, the pinned conversation and the expanded one (with
    /// its scrim, a message being typed, a refusal, an approval waiting, and a long history).
    func testRenderTheConversation() throws {
        guard let dir = ProcessInfo.processInfo.environment["VOICE_ORB_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("VOICE_ORB_SNAPSHOT_DIR is not set")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let rows: [ConversationRow] = [
            .user(id: "1", text: "What's on my calendar this afternoon?", source: .voice, turnId: "t1"),
            ConversationRow(id: "2", turnId: "t1", kind: .progress, text: "calendar.list today", step: .done),
            ConversationRow(id: "3", turnId: "t1", kind: .reply,
                            text: "You have two things: the design review at 2 pm with Priya, and a dentist appointment "
                                + "at 4:30. Traffic looks light, so leaving at 4:05 gets you there on time.",
                            streaming: false),
            .user(id: "4", text: "Move the design review to tomorrow morning and tell Priya.", source: .typed, turnId: "t2"),
            ConversationRow(id: "5", turnId: "t2", kind: .progress, text: "calendar.move \"Design review\"", step: .done),
            ConversationRow(id: "6", turnId: "t2", kind: .approval, text: "Send an email to Priya?",
                            approvalId: "a1", detail: "mail.send to: priya@example.com", decision: .allowed),
            ConversationRow(id: "7", turnId: "t2", kind: .reply,
                            text: "Done: the design review is at 9:30 tomorrow, and Priya has a note from you.", streaming: false),
            .user(id: "8", text: "Clean up the build folder", source: .voice, turnId: "t3"),
            ConversationRow(id: "9", turnId: "t3", kind: .progress, text: "fs.du ~/dev/machud/.build", step: .running),
            ConversationRow(id: "10", turnId: "t3", kind: .approval, text: "Delete ~/dev/machud/.build (2.4 GB)?",
                            approvalId: "a2", detail: "rm -rf ~/dev/machud/.build", decision: .pending),
        ]
        let streaming = Array(rows.prefix(4)) + [
            ConversationRow(id: "s", turnId: "t2", kind: .reply, text: "Moving the design review to", streaming: true),
        ]
        var long: [ConversationRow] = []
        for i in 0..<12 {
            long.append(.user(id: "u\(i)", text: "Question number \(i + 1)?", source: i % 2 == 0 ? .voice : .typed))
            long.append(ConversationRow(id: "r\(i)", kind: .reply,
                                        text: "Answer \(i + 1): a reply long enough to wrap onto a second line in the panel.",
                                        streaming: false))
        }
        let card = VoiceCard(prompt: "Clean up the build folder", reply: "", progress: ["fs.du ~/dev/machud/.build"])
        let cases: [(String, VoiceHostState, [ConversationRow], String, String?)] = [
            ("31-pinned-history", VoiceHostState(phase: .awaitingApproval, card: card, sessionKey: "claude:abc",
                                                 sessionProvider: "MechaHUD", cardMode: .pinned), rows, "", nil),
            ("32-pinned-streaming", VoiceHostState(phase: .working, card: card, cardMode: .pinned), streaming, "", nil),
            ("33-pinned-empty", VoiceHostState(cardMode: .pinned), [], "", nil),
            ("34-expanded-history", VoiceHostState(phase: .awaitingApproval, card: card, sessionKey: "claude:abc",
                                                   sessionProvider: "MechaHUD", cardMode: .expanded), rows, "", nil),
            ("35-expanded-typing", VoiceHostState(card: card, cardMode: .expanded), Array(rows.prefix(7)),
             "Also block an hour on Friday for the\nquarterly planning doc", nil),
            ("36-expanded-busy-refused", VoiceHostState(phase: .working, card: card, cardMode: .expanded), streaming,
             "And then?", VoiceHostController.agentBusy),
            ("37-expanded-empty", VoiceHostState(cardMode: .expanded), [], "", nil),
            ("38-expanded-long-scrolled-to-bottom", VoiceHostState(cardMode: .expanded), long, "", nil),
            ("39-expanded-voice-take", VoiceHostState(phase: .listening(.agent), inputLevel: 0.6, card: card,
                                                      cardMode: .expanded), Array(rows.prefix(7)), "", nil),
        ]
        for (name, state, rows, text, status) in cases {
            let rep = try XCTUnwrap(OrbSnapshot.renderConversation(state, rows: rows, composerText: text, status: status), name)
            let url = out.appendingPathComponent("\(name).png")
            try OrbSnapshot.write(rep, to: url)
            print("orb snapshot: \(url.path)")
        }
        // The peek it grows from.
        let peek = try XCTUnwrap(OrbSnapshot.render(VoiceHostState(phase: .awaitingApproval, card: VoiceCard(
            prompt: "Clean up the build folder", reply: "I can remove the stale build outputs.",
            approval: VoiceApproval(id: "a2", summary: "Delete ~/dev/machud/.build (2.4 GB)?", detail: "rm -rf ~/dev/machud/.build")))))
        try OrbSnapshot.write(peek, to: out.appendingPathComponent("30-peek.png"))
        // A reply being spoken: the peek shows it up to the part being said.
        let reply = "You have two things: the design review at 2 pm with Priya, and a dentist appointment at 4:30."
        let paced = try XCTUnwrap(OrbSnapshot.render(VoiceHostState(phase: .speaking, card: VoiceCard(
            prompt: "What's on my calendar this afternoon?", reply: reply, spokenUpTo: 58))))
        try OrbSnapshot.write(paced, to: out.appendingPathComponent("40-peek-spoken-so-far.png"))
    }
}
