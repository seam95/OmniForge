import Foundation

/// 一次反应气泡的定格内容：反应开始时确定，整个反应期不变。
struct PetBubbleContent: Equatable {
    let kind: PetReactionKind
    let text: String
}

/// 事件 → 气泡文案的纯映射：变体由注入的 roll（0..<1）二选一，测试可钉死。
/// 限额类文案组合「平台 + 窗口」标签（如 "Claude 7d"），与重置 toast 同一口径；
/// 未映射事件（三期 Agent 预留）返回 nil——调用方只在反应被接受时才取文案。
enum PetBubbleCopy {
    static func text(
        for event: PetExternalEvent,
        strings: Strings,
        variantRoll: Double
    ) -> String? {
        let secondVariant = variantRoll >= 0.5
        switch event {
        case .celebrationTriggered(let quotaLabel):
            return secondVariant
                ? String(format: strings.desktopPetBubbleResetFormat2, quotaLabel)
                : String(format: strings.desktopPetBubbleResetFormat1, quotaLabel)
        case .attentionRequested(let quotaLabel):
            return secondVariant
                ? String(format: strings.desktopPetBubbleLowFormat2, quotaLabel)
                : String(format: strings.desktopPetBubbleLowFormat1, quotaLabel)
        case .loadSurged:
            return secondVariant ? strings.desktopPetBubbleHeat2 : strings.desktopPetBubbleHeat1
        case .clipboardActivity:
            return secondVariant ? strings.desktopPetBubbleClipboard2 : strings.desktopPetBubbleClipboard1
        case .inputLockChanged(let locked):
            // 锁定 → 守护文案；解锁映射为 celebrate，用「回来了」文案（无额度标签）。
            if locked {
                return secondVariant
                    ? strings.desktopPetBubbleLocked2
                    : strings.desktopPetBubbleLocked1
            }
            return secondVariant
                ? strings.desktopPetBubbleUnlocked2
                : strings.desktopPetBubbleUnlocked1
        case .activityStarted, .activityEnded:
            return nil
        }
    }
}
