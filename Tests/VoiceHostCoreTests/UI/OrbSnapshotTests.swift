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
    }
}
