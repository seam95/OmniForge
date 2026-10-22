import Foundation

// MARK: - Pi / Oh My Pi 会话 JSONL 行（隐私红线：只声明身份/模型/用量字段）

/// Pi 系（Pi / Oh My Pi）会话 JSONL 单行。
///
/// 一个结构覆盖 session 头、title 元数据、model_change 与 message 行：
/// 未声明键（content / thinking / 工具调用等正文）由 JSONDecoder 直接丢弃，
/// 永不物化、绝不落盘（SPEC 2.6 隐私红线）。
///
/// 记录形状（本机实测 + tokscale sessions/pi.rs）：
/// - {"type":"session","version":3,"id":"<uuid>","timestamp":"ISO","cwd":"..."}
/// - {"type":"model_change","provider":"...","modelId":"..."}（Pi）
///   / {"type":"model_change","model":"..."}（OMP 新版本，无 modelId）
/// - {"type":"message","id":"...","timestamp":"ISO","message":{"role":"assistant","usage":{...}}}
/// - OMP 新会话文件可能在 session 头之前写一行 {"type":"title",...}，本结构忽略其正文。
struct PiSessionRecord: Decodable, Equatable {
    let type: String?
    let id: String?
    let timestamp: String?
    let provider: String?
    let model: String?
    let modelId: String?
    let message: PiMessage?
}

/// 单条消息 — 只声明角色/模型/用量字段；正文内容不在解析范围内。
struct PiMessage: Decodable, Equatable {
    let role: String?
    let model: String?
    let usage: PiTokenUsage?
}

/// Pi 系 usage 块 — camelCase：
/// {input, output, cacheRead, cacheWrite, totalTokens}，Pi 另写 reasoning，
/// OMP 写 reasoningTokens（两种拼写都接受）。
struct PiTokenUsage: Decodable, Equatable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    /// Pi 的推理 token（output 的子集）。
    let reasoning: Int?
    /// OMP 的推理 token 拼写（同为 output 子集）。
    let reasoningTokens: Int?
}

// MARK: - 解析纯函数

/// Pi / Oh My Pi 行解析归一化 — 纯函数；会话/模型归属、六列映射、去重 key、半小时桶。
///
/// 口径说明（与 tokscale 的差异）：
/// - Pi 自身 usage.totalTokens = input + output + cacheRead + cacheWrite（不含 reasoning）；
/// - tokscale 的 total 含 cache、且因 reasoning 是 output 子集而置 0，避免重复计；
/// - 本仓库六列口径为 total = input + output + reasoning，缓存读写单列存储但不计入 total（SPEC 4.2）。
///   因此这里把 reasoning 从 output 中拆出（output = max(0, rawOutput - reasoning)），
///   与 DSH/ClaudeFork 的「从父列拆子列」一致：total 等价于 input + rawOutput，与 Pi 自身
///   totalTokens 扣除缓存后的金额对账一致，也不会重复计入。
enum PiUsageProcessing {
    static let defaultModel = "unknown"

    // MARK: 行解码

