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

    func testRepliesToTypedMessagesAreSilentByDefault() throws {
        XCTAssertFalse(try JSONDecoder().decode(VoiceHostSettings.self, from: Data("{}".utf8)).speakTypedReplies)
        var settings = VoiceHostSettings()
        settings.speakTypedReplies = true
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(object["speakTypedReplies"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testMacHUDToolsDefaultOnWithoutApproval() throws {
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(#"{"brain":{"runtime":"claude"}}"#.utf8))
        XCTAssertTrue(settings.machudTools)
        XCTAssertFalse(settings.machudToolsRequireApproval)
        XCTAssertEqual(settings.brain.runtime, .claude)
    }

    /// The MacHUD tool settings live inside `brain` (`brain.machudTools`), beside BrainKit's own keys.
    func testMacHUDToolsAreStoredInsideBrain() throws {
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.machudTools)
        XCTAssertTrue(settings.machudToolsRequireApproval)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let brain = try XCTUnwrap(object["brain"] as? [String: Any])
        XCTAssertEqual(brain["machudTools"] as? Bool, false)
        XCTAssertEqual(brain["machudToolsRequireApproval"] as? Bool, true)
        XCTAssertEqual(brain["workspacePath"] as? String, "/w")
        XCTAssertNil(object["machudTools"])
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testHandsFreeDefaults() throws {
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.handsFree, HandsFreeSettings(endOfTurn: .auto, pause: 2, sensitivity: .medium))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let handsFree = try XCTUnwrap(object["handsFree"] as? [String: Any])
        XCTAssertEqual(handsFree["endOfTurn"] as? String, "auto")
        XCTAssertEqual(handsFree["pause"] as? Double, 2)
        XCTAssertEqual(handsFree["sensitivity"] as? String, "medium")
    }

    func testHandsFreeDecodesLenientlyAndKeepsThePauseInRange() throws {
        func decode(_ json: String) throws -> HandsFreeSettings {
            try JSONDecoder().decode(VoiceHostSettings.self, from: Data(json.utf8)).handsFree
        }
        XCTAssertEqual(try decode(#"{"handsFree":{"endOfTurn":"manual"}}"#),
                       HandsFreeSettings(endOfTurn: .manual, pause: 2, sensitivity: .medium))
        XCTAssertEqual(try decode(#"{"handsFree":{"endOfTurn":"never","pause":"long","sensitivity":"max"}}"#),
                       HandsFreeSettings())
        XCTAssertEqual(try decode(#"{"handsFree":{"pause":9}}"#).pause, 4)
        XCTAssertEqual(try decode(#"{"handsFree":{"pause":0.2}}"#).pause, 1)
        XCTAssertEqual(try decode(#"{"handsFree":{"pause":2.3}}"#).pause, 2.5, "steps of half a second")
        XCTAssertEqual(try decode(#"{"handsFree":{"sensitivity":"high"}}"#).sensitivity, .high)
        XCTAssertEqual(try decode(#"{"handsFree":7}"#), HandsFreeSettings())
        let settings = VoiceHostSettings(handsFree: HandsFreeSettings(endOfTurn: .manual, pause: 3.5, sensitivity: .low))
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testTakeEndRoundTripsInTheState() throws {
        let end = VoiceTakeEnd(reason: .pause, seconds: 6.4, quietMs: 2050, floor: 0.021, threshold: 0.05,
                               pause: 3.5, grace: true, trigger: .wake(score: 0.973, phrase: "Hey Jarvis"))
        let state = VoiceHostState(lastTakeEnd: end)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostState.self, from: JSONEncoder().encode(state)), state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(end)) as? [String: Any])
        XCTAssertEqual(object["reason"] as? String, "pause")
        XCTAssertEqual(object["quietMs"] as? Int, 2050)
        let trigger = try XCTUnwrap(object["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["source"] as? String, "wake")
        XCTAssertEqual(trigger["score"] as? Double, 0.973)
        XCTAssertEqual(trigger["phrase"] as? String, "Hey Jarvis")
        // A take end from before triggers were recorded still decodes.
        let older = try JSONDecoder().decode(VoiceTakeEnd.self, from: Data(#"{"reason":"stop","seconds":2,"grace":false}"#.utf8))
        XCTAssertNil(older.trigger)
        XCTAssertEqual(older.reason, .stop)
    }

    func testTriggersEncodeWithTheirSource() throws {
        func json(_ trigger: VoiceTakeTrigger) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? NSDictionary)
        }
        XCTAssertEqual(try json(.wake(score: 0.61, phrase: "Hey Jarvis")),
                       ["source": "wake", "score": 0.61, "phrase": "Hey Jarvis"])
        XCTAssertEqual(try json(.orb), ["source": "orb"])
        XCTAssertEqual(try json(.socket(action: "ask")), ["source": "socket", "action": "ask"])
        XCTAssertEqual(try json(.key(.alternate, retargeted: true)),
                       ["source": "key", "gesture": "alternate", "retargeted": true])
        for trigger: VoiceTakeTrigger in [.wake(score: 0.61, phrase: "Hey Jarvis"), .orb, .socket(action: "dictate"),
                                          .key(.primary, retargeted: false)] {
            XCTAssertEqual(try JSONDecoder().decode(VoiceTakeTrigger.self, from: JSONEncoder().encode(trigger)), trigger)
        }
    }

    func testATriggerFromANewerBuildIsKeptAsItWas() throws {
        let newer = #"{"source":"telepathy","strength":3,"detail":{"seen":[1,true,null,"x"]}}"#
        let trigger = try JSONDecoder().decode(VoiceTakeTrigger.self, from: Data(newer.utf8))
        XCTAssertEqual(trigger.source, "telepathy")
        XCTAssertEqual(trigger.summary, "telepathy")
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? NSDictionary
        XCTAssertEqual(again, try JSONSerialization.jsonObject(with: Data(newer.utf8)) as? NSDictionary,
                       "encoded back unchanged")
        XCTAssertEqual(try JSONDecoder().decode(VoiceTakeTrigger.self, from: JSONEncoder().encode(trigger)), trigger)
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
