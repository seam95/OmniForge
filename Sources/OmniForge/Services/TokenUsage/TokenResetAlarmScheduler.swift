import Combine
import Foundation

/// 单发墙钟闹钟调度抽象（测试注入用）。
protocol OneShotAlarmScheduling: AnyObject {
    /// 在指定墙钟时刻触发一次 action；返回的 cancellable 取消后不再触发。
    /// 生产实现保证回调落在主线程。
    func schedule(at deadline: Date, _ action: @escaping () -> Void) -> AnyCancellable
}

/// DispatchSourceTimer + wall clock 的单发闹钟：睡眠期间墙钟照走，
/// 唤醒后 deadline 已过则立即触发——「睡眠错过时刻」由此天然覆盖，
/// 触发端再按宽限过滤（`TokenResetAlarmScheduler.fireGrace`）。
final class WallClockOneShotScheduler: OneShotAlarmScheduling {
    func schedule(at deadline: Date, _ action: @escaping () -> Void) -> AnyCancellable {
        let timer = DispatchSource.makeTimerSource()
        let delayMs = Int(max(0, deadline.timeIntervalSinceNow) * 1000)
        // DispatchWallTime 重载走墙钟：睡眠期间照走，唤醒后 deadline 已过立即触发。
        timer.schedule(deadline: .now() + .milliseconds(delayMs), repeating: .never, leeway: .seconds(1))
        // 回调统一回主线程：消费方（TokenResetAlarmScheduler）是 @MainActor。
        timer.setEventHandler { DispatchQueue.main.async(execute: action) }
        timer.resume()
        return AnyCancellable { timer.cancel() }
    }
}

/// 额度重置静默闹钟 — 面板关闭期间按窗口 `resetAt` 建墙钟闹钟：
/// 到点前 1 分钟校准（单 provider 拉取，漂移则重设闹钟继续循环），
/// 到点直提醒。冷启动从持久化记录恢复，不触网、不读 Keychain（SPEC §3）。
@MainActor
final class TokenResetAlarmScheduler {

    /// 单窗口闹钟记录（持久化供冷启动恢复）。
    struct AlarmRecord: Codable, Equatable {
        let provider: TokenUsageProvider
        /// 持久化身份键（与 LimitResetDetector 的 windowKey 同口径）。
        let windowKey: String
        /// 展示名（庆祝 toast 文案用）。
        let windowLabel: String
        /// 窗口重置时刻（unix 秒；漂移重设时更新）。
        var resetAt: Double
        /// 最近一次同步时的已用百分比（到点门槛判断）。
        var usedPercent: Double
    }

    /// 到点前的校准提前量（秒）：resetAt − 60s 触发单 provider 校准拉取。
    private let calibrateLead: TimeInterval = 60
    /// 触发时距 resetAt 超过该值不再补播（睡眠/关机宽限，秒）。
    private let fireGrace: TimeInterval = 300
    /// resetAt 漂移容差（秒）：小于该值不重设闹钟，过滤时间戳抖动。
    private let driftTolerance: TimeInterval = 60

    /// 校准点触发：拉取该 provider 限额（force；429 冷却仍生效）。
    /// 回包走 `sync(limits:)` — 漂移则重设闹钟，未漂移则原闹钟保持。
    var onCalibrate: ((TokenUsageProvider) -> Void)?
    /// 到点触发：静默提醒 + 拉取建立下一周期基线（均由消费方执行）。
    var onFire: ((AlarmRecord) -> Void)?

    private let scheduling: OneShotAlarmScheduling
    private let defaults: UserDefaults
    private let now: () -> Date
    private let stringsProvider: () -> Strings

    /// windowKey → 记录；闹钟集合随每次限额快照全量同步。
    private var records: [String: AlarmRecord] = [:]
    private var calibrateTimers: [String: AnyCancellable] = [:]
    private var fireTimers: [String: AnyCancellable] = [:]

    static let storageKey = "OmniForge.tokenResetAlarms"

    init(
        scheduling: OneShotAlarmScheduling = WallClockOneShotScheduler(),
        defaults: UserDefaults = .standard,
        stringsProvider: @escaping () -> Strings = { L10n().s },
        now: @escaping () -> Date = { Date() }
    ) {
        self.scheduling = scheduling
        self.defaults = defaults
        self.stringsProvider = stringsProvider
        self.now = now
    }

