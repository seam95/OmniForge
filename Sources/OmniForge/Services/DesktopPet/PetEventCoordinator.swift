import Foundation

/// 事件协调器：订阅应用内数据源 → 冷却 / 下降沿 / 持续窗口裁决 → 投递给宠物。
/// 不持有任何数据源（由组合根喂数），时钟与出口可注入，全量单测。
/// 冷却参数取业界共识值：提醒类 600s（两家同类产品同值）、感官类 60s、事件型（重置/输入法）不冷却。
@MainActor
final class PetEventCoordinator {
    /// 冷却通道（按反应类别划分）。
    enum CooldownChannel: String, Hashable, CaseIterable {
        case attention
        case load
        case clipboard

        /// 通道冷却时长（秒）。
        var cooldown: TimeInterval {
            switch self {
            case .attention: return 600
            case .load: return 600
            case .clipboard: return 60
            }
        }
    }

    private let now: () -> Date
    /// 事件出口（接 `DesktopPetManager.submit`），返回是否被引擎接受。
    private let sink: (PetExternalEvent) -> Bool

    private var lastFired: [CooldownChannel: Date] = [:]

    // 告急下降沿：上次已知的最小剩余百分比（nil = 尚无数据）。
    private var lastShortagePercent: Double?
    // CPU 连续超阈计数与冷却武装。
    private var highLoadStreak = 0
    private var loadCooldownActive = false
    // 输入法边沿。
    private var lastInputLocked: Bool?
    // 剪贴板条目数基线。
    private var lastEntryCount: Int?

    /// 判定阈值（点值便于测试覆盖）。
    static let shortageThresholdPercent = 10.0
    static let highLoadThresholdPercent = 80.0
    static let loadRecoveryThresholdPercent = 60.0
    static let highLoadStreakLimit = 5

    init(
        now: @escaping () -> Date = Date.init,
        sink: @escaping (PetExternalEvent) -> Bool
    ) {
        self.now = now
        self.sink = sink
    }

    // MARK: - 数据入口（组合根订阅调用）

    /// 限额重置（onCelebrate）：事件天然稀疏，不冷却。
    func handleLimitReset() {
        sink(.celebrationTriggered)
    }

    /// 限额刷新：`shortagePercent` 为当前各启用窗口的最小剩余百分比（nil = 无可用数据）。
    /// 下降沿触发：上次 >10% 本次 ≤10% 才提醒；已在告急区不重复。
    func handleLimitsUpdate(shortagePercent: Double?) {
        defer { lastShortagePercent = shortagePercent }
        guard let percent = shortagePercent else { return }
        let wasOutside = (lastShortagePercent ?? .infinity) > Self.shortageThresholdPercent
        let isInside = percent <= Self.shortageThresholdPercent
        guard wasOutside, isInside, passCooldown(.attention) else { return }
        if sink(.attentionRequested) {
            markFired(.attention)
        }
    }

    /// CPU 采样：连续 `highLoadStreakLimit` 次 ≥80% 触发（显式持续窗口，业界教训：单次采样即触发是反例）；
    /// 触发后 600s 冷却；降至 ≤60% 清零计数并解除冷却（施密特回滞）。
    func handleCPUSample(percent: Double) {
        if percent <= Self.loadRecoveryThresholdPercent {
            // 回滞清零：计数与冷却一并解除（SPEC：降至 60% 以下后下次再高可再触发）。
            highLoadStreak = 0
            loadCooldownActive = false
            lastFired[.load] = nil
            return
        }
        guard percent >= Self.highLoadThresholdPercent else {
            // 60%-80% 之间：不累计也不清零（回滞缓冲区）。
            return
        }
        highLoadStreak += 1
        guard highLoadStreak >= Self.highLoadStreakLimit else { return }
        highLoadStreak = 0
        guard !loadCooldownActive, passCooldown(.load) else { return }
        if sink(.loadSurged) {
            markFired(.load)
            loadCooldownActive = true
        }
    }

    /// 剪贴板条目数变化：数量增加视为新复制（粘贴回写可接受），60s 冷却。
    func handleClipboardEntries(count: Int) {
        defer { lastEntryCount = count }
        guard let last = lastEntryCount, count > last, passCooldown(.clipboard) else { return }
        if sink(.clipboardActivity) {
            markFired(.clipboard)
        }
    }

    /// 输入法锁定状态：边沿触发（用户手动操作天然稀疏，不冷却）。
    func handleInputLock(locked: Bool) {
        defer { lastInputLocked = locked }
        guard lastInputLocked != nil, lastInputLocked != locked else { return }
        sink(.inputLockChanged(locked: locked))
    }

    // MARK: - 冷却裁决

    private func passCooldown(_ channel: CooldownChannel) -> Bool {
        guard let last = lastFired[channel] else { return true }
        return now().timeIntervalSince(last) >= channel.cooldown
    }

    private func markFired(_ channel: CooldownChannel) {
        lastFired[channel] = now()
    }

    /// 重置全部裁决状态（测试与生命周期重启用）。
    func resetState() {
        lastFired.removeAll()
        lastShortagePercent = nil
        highLoadStreak = 0
        loadCooldownActive = false
        lastInputLocked = nil
        lastEntryCount = nil
    }
}
