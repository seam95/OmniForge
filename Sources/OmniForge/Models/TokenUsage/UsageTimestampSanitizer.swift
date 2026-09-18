import Foundation

/// 外部用量数据时间戳的统一清洗入口。
///
/// 上游 CLI 的 JSONL 与 Trae CN 用量 API 都是不受信任的数据源：
/// 单行坏数据（NaN / Inf / 1e300 级数值）一旦直接 `Int(Double)` 即
/// fatal error，整个菜单栏应用随之崩溃——这是外部信任链的最后一环。
/// 各 provider 的 bucketStart 统一走本入口，非法/超界返回 nil，
/// 由调用方按「丢弃该行」处理。
enum UsageTimestampSanitizer {
    /// 上界 2100-01-01（Unix 秒）：再晚必然是坏数据（如毫秒误传到秒位）。
    private static let maximumEpochSeconds = 4_102_444_800.0

    /// 毫秒时间戳 → Unix 秒；非法返回 nil。
    static func epochSeconds(fromMilliseconds ms: Double) -> Int? {
        guard ms.isFinite, ms > 0 else { return nil }
        return epochSeconds(ms / 1000)
    }

    /// 秒时间戳清洗；非法返回 nil。
    static func epochSeconds(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds > 0, seconds <= maximumEpochSeconds else { return nil }
        return Int(exactly: seconds.rounded(.down))
    }
}
