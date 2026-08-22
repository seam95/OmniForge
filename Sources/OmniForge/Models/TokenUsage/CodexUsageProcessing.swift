import Foundation

// MARK: - Codex rollout 行（隐私红线：只解码身份/用量字段，正文从不物化）

/// Codex rollout JSONL 单行 — 只声明身份/用量字段。
///
/// 隐私红线（SPEC 2.6）：本结构不含任何 prompt、消息正文或会话内容字段；
/// `payload` 中未声明的键（如文本片段）由 JSONDecoder 直接丢弃，永不读取。
struct CodexRolloutEntry: Decodable, Equatable {
    let type: String?
    let timestamp: String?
    let payload: Payload?

    var isTokenCountEvent: Bool {
        type == "event_msg" && (payload?.type == "token_count" || payload?.msg?.type == "token_count")
    }

    /// token_count 事件载体：`payload.info`（新版本）或 `payload.msg.info`（包壳兼容）。
    var tokenCountResource: CodexTokenCountResource? {
        payload?.info ?? payload?.msg?.info
    }

    struct Payload: Decodable, Equatable {
        let type: String?
        /// turn_context：当前模型。
        let model: String?
        /// session_meta：会话唯一 id。
        let id: String?
        /// session_meta：model_provider（turn_context 缺失时的模型兜底）。
        let modelProvider: String?
        /// token_count 事件载体。
        let info: CodexTokenCountResource?
        /// 部分版本把 token_count 包在 payload.msg 内。
        let msg: Msg?

        struct Msg: Decodable, Equatable {
            let type: String?
            let info: CodexTokenCountResource?
        }

        enum CodingKeys: String, CodingKey {
            case type, model, id, info, msg
            case modelProvider = "model_provider"
        }
    }
}

/// token_count 事件的用量信息：last 为「最新完成轮次」用量，total 为流内累计（参考 codex-token-usage.js）。
struct CodexTokenCountResource: Decodable, Equatable {
    let lastTokenUsage: CodexTokenCounts?
    let totalTokenUsage: CodexTokenCounts?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
    }
}

/// Codex 六维 token 计数（原始字段，可能为负数/缺失 — 归一化时清洗）。
struct CodexTokenCounts: Decodable, Equatable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var cacheCreationInputTokens: Int?
    /// `cache_write_input_tokens` 是 `cache_creation_input_tokens` 的别名（canonicalUsage）。
    var cacheWriteInputTokens: Int?
    var outputTokens: Int?
    var reasoningOutputTokens: Int?
    var totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - 解析纯函数（参考 02 / codex-rollout-parser normalizeUsage）

/// Codex 行解析归一化 — 纯函数；cached 减法 / 增量口径 / 去重 key / 半小时桶。
///
/// **cached 减法（成本正确性关键）**：Codex 的 `input_tokens` 是「含缓存的总 prompt」，
/// `cached` 是其子集；六列 schema 里 `input` 应为纯非缓存输入，必须
/// `input = max(0, input - cached)`，否则缓存部分被双重计费、成本虚增 6~7 倍。
///
/// 口径说明：TokenTracker 的多流恢复状态机（codex-token-usage.js）在此简化为
/// 「单流 per 文件」——按事件顺序维护上一轮累计差值，配合 (session, timestamp,
/// 用量签名) 跨 sync 去重，同文件多流交错场景保守跳过。
enum CodexUsageProcessing {
    /// 默认模型名（与 TokenTracker 对齐）。
    static let defaultModel = "unknown"

    // MARK: 归一化 + cached 减法

