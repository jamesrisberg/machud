import AppKit
import XCTest
@testable import VoiceHostCore

/// The conversation panel's keyboard: Return, Shift-Return, ↑, ⌘K, ⌘Y/⌘N and the standard
/// edit commands, driven as AppKit delivers them, in a window that is never shown.
@MainActor
final class ConversationViewTests: XCTestCase {
    private var window: NSWindow!
    private var panel: ConversationPanelView!
    private var sent: [String] = []
    private var refusal: String?
    private var approved: [String] = []
    private var denied: [String] = []
    private var shift = false

    override func setUp() async throws {
        panel = ConversationPanelView(frame: CGRect(x: 0, y: 0, width: 640, height: 500))
        panel.panelWidth = 640
        window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        sent = []
        refusal = nil
        approved = []
        denied = []
        shift = false
        panel.onSend = { [unowned self] text in
            sent.append(text)
            return refusal
        }
        panel.onApprove = { [unowned self] in approved.append($0) }
        panel.onDeny = { [unowned self] in denied.append($0) }
        panel.isShiftDown = { [unowned self] in shift }
        panel.update(rows: [], mode: .expanded, busy: false, sessionLink: nil)
        XCTAssertTrue(window.makeFirstResponder(panel.composer))
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func command(_ selector: Selector) -> Bool {
        panel.textView(panel.composer, doCommandBy: selector)
    }

    private func key(_ character: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
    }

    func testReturnSendsAndClearsTheField() {
        panel.composerText = "list my files"
        XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sent, ["list my files"])
        XCTAssertEqual(panel.composerText, "")
    }

    func testShiftReturnStartsANewLine() {
        panel.composerText = "first"
        shift = true
        XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(panel.composerText, "first\n")
    }

    func testUpInAnEmptyFieldRecallsTheLastMessage() {
        panel.composerText = "hello"
        _ = command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(command(#selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(panel.composerText, "hello")
        XCTAssertFalse(command(#selector(NSResponder.moveUp(_:))), "↑ moves the caret once there is text")
    }

    func testARefusedMessageStaysInTheFieldWithTheReason() {
        refusal = VoiceHostController.agentBusy
        panel.composerText = "and then?"
        _ = command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(panel.composerText, "and then?")
        XCTAssertEqual(panel.statusText, VoiceHostController.agentBusy)
    }

    func testAMessageTheBrainRefusesComesBackToTheField() {
        panel.composerText = "hello"
        _ = command(#selector(NSResponder.insertNewline(_:)))
        var pending = ConversationRow.user(id: "p", text: "hello", source: .typed)
        pending.pending = true
        panel.update(rows: [pending], mode: .expanded, busy: false, sessionLink: nil)
        XCTAssertEqual(panel.composerText, "")
        panel.update(rows: [], mode: .expanded, busy: false, sessionLink: nil, errorMessage: "Companion (409): busy")
        XCTAssertEqual(panel.composerText, "hello")
        XCTAssertEqual(panel.statusText, "Companion (409): busy")
    }

    func testAMessageTheBrainTakesStaysSent() {
        panel.composerText = "hello"
        _ = command(#selector(NSResponder.insertNewline(_:)))
        var pending = ConversationRow.user(id: "p", text: "hello", source: .typed)
        pending.pending = true
        panel.update(rows: [pending], mode: .expanded, busy: false, sessionLink: nil)
        panel.update(rows: [.user(id: "u", text: "hello", source: .typed)], mode: .expanded, busy: true, sessionLink: nil)
        XCTAssertEqual(panel.composerText, "")
    }

    func testAFailureShowsAboveTheFieldUntilItPasses() {
        panel.update(rows: [], mode: .expanded, busy: false, sessionLink: nil, errorMessage: "The brain stopped")
        XCTAssertEqual(panel.statusText, "The brain stopped")
        panel.update(rows: [], mode: .expanded, busy: false, sessionLink: nil, errorMessage: nil)
        XCTAssertNil(panel.statusText)
    }

    func testCommandKClearsTheFieldEvenWithCapsLock() {
        panel.composerText = "draft"
        XCTAssertTrue(panel.performKeyEquivalent(with: key("k", [.command, .capsLock])))
        XCTAssertEqual(panel.composerText, "")
    }

    func testCommandYAndNAnswerTheNewestApproval() {
        let rows = [
            ConversationRow(id: "1", kind: .approval, text: "Old", approvalId: "a1", decision: .allowed),
            ConversationRow(id: "2", kind: .approval, text: "Delete?", approvalId: "a2", decision: .pending),
        ]
        panel.update(rows: rows, mode: .expanded, busy: true, sessionLink: nil)
        XCTAssertTrue(panel.performKeyEquivalent(with: key("y", .command)))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("n", .command)))
        XCTAssertEqual(approved, ["a2"])
        XCTAssertEqual(denied, ["a2"])
    }

    func testTheStandardEditCommandsReachTheField() {
        panel.composerText = "select me"
        panel.composer.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("a", .command)), "⌘A does not beep")
        XCTAssertEqual(panel.composer.selectedRange(), NSRange(location: 0, length: 9))
        XCTAssertEqual(ConversationPanelView.editAction(for: key("v", .command)), #selector(NSText.paste(_:)))
        XCTAssertEqual(ConversationPanelView.editAction(for: key("c", [.command, .capsLock])), #selector(NSText.copy(_:)))
        XCTAssertEqual(ConversationPanelView.editAction(for: key("x", .command)), #selector(NSText.cut(_:)))
        XCTAssertEqual(ConversationPanelView.editAction(for: key("z", .command)), Selector(("undo:")))
        XCTAssertEqual(ConversationPanelView.editAction(for: key("z", [.command, .shift])), Selector(("redo:")))
        XCTAssertNil(ConversationPanelView.editAction(for: key("q", .command)), "no ⌘Q: it would quit the voice host")
        XCTAssertTrue(panel.composer.responds(to: #selector(NSText.paste(_:))))
    }
}
