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
    // CPU 高负载累计时长（秒）与上次采样时刻；冷却武装标记。
    private var highLoadAccumulated: TimeInterval = 0
    private var lastCPUSampleAt: Date?
    private var loadCooldownActive = false
    // 输入法边沿。
    private var lastInputLocked: Bool?
    // 剪贴板首条目基线（id + 时间戳）；首帧发射只建基线不触发。
    private var clipboardBaselineEstablished = false
    private var lastHeadID: UUID?
    private var lastHeadCreatedAt: Date?

    /// 判定阈值（点值便于测试覆盖）。
    static let shortageThresholdPercent = 10.0
    static let highLoadThresholdPercent = 80.0
    static let loadRecoveryThresholdPercent = 60.0
    /// 高负载持续窗口（秒）：按真实时长累计，判定不随采样频率漂移。
    static let highLoadSustainDuration: TimeInterval = 10
    /// 可计入持续窗口的采样间隔上限（秒）：超过视为采样中断，间隙时长不计（高负载状态未知）。
    static let maxSampleGap: TimeInterval = 5

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

    /// CPU 采样：按真实时长累计高负载（≥80% 累计满 `highLoadSustainDuration` 秒触发，
    /// 判定口径不随采样频率漂移——面板打开导致的刷新加速不会缩短时间窗）；
    /// 采样间隔超过 `maxSampleGap` 视为中断，该段时长不计入（暂停期状态未知）；
    /// 触发后 600s 冷却；降至 ≤60% 清零累计并解除冷却（施密特回滞）。
    func handleCPUSample(percent: Double) {
        let timestamp = now()
        let gap = lastCPUSampleAt.map { timestamp.timeIntervalSince($0) } ?? 0
        lastCPUSampleAt = timestamp

        if percent <= Self.loadRecoveryThresholdPercent {
            // 回滞清零：累计与冷却一并解除（SPEC：降至 60% 以下后下次再高可再触发）。
            highLoadAccumulated = 0
            loadCooldownActive = false
            lastFired[.load] = nil
            return
        }
        guard percent >= Self.highLoadThresholdPercent else {
            // 60%-80% 之间：不累计也不清零（回滞缓冲区）。
            return
        }
        // 只累计连续覆盖的采样时长：间隔异常大说明采样中断过，不计入窗口。
        if gap > 0, gap <= Self.maxSampleGap {
            highLoadAccumulated += gap
        }
        guard highLoadAccumulated >= Self.highLoadSustainDuration else { return }
        highLoadAccumulated = 0
        guard !loadCooldownActive, passCooldown(.load) else { return }
        if sink(.loadSurged) {
            markFired(.load)
            loadCooldownActive = true
        }
    }

    /// 剪贴板首条目变化：出现新 id 且时间戳不早于旧首条视为新复制，60s 冷却。
    /// 判据取「首条目 id 边沿 + 时间戳不回退」而非条目数：达上限去旧时数量不增（不漏报），
    /// 清空历史时首条换成旧条目、时间戳回退（不误报），去重置顶时 id 复用（不误报）。
    /// 首帧发射只建基线不触发（订阅瞬间不得因已有历史而反应）。
    func handleClipboardHead(id: UUID?, createdAt: Date?) {
        defer {
            lastHeadID = id
            lastHeadCreatedAt = createdAt
            clipboardBaselineEstablished = true
        }
        guard clipboardBaselineEstablished, let id, let createdAt, id != lastHeadID else { return }
        // 时间戳回退 = 清空历史后旧条目回填首位的假边沿。
        if let lastCreatedAt = lastHeadCreatedAt, createdAt < lastCreatedAt { return }
        guard passCooldown(.clipboard) else { return }
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
        highLoadAccumulated = 0
        lastCPUSampleAt = nil
        loadCooldownActive = false
        lastInputLocked = nil
        clipboardBaselineEstablished = false
        lastHeadID = nil
        lastHeadCreatedAt = nil
    }
}
