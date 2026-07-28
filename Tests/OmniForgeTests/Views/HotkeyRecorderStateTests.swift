import AppKit
import Carbon
import XCTest
import KeyboardShortcuts
@testable import OmniForge

@MainActor
final class HotkeyRecorderStateTests: XCTestCase {
    func test_initialStateIsIdleWithProvidedDisplayText() {
        let state = HotkeyRecorderState(initialDisplayText: "F2", apply: { _ in })

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.displayText, "F2")
    }

    func test_beginRecordingMovesToRecordingPhase() {
        let state = HotkeyRecorderState(initialDisplayText: "F2", apply: { _ in })

        state.beginRecording()

        XCTAssertEqual(state.phase, .recording)
    }

    func test_cancelReturnsToIdleWithoutApplyingChange() {
        var applied: [KeyboardShortcuts.Shortcut?] = []
        let state = HotkeyRecorderState(initialDisplayText: "F2") { applied.append($0) }

        state.beginRecording()
        state.cancel()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.displayText, "F2")
        XCTAssertTrue(applied.isEmpty)
    }

    func test_modifierOnlyEventIsRejectedAndStaysRecording() {
        var applied: [KeyboardShortcuts.Shortcut?] = []
        let state = HotkeyRecorderState(initialDisplayText: "F2") { applied.append($0) }

        state.beginRecording()
        let event = makeEvent(keyCode: UInt16(kVK_Shift), modifiers: [.shift])
        let handled = state.consume(event)

        XCTAssertFalse(handled)
        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(state.displayText, "F2")
        XCTAssertTrue(applied.isEmpty)
    }

    func test_validCombinationCapturesAndApplies() {
        var applied: [KeyboardShortcuts.Shortcut?] = []
        let state = HotkeyRecorderState(initialDisplayText: "F2") { applied.append($0) }

        state.beginRecording()
        let event = makeEvent(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .option])
        let handled = state.consume(event)

        XCTAssertTrue(handled)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.displayText, "⌥⌘J")
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0]?.carbonKeyCode, Int(kVK_ANSI_J))
        XCTAssertEqual(applied[0]?.modifiers, [.command, .option])
    }

    func test_escapeDuringRecordingCancelsWithoutApplying() {
        var applied: [KeyboardShortcuts.Shortcut?] = []
        let state = HotkeyRecorderState(initialDisplayText: "F2") { applied.append($0) }

        state.beginRecording()
        let event = makeEvent(keyCode: UInt16(kVK_Escape), modifiers: [])
        let handled = state.consume(event)

        XCTAssertTrue(handled)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.displayText, "F2")
        XCTAssertTrue(applied.isEmpty)
    }

    func test_syncDisplayTextUpdatesOnlyWhileIdle() {
        let state = HotkeyRecorderState(initialDisplayText: "F2", apply: { _ in })

        state.syncDisplayText("⌃⌥⌘D")
        XCTAssertEqual(state.displayText, "⌃⌥⌘D")

        state.beginRecording()
        state.syncDisplayText("F8")
        XCTAssertEqual(state.displayText, "⌃⌥⌘D")
    }

    private func makeEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
