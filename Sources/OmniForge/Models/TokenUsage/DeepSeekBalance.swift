import Foundation

// MARK: - 数据模型

/// 单币种余额行。金额是 API 返回的字符串（"110.00"），解析失败时保留原始字符串兜底展示，
/// 且该行不参与低余额判定。
struct DeepSeekBalanceInfo: Equatable {
    var currency: String
    var totalBalance: Decimal?
    var grantedBalance: Decimal?
    var toppedUpBalance: Decimal?
    var totalBalanceText: String?
}

/// `/user/balance` 响应的纯数据。
struct DeepSeekBalanceResponse: Equatable {
    var isAvailable: Bool
    var infos: [DeepSeekBalanceInfo]
}

/// 面板/经理消费的快照（对齐 `ProviderUsageLimits` 的元数据口径）。
struct DeepSeekBalanceSnapshot: Equatable {
    var configured: Bool
    var isAvailable: Bool
    var infos: [DeepSeekBalanceInfo]
    var capturedAt: Date
    var stale: Bool
    var issue: LimitError?
}

// MARK: - 设置

/// DeepSeek 余额监控设置（并入 `TokenUsageConfiguration.deepSeekBalance`，可选字段容器）。
struct DeepSeekBalanceSettings: Codable, Equatable {
    var lowBalanceAlertEnabled = true
    var lowBalanceThreshold = 1.0
    var refreshMinutes = 5

    /// 余额刷新间隔合法值（与 `TokenUsageConfiguration.allowedRefreshIntervals` 同值，测试断言防漂移）。
    static let allowedRefreshIntervals = [1, 5, 15]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lowBalanceAlertEnabled
        case lowBalanceThreshold
        case refreshMinutes
    }

    /// 手动解码：各字段缺省回默认值——保证旧配置缺少部分字段时仍能整体解码，
    /// 否则 TokenUsageConfiguration 的 `deepSeekBalance` 键一旦存在即整体解码失败，拖垮全部偏好。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lowBalanceAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .lowBalanceAlertEnabled) ?? true
        lowBalanceThreshold = try container.decodeIfPresent(Double.self, forKey: .lowBalanceThreshold) ?? 1.0
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 5
    }
}

// MARK: - 解码器

enum DeepSeekBalanceResponseDecoder {
    /// 字典 → 响应。`balance_infos` 缺失或非数组 → nil（调用方报 `.decoding`）。
    static func decode(_ object: [String: Any]) -> DeepSeekBalanceResponse? {
        guard let rawInfos = object["balance_infos"] as? [[String: Any]] else { return nil }
        let infos = rawInfos.map { raw -> DeepSeekBalanceInfo in
            let totalRaw = raw["total_balance"] as? String
            return DeepSeekBalanceInfo(
                currency: raw["currency"] as? String ?? "",
                totalBalance: totalRaw.flatMap(DeepSeekAmountParsing.parse),
                grantedBalance: (raw["granted_balance"] as? String).flatMap(DeepSeekAmountParsing.parse),
                toppedUpBalance: (raw["topped_up_balance"] as? String).flatMap(DeepSeekAmountParsing.parse),
                totalBalanceText: totalRaw
            )
        }
        return DeepSeekBalanceResponse(
            isAvailable: object["is_available"] as? Bool ?? false,
            infos: infos
        )
    }
}

// MARK: - 金额解析

enum DeepSeekAmountParsing {
    /// 解析 API 返回的字符串金额；固定 POSIX locale（"." 为小数点），避免逗号小数区域误读。
    static func parse(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: - 金额展示格式化

enum DeepSeekBalanceFormat {
    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        // 固定小数点语义，避免逗号小数区域差异
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 币种符号：CNY→¥、USD→$、其他→"<code> "。
    static func currencySymbol(_ code: String) -> String {
        switch code {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return "\(code) "
        }
    }

    /// 金额文本：Decimal 正常格式化两位小数；解析失败回退原始字符串；均缺 → 仅符号。
    static func amount(_ decimal: Decimal?, rawText: String?, currency: String) -> String {
        let symbol = currencySymbol(currency)
        if let decimal {
            return symbol + (amountFormatter.string(from: decimal as NSDecimalNumber) ?? "\(decimal)")
        }
        if let rawText {
            return symbol + rawText
        }
        return symbol
    }
}

// MARK: - 低余额判定

enum DeepSeekLowBalanceEvaluator {
    /// CNY 条目 `total_balance`；无 CNY 条目（或 CNY 金额解析失败）→ nil，不做判定。
    static func cnyTotal(in response: DeepSeekBalanceResponse) -> Decimal? {
        for info in response.infos where info.currency == "CNY" {
            if let total = info.totalBalance { return total }
        }
        return nil
    }

    /// 是否已跨过阈值（CNY 口径，≤ 触发）。`is_available=false` 不拦截（正是余额耗尽场景）。
    static func crossedThreshold(in response: DeepSeekBalanceResponse, threshold: Double) -> Bool {
        guard let total = cnyTotal(in: response) else { return false }
        return total <= Decimal(threshold)
    }
}