    /// 六列归一化（含 cached 减法与 total 重算）；全零 → nil（不产生计数）。
    static func normalized(from counts: CodexTokenCounts) -> TokenUsage? {
        let input = max(0, canonical(counts.inputTokens) - canonical(counts.cachedInputTokens))
        let cached = canonical(counts.cachedInputTokens)
        let creation = canonical(counts.cacheCreationInputTokens ?? counts.cacheWriteInputTokens)
        let output = canonical(counts.outputTokens)
        let total = input + cached + creation + output
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: creation,
            outputTokens: output,
            reasoningOutputTokens: canonical(counts.reasoningOutputTokens),
            totalTokens: total
        )
    }

    // MARK: 行级增量口径

    /// 一条 token_count 事件的增量（返回 nil 表示本轮**无增量**，调用方不得计数）。
    ///
    /// 规则（参考 consumeUsageDelta 的简化口径）：
    /// - `last_token_usage` 存在 → 它就是「最新完成轮次」的用量；
    /// - 否则与本次扫描内上一轮累计 `total - previousTotal` 逐字段差值；
    /// - 整读起点（无 last 且无 previousTotal）→ 累计值即首次增量；
    /// - 增量尾部无 last 且无 previousTotal（半流切入）→ 保守跳过，避免把累计当增量。
    static func delta(
        last: CodexTokenCounts?,
        total: CodexTokenCounts?,
        previousTotal: CodexTokenCounts?,
        isStreamStart: Bool
    ) -> TokenUsage? {
        if let last, last.canonicalized() != nil {
            // 上次扫描后累计总量未变 → 该 last 快照已涵盖在既有差值口径中（参考
            // consumeUsageDelta 的基线命中即返 null）：同一轮次重发（时间戳不同 → 去重
            // key 失效）不得重复计费。
            if let total, let previousTotal,
               !isTotalsReset(total: total, previous: previousTotal),
               total.canonicalized() == previousTotal.canonicalized() {
                return nil
            }
            return normalized(from: last)
        }
        guard let total else { return nil }
        if let previousTotal {
            guard !isTotalsReset(total: total, previous: previousTotal) else { return nil }
            guard let diff = subtract(total: total, previous: previousTotal) else { return nil }
            return normalized(from: diff)
        }
        guard isStreamStart else { return nil }
        return normalized(from: total)
    }

    /// `total - previous` 逐字段差值；任一字段倒挂（累计回退）→ nil。
    static func subtract(total: CodexTokenCounts, previous: CodexTokenCounts) -> CodexTokenCounts? {
        let a = total.canonicalized()
        let b = previous.canonicalized()
        guard let a, let b else { return nil }
        let fields: [(Int?, Int?)] = [
            (a.inputTokens, b.inputTokens),
            (a.cachedInputTokens, b.cachedInputTokens),
            (a.cacheCreationInputTokens ?? a.cacheWriteInputTokens, b.cacheCreationInputTokens ?? b.cacheWriteInputTokens),
            (a.outputTokens, b.outputTokens),
            (a.reasoningOutputTokens, b.reasoningOutputTokens),
            (a.totalTokens, b.totalTokens),
        ]
        for (left, right) in fields where (left ?? 0) < (right ?? 0) {
            return nil
        }
        return CodexTokenCounts(
            inputTokens: max(0, (a.inputTokens ?? 0) - (b.inputTokens ?? 0)),
            cachedInputTokens: max(0, (a.cachedInputTokens ?? 0) - (b.cachedInputTokens ?? 0)),
            cacheCreationInputTokens: max(0, (a.cacheCreationInputTokens ?? a.cacheWriteInputTokens ?? 0) - (b.cacheCreationInputTokens ?? b.cacheWriteInputTokens ?? 0)),
            cacheWriteInputTokens: nil,
            outputTokens: max(0, (a.outputTokens ?? 0) - (b.outputTokens ?? 0)),
            reasoningOutputTokens: max(0, (a.reasoningOutputTokens ?? 0) - (b.reasoningOutputTokens ?? 0)),
            totalTokens: max(0, (a.totalTokens ?? 0) - (b.totalTokens ?? 0))
        )
    }

    /// 累计值回退（stream 轮换）：`total.totalTokens < previous.totalTokens`。
    static func isTotalsReset(total: CodexTokenCounts, previous: CodexTokenCounts) -> Bool {
        guard let a = total.canonicalized(), let b = previous.canonicalized() else { return false }
        return (a.totalTokens ?? 0) < (b.totalTokens ?? 0)
    }

    // MARK: 去重 key

    /// 消息级去重 key：`sessionId:timestamp:usageSignature(last,total)`。
    ///
    /// Codex 无 requestId 语义（参考参考 02 血泪教训的兼容口径）：
    /// 以事件时间戳 + 用量签名组成稳定 key，跨 sync 持久化去重；
    /// 无时间戳 → 无法归桶也无从去重，返回 nil。
    static func eventKey(
        sessionID: String?,
        timestamp: String?,
        last: CodexTokenCounts?,
        total: CodexTokenCounts?
    ) -> String? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        return "\(sessionID ?? "unknown"):\(timestamp):\(usageSignature(last: last, total: total))"
    }

    /// 用量签名（canonical 六字段原子串，与 codex-token-usage.js usageSignature 对齐）。
    static func usageSignature(last: CodexTokenCounts?, total: CodexTokenCounts?) -> String {
        "\(countsKey(last)):\(countsKey(total))"
    }

    private static func countsKey(_ counts: CodexTokenCounts?) -> String {
        guard let c = counts?.canonicalized() else { return "none" }
        let creation = c.cacheCreationInputTokens ?? c.cacheWriteInputTokens
        return [
            c.inputTokens, c.cachedInputTokens, creation, c.outputTokens,
            c.reasoningOutputTokens, c.totalTokens,
        ].map { String($0 ?? 0) }.joined(separator: ":")
    }

    // MARK: 时间桶与模型

    /// 行时间戳 → UTC 半小时桶起点（参考 02 `toUtcHalfHourStart`）。
    static func bucketStart(from timestamp: String?) -> Date? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        guard let date = isoDate(from: timestamp) else { return nil }
        let seconds = Int(date.timeIntervalSince1970)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// 模型名：trim 后非空，否则回退 `unknown`。
    static func modelName(_ raw: String?) -> String {
        guard let raw else { return defaultModel }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    // MARK: 内部

    private static func canonical(_ value: Int?) -> Int {
        guard let value else { return 0 }
        return max(0, value)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func isoDate(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}

private extension CodexTokenCounts {
    /// 非负化（缺省补 0）；全部字段不可解析 → nil。
    func canonicalized() -> CodexTokenCounts? {
        let values = [inputTokens, cachedInputTokens, cacheCreationInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, totalTokens]
        guard values.contains(where: { $0 != nil }) else { return nil }
        return CodexTokenCounts(
            inputTokens: max(0, inputTokens ?? 0),
            cachedInputTokens: max(0, cachedInputTokens ?? 0),
            cacheCreationInputTokens: cacheCreationInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: max(0, outputTokens ?? 0),
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: max(0, totalTokens ?? 0)
        )
    }
}