    /// 冷启动恢复：从持久化记录重建闹钟。过期记录触发后被宽限过滤并清理，
    /// 因此长关机不会积压误报。
    func restore() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([AlarmRecord].self, from: data) else { return }
        for record in saved {
            records[record.windowKey] = record
            arm(record)
        }
    }

    /// 挂起全部闹钟（功能停用）；`restore()` 从持久化重新拉起。
    func suspend() {
        for key in records.keys {
            calibrateTimers.removeValue(forKey: key)?.cancel()
            fireTimers.removeValue(forKey: key)?.cancel()
        }
        records.removeAll()
    }

    /// 全量同步窗口闹钟（随 TokenUsageManager.apply 调用）。
    ///
    /// 两个口径分开：建/更新闹钟只认健康快照（`limitResetReadings` 过滤未配置/
    /// issue 态）；**保留判断**放宽到「已配置且窗口仍存在」— 校准拉取失败回退的
    /// stale 快照（带 issue 但窗口来自 last-good）不清掉既有闹钟，降级路径成立。
    func sync(limits: [TokenUsageProvider: ProviderUsageLimits]) {
        let readings = limits.limitResetReadings(strings: stringsProvider())

        // 保留集：已配置 provider 的全部窗口键（含 issue 态回退）。
        var retain = Set<String>()
        for (provider, limit) in limits where limit.configured {
            for kind in limit.windows.keys {
                retain.insert("\(provider.rawValue).\(kind.rawValue)")
            }
            for entry in limit.labeledWindows ?? [] {
                retain.insert("\(provider.rawValue).labeled.\(entry.label)")
            }
        }

        for reading in readings {
            // 无重置时刻的窗口无法建闹钟（既有闹钟保留，等下个周期数据修正）。
            guard let resetAt = reading.resetAt else { continue }

            if var record = records[reading.windowKey] {
                // 百分比始终跟进（到点门槛用最新值）；漂移超容差才重设闹钟。
                record.usedPercent = reading.usedPercent
                if abs(resetAt - record.resetAt) > driftTolerance {
                    record.resetAt = resetAt
                    arm(record)
                }
                records[reading.windowKey] = record
            } else {
                arm(AlarmRecord(
                    provider: reading.provider,
                    windowKey: reading.windowKey,
                    windowLabel: reading.windowLabel,
                    resetAt: resetAt,
                    usedPercent: reading.usedPercent
                ))
            }
        }

        // 窗口真正消失（provider 未配置 / 快照不再包含）→ 移除闹钟。
        for key in records.keys where !retain.contains(key) {
            remove(key)
        }
        persist()
    }

    // MARK: - 内部

    /// 按记录布防两个闹钟：校准点（resetAt − lead，已过期则跳过）与触发点（resetAt）。
    private func arm(_ record: AlarmRecord) {
        let key = record.windowKey
        calibrateTimers.removeValue(forKey: key)?.cancel()
        fireTimers.removeValue(forKey: key)?.cancel()
        records[key] = record

        let resetDate = Date(timeIntervalSince1970: record.resetAt)
        let calibrateDate = resetDate.addingTimeInterval(-calibrateLead)
        if calibrateDate > now() {
            calibrateTimers[key] = scheduling.schedule(at: calibrateDate) { [weak self] in
                guard let self else { return }
                self.calibrateTimers[key] = nil
                self.onCalibrate?(record.provider)
                // 回包走 sync：漂移则重设闹钟，未漂移则下方 fire 闹钟保持原时刻。
            }
        }
        fireTimers[key] = scheduling.schedule(at: resetDate) { [weak self] in
            self?.fire(key: key)
        }
    }

    /// 触发点：宽限外（睡眠/关机太久）只清理不补播；宽限内回调并清理，
    /// 下一周期闹钟由消费方的到点后拉取 → sync 重建。
    /// 记录从 `records` 现取（小抖动不重设闹钟，但百分比已跟进）。
    private func fire(key: String) {
        calibrateTimers.removeValue(forKey: key)?.cancel()
        fireTimers[key] = nil
        guard let record = records[key] else { return }
        records[key] = nil
        persist()

        let lag = now().timeIntervalSince(Date(timeIntervalSince1970: record.resetAt))
        guard lag <= fireGrace else { return }
        onFire?(record)
    }

    private func remove(_ key: String) {
        calibrateTimers.removeValue(forKey: key)?.cancel()
        fireTimers.removeValue(forKey: key)?.cancel()
        records[key] = nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
