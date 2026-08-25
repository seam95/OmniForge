import Foundation

/// 一次限额窗口重置事件 — 窗口 rollover 且用量明显下降后产生。
struct LimitResetEvent: Equatable {
    let provider: TokenUsageProvider
    /// 持久化身份键（如 "codex.weekly"、"claude.labeled.Opus"），永不变更。
    let windowKey: String
    /// 展示名（如 "7d"、"5h"、"Gemini 5h"），用于庆祝 toast 文案。
    let windowLabel: String
    let previousPercent: Double
}

/// 检测限额窗口「重置」（rollover）— 移植 TokenTracker `WeeklyLimitResetDetector`。
///
/// 判据：窗口的 `resetAt` 前进超过容差（确认真 rollover），且已用百分比下降超过
/// `minDrop`（确认窗口确实清空，兼防 resetAt 持续滑动的 provider 误报）。
/// 首次观测只记基线不触发；事件按窗口键防抖（`cooldown` 内不重复）。
struct LimitResetDetector {

    /// 真实 rollover 必须让用量至少下降这么多（百分点）— 确认窗口被清空。
    var minDrop: Double = 5
    /// 窗口 `resetAt` 必须至少前进这么多（秒）才算真 rollover — 过滤时间戳抖动。
    var resetAdvanceTolerance: TimeInterval = 60
    /// 触发后同一窗口在冷却期内不重复触发。
    var cooldown: TimeInterval = 3600

    struct Snapshot: Codable, Equatable {
        var lastPercent: [String: Double] = [:]
        var lastEventAt: [String: Double] = [:]   // unix 秒
        var lastResetAt: [String: Double] = [:]   // unix 秒 — 上次见到的窗口 reset_at

        init() {}

        /// 容忍旧快照缺少 `lastResetAt`（或任一字段），升级后保留既有基线与冷却记忆。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastPercent = try container.decodeIfPresent([String: Double].self, forKey: .lastPercent) ?? [:]
            lastEventAt = try container.decodeIfPresent([String: Double].self, forKey: .lastEventAt) ?? [:]
            lastResetAt = try container.decodeIfPresent([String: Double].self, forKey: .lastResetAt) ?? [:]
        }
    }

    /// 给定持久化快照与当前读数，返回需要庆祝的事件 + 下一次持久化的快照。
    /// 快照即上一次读数的记忆，调用方无需自行跟踪历史响应。
    func evaluate(
        readings: [(provider: TokenUsageProvider, windowKey: String, windowLabel: String, usedPercent: Double, resetAt: Double?)],
        snapshot: Snapshot,
        now: Double
    ) -> (events: [LimitResetEvent], snapshot: Snapshot) {
        var updated = snapshot
        var events: [LimitResetEvent] = []

        for reading in readings {
            let key = reading.windowKey
            let prevPercent = snapshot.lastPercent[key]
            let prevReset = snapshot.lastResetAt[key]
            updated.lastPercent[key] = reading.usedPercent
            if let resetAt = reading.resetAt {
                updated.lastResetAt[key] = resetAt   // 缺省时保留旧值
            }

            // 需要完整的历史基线（百分比 + 重置时间）与当前重置时间。
            // 首次观测或窗口无重置时间戳：只记基线，绝不庆祝。
            guard let prevPercent, let prevReset, let curReset = reading.resetAt else { continue }
            // 窗口必须真的 rollover：reset_at 前进到新周期，而非仅百分比下降。
            guard curReset > prevReset + resetAdvanceTolerance else { continue }
            // 且 rollover 真的清空了窗口（兼防 resetAt 连续滑动的 provider 误报）。
            guard prevPercent - reading.usedPercent >= minDrop else { continue }
            if let last = snapshot.lastEventAt[key], now - last < cooldown { continue }

            updated.lastEventAt[key] = now
            events.append(LimitResetEvent(
                provider: reading.provider,
                windowKey: key,
                windowLabel: reading.windowLabel,
                previousPercent: prevPercent
            ))
        }

        return (events, updated)
    }
}

// MARK: - 持久化

extension LimitResetDetector {
    static let snapshotKey = "OmniForge.tokenLimitResetSnapshot"

    static func loadSnapshot(_ defaults: UserDefaults = .standard) -> Snapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: Snapshot, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }
}

// MARK: - 读数提取

extension Dictionary where Key == TokenUsageProvider, Value == ProviderUsageLimits {
    /// 把各 provider 的限额窗口拍平为检测器读数，跳过未配置或出错（无窗口）的快照。
    /// `windowKey` 是持久化身份（基线与防抖），永不变更；`windowLabel` 用于庆祝 toast 文案。
    /// 数值口径统一为已用百分比（0…100），resetAt 为 unix 秒。
    func limitResetReadings(strings: Strings) -> [(provider: TokenUsageProvider, windowKey: String, windowLabel: String, usedPercent: Double, resetAt: Double?)] {
        var out: [(provider: TokenUsageProvider, windowKey: String, windowLabel: String, usedPercent: Double, resetAt: Double?)] = []

        for (provider, limits) in self {
            guard limits.configured, limits.issue == nil else { continue }

            for (kind, window) in limits.windows {
                let label = kind.shortTitle(for: provider, strings: strings)
                out.append((
                    provider,
                    "\(provider.rawValue).\(kind.rawValue)",
                    label,
                    window.usedPercent,
                    window.resetAt?.timeIntervalSince1970
                ))
            }
            for entry in limits.labeledWindows ?? [] {
                out.append((
                    provider,
                    "\(provider.rawValue).labeled.\(entry.label)",
                    entry.label,
                    entry.window.usedPercent,
                    entry.window.resetAt?.timeIntervalSince1970
                ))
            }
        }

        return out
    }
}