    /// JSONL 行 → 记录；空白行/坏行返回 nil（逐行 try? 跳过，不影响整文件）。
    static func record(from line: String, decoder: JSONDecoder) -> PiSessionRecord? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // UTF-8 BOM 防御：部分工具链会在文件首行写入 BOM。
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard !text.isEmpty, text.hasPrefix("{") else { return nil }
        return try? decoder.decode(PiSessionRecord.self, from: Data(text.utf8))
    }

    // MARK: 会话 / 模型归属

    /// session 头 id（trim 后非空）。
    static func sessionID(from record: PiSessionRecord) -> String? {
        normalized(record.id)
    }

    /// model_change 的模型与上游 provider。
    ///
    /// Pi 用 modelId，OMP 新版本写 model（且 provider 可能为 null）；两者都接受。
    /// 上游 provider 不参与桶键（桶键的 provider 是应用来源 .pi/.omp），仅随记录解析备用。
    static func modelChange(from record: PiSessionRecord) -> (model: String, provider: String?)? {
        guard record.type == "model_change" else { return nil }
        guard let model = normalized(record.modelId) ?? normalized(record.model) else { return nil }
        return (model, normalized(record.provider))
    }

    /// 消息自带模型（旧文件没有 model_change 时的模型归属兜底）。
    static func messageModel(from message: PiMessage?) -> String? {
        normalized(message?.model)
    }

    // MARK: 六列归一化

    /// assistant usage → 六列；无有效新增 token 返回 nil（不产生计数）。
    ///
    /// 映射（SPEC 4.2）：input=usage.input、cached=cacheRead、cacheCreation=cacheWrite、
    /// output=usage.output（先扣除 reasoning 子集）、reasoning=usage.reasoning/reasoningTokens、
    /// total=input+output+reasoning（缓存不计入）。
    static func tokenUsage(from usage: PiTokenUsage?) -> TokenUsage? {
        guard let usage else { return nil }
        let input = max(0, usage.input ?? 0)
        let cached = max(0, usage.cacheRead ?? 0)
        let cacheCreation = max(0, usage.cacheWrite ?? 0)
        // Pi 写 reasoning，OMP 写 reasoningTokens；同时出现时以 reasoning 为准。
        let reasoning = max(0, usage.reasoning ?? usage.reasoningTokens ?? 0)
        let outputRaw = max(0, usage.output ?? 0)
        // reasoning 是 output 的子集：拆出后六列自洽，total 不重复计。
        let output = max(0, outputRaw - reasoning)
        let total = input + output + reasoning
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    // MARK: 去重 / 会话计数 key

    /// 消息级去重 key：<namespace>:<sessionId>:<message.id>；
    /// 无 message.id 的旧记录用行号兜底（<namespace>:<sessionId>:line:<n>）。
    static func deduplicationKey(
        namespace: String,
        sessionID: String?,
        messageID: String?,
        lineNumber: Int
    ) -> String {
        let session = sessionID ?? "unknown"
        if let messageID = normalized(messageID) {
            return "\(namespace):\(session):\(messageID)"
        }
        return "\(namespace):\(session):line:\(lineNumber)"
    }

    /// 会话计数 key：每个 session 文件只计 1 次会话（首条 assistant 用量）。
    ///
    /// 走 message_seen 持久化（按文件路径），增量扫描/截断重读都不会重复计数。
    static func sessionMarkerKey(namespace: String, filePath: String) -> String {
        "\(namespace):session-file:\(filePath)"
    }

    // MARK: 时间桶

    /// ISO8601 行时间戳 → UTC 半小时桶起点；非法/缺失返回 nil。
    static func bucketStart(from timestamp: String?) -> Date? {
        guard let timestamp = normalized(timestamp),
              let date = isoDate(from: timestamp),
              let seconds = UsageTimestampSanitizer.epochSeconds(date.timeIntervalSince1970) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    // MARK: 路径归属

    /// 从文件路径推导会话 id — 增量扫描读不到头部时保持去重键稳定。
    ///
    /// - 顶层 <timestamp>_<uuid>.jsonl → uuid；
    /// - OMP 子代理 <timestamp>_<uuid>/<AgentName>.jsonl → <uuid>-<AgentName>；
    /// - 其他命名回退文件 stem（编码 cwd 目录含下划线也不会被误判：时间戳前缀需以数字开头含 T 结尾 Z）。
    static func derivedSessionID(from fileURL: URL) -> String? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        if let parentID = timestampedStemIdentifier(parent) {
            return "\(parentID)-\(stem)"
        }
        if let fileID = timestampedStemIdentifier(stem) {
            return fileID
        }
        return stem.isEmpty ? nil : stem
    }

    // MARK: 内部

    /// trim 后非空；空串/纯空白 → nil。
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// <timestamp>_<id> 形态的 stem → id；时间戳前缀不匹配返回 nil。
    private static func timestampedStemIdentifier(_ name: String) -> String? {
        guard let separator = name.lastIndex(of: "_") else { return nil }
        let prefix = name[..<separator]
        let identifier = name[name.index(after: separator)...]
        guard !identifier.isEmpty,
              prefix.first?.isNumber == true,
              prefix.contains("T"),
              prefix.hasSuffix("Z") else {
            return nil
        }
        return String(identifier)
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
