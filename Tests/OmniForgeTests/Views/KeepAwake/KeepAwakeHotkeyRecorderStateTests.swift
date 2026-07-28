import Carbon
import XCTest
@testable import OmniForge

@MainActor
final class KeepAwakeHotkeyRecorderStateTests: XCTestCase {

    // MARK: - 初始状态

    func test_initialStateIsIdleWithPersistedHotkey() {
        let persisted = HotkeyDefinition.defaultKeepAwake
        let state = KeepAwakeHotkeyRecorderState(initial: persisted, apply: { _ in })

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.hotkey, persisted)
    }

    // MARK: - 聚焦开始录制

    func test_beginRecordingMovesToRecordingPhase() {
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake, apply: { _ in })

        state.beginRecording()

        XCTAssertEqual(state.phase, .recording)
    }

    // MARK: - 取消回到 idle，不更新配置

    func test_cancelReturnsToIdleWithoutApplyingChange() {
        var applied: [HotkeyDefinition] = []
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake) { applied.append($0) }

        state.beginRecording()
        state.cancel()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.hotkey, .defaultKeepAwake)
        XCTAssertTrue(applied.isEmpty, "取消不应调用 apply")
    }

    // MARK: - 清除：回到 idle，state 不模拟 apply（由 view 直接清空 UserDefaults）

    func test_clearReturnsToIdleWithoutApplying() {
        var applied: [HotkeyDefinition] = []
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake) { applied.append($0) }

        state.beginRecording()
        state.clear()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(applied.isEmpty, "清除不是有效的 apply；state 不应模拟 apply")
    }

    // MARK: - modifier-only 输入：拒绝，留在 recording

    func test_modifierOnlyEventIsRejectedAndStaysRecording() {
        var applied: [HotkeyDefinition] = []
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake) { applied.append($0) }

        state.beginRecording()
        let event = makeEvent(keyCode: UInt16(kVK_Shift), modifiers: [.shift])
        let handled = state.consume(event)

        XCTAssertFalse(handled, "modifier-only 应被识别为修饰键事件，不视为完成录制")
        XCTAssertEqual(state.phase, .recording, "录制中状态保持")
        XCTAssertTrue(applied.isEmpty)
    }

    // MARK: - 有效组合：capture 并 apply

    func test_validCombinationCapturesAndApplies() {
        var applied: [HotkeyDefinition] = []
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake) { applied.append($0) }

        state.beginRecording()
        let event = makeEvent(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .option])
        let handled = state.consume(event)

        XCTAssertTrue(handled)
        XCTAssertEqual(state.phase, .idle)
        let expected = HotkeyDefinition(keyCode: Int(kVK_ANSI_J), modifiers: [.command, .option])
        XCTAssertEqual(state.hotkey, expected)
        XCTAssertEqual(applied, [expected])
    }

    // MARK: - 非录制状态下 consume 不处理

    func test_consumeWhileIdleReturnsFalse() {
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake, apply: { _ in })
        let event = makeEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])

        XCTAssertFalse(state.consume(event))
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Esc 在录制中等价取消

    func test_escapeDuringRecordingCancels() {
        var applied: [HotkeyDefinition] = []
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake) { applied.append($0) }

        state.beginRecording()
        let esc = makeEvent(keyCode: UInt16(kVK_Escape), modifiers: [])
        _ = state.consume(esc)

        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(applied.isEmpty)
    }

    // MARK: - 路径无 KeyboardShortcuts：apply 闭包只接收 HotkeyDefinition

    func test_applyOnlyReceivesHotkeyDefinition() {
        // 纯状态测试：通过计数器确认 apply 闭包只接收 HotkeyDefinition，
        // 没有 KeyboardShortcuts.Shortcut 等外部类型参与。
        var callCount = 0
        var lastArg: HotkeyDefinition?
        let state = KeepAwakeHotkeyRecorderState(initial: .defaultKeepAwake) { def in
            callCount += 1
            lastArg = def
        }

        state.beginRecording()
        let event = makeEvent(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option, .command])
        _ = state.consume(event)

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(lastArg, .defaultKeepAwake)
    }

    // MARK: - 辅助

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
