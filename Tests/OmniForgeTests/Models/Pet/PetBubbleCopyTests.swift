import XCTest
@testable import OmniForge

/// 气泡文案映射测试：事件 → 双候选文案、额度标签组合、解锁/锁定区分。
final class PetBubbleCopyTests: XCTestCase {
    private let strings = Strings.zhHans

    private func text(
        _ event: PetExternalEvent,
        roll: Double
    ) -> String? {
        PetBubbleCopy.text(for: event, strings: strings, variantRoll: roll)
    }

    // MARK: - 限额类（组合「平台 + 窗口」标签）

    func test_resetComposesQuotaLabelVariants() {
        let event = PetExternalEvent.celebrationTriggered(quotaLabel: "Claude 7d")
        XCTAssertEqual(text(event, roll: 0.1), "Claude 7d 额度重置啦！")
        XCTAssertEqual(text(event, roll: 0.9), "Claude 7d 又满血啦！")
    }

    func test_attentionComposesQuotaLabelVariants() {
        let event = PetExternalEvent.attentionRequested(quotaLabel: "DeepSeek 5h")
        XCTAssertEqual(text(event, roll: 0.1), "DeepSeek 5h 额度快见底了…")
        XCTAssertEqual(text(event, roll: 0.9), "DeepSeek 5h 得省着点用了")
    }

    // MARK: - 输入法（锁定守护 / 解锁归来，无额度标签）

    func test_inputLockLockedUsesGuardCopy() {
        let event = PetExternalEvent.inputLockChanged(locked: true)
        XCTAssertEqual(text(event, roll: 0.1), "看好你的键盘！")
        XCTAssertEqual(text(event, roll: 0.9), "键盘由我守护！")
    }

    func test_inputLockUnlockUsesReturnCopy() {
        // 解锁映射为 celebrate 反应，但文案走「回来了」而非额度重置。
        let event = PetExternalEvent.inputLockChanged(locked: false)
        XCTAssertEqual(text(event, roll: 0.1), "我回来啦~")
        XCTAssertEqual(text(event, roll: 0.9), "解锁，我回来啦！")
    }

    // MARK: - 感官类

    func test_heatAndClipboardVariants() {
        XCTAssertEqual(text(.loadSurged, roll: 0.1), "CPU 好烫…")
        XCTAssertEqual(text(.loadSurged, roll: 0.9), "热得受不了啦")
        XCTAssertEqual(text(.clipboardActivity, roll: 0.1), "又复制了什么？")
        XCTAssertEqual(text(.clipboardActivity, roll: 0.9), "让我瞅瞅~")
    }

    // MARK: - 未映射事件

    func test_unmappedEventsReturnNil() {
        XCTAssertNil(text(.activityStarted(kind: .thinking), roll: 0.1))
        XCTAssertNil(text(.activityEnded(kind: .working), roll: 0.9))
    }
}
