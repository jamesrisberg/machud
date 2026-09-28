import XCTest
@testable import VoiceHostCore

final class VoiceHostSettingsTests: XCTestCase {
    func testEmptyObjectDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, VoiceHostSettings())
        XCTAssertEqual(settings.brainPort, 8791)
    }

    func testBadValuesFallBackToDefaults() throws {
        let json = #"{"keyMode":"edit","brainPort":80,"enabled":"yes"}"#
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.keyMode, .hold)
        XCTAssertEqual(settings.brainPort, 8791)
        XCTAssertTrue(settings.enabled)
    }

    func testPhaseEncodesWithPlainNames() throws {
        let data = try JSONEncoder().encode(VoicePhase.listening(.agent))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(object, ["name": "listening", "mode": "agent"])
        let failed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoicePhase.failed("No mic"))) as? [String: String]
        XCTAssertEqual(failed, ["name": "failed", "message": "No mic"])
    }

    func testStateRoundTrips() throws {
        let state = VoiceHostState(phase: .failed("No mic"), card: VoiceCard(prompt: "hi", approval: VoiceApproval(id: "a", summary: "Run ls")))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostState.self, from: data), state)
    }
}
