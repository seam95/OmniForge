import Foundation

// MARK: - 客户端形态

/// Antigravity 会话库来源（两类目录同 schema，仅去重 key 前缀不同）。
enum AntigravityClientKind: String, Equatable, CaseIterable {
    /// CLI：`~/.gemini/antigravity-cli/conversations`。
    case cli
    /// IDE 扩展：`~/.gemini/antigravity/conversations`。
    case ide
}

// MARK: - blob 解析结果（只含身份/用量字段，正文永不读取）

/// `gen_metadata` 单行解析结果。
///
/// 隐私红线（SPEC 2.6）：生成 blob 内混有对话正文；本结构只承载按字段号取出的
/// token 数字、时间、模型与 responseId，**不保留也不打印任何正文**。
struct AntigravityGenerationRecord: Equatable {
    /// `gen_metadata.idx`：0-based 生成序号（与 `steps.metadata.#20.#3` 对应）。
    var sequence: Int
    /// 六列用量（保留原始值，零用量过滤在出桶阶段做）。
    var usage: TokenUsage
    /// 纯输入/缓存读/输出/reasoning 四列是否至少一项非零。
    var hasTokenUsage: Bool
    /// `chatModel.#4.#11`（responseId，与 `steps.metadata.#9.#11` 一致）；可为空。
    var responseID: String?
    /// `chatModel.#19`（responseModel 字符串）。
    var responseModel: String?
    /// `chatModel.#21`（展示 label 字符串，如 "Gemini 3.5 Flash (High)"）。
    var displayLabel: String?
    /// 旧版时间：`chatModel.#9.#4` Timestamp → epoch 毫秒；新版该字段不含可用时间。
    var legacyTimestampMilliseconds: Double?
}

/// `steps` 表中模型轮次行（step_type = 15）的解析结果。
struct AntigravityStepRecord: Equatable {
    /// `metadata.#9.#11`（responseId）。
    var responseID: String?
    /// `metadata.#1` Timestamp → epoch 毫秒。
    var timestampMilliseconds: Double?
    /// `metadata.#20.#3`（0-based 生成序号；#20 存在而 #3 缺省时为 0）。
    var generationSequence: Int?
}

/// 单次有效生成（一条模型调用）的最终入库形态。
struct AntigravityGeneration: Equatable {
    /// `gen_metadata.idx`（用于无 responseId 时的稳定去重 key）。
    var sequence: Int
    /// 恢复后的模型名（永不空，最差为 "unknown"）。
    var model: String
    var usage: TokenUsage
    /// UTC 半小时桶起点。
    var bucketStart: Date
    /// 跨扫描去重 key（由采集器写入 seen keys）。
    var deduplicationKey: String
    /// 会话计数增量：每条有效生成计 1。
    ///
    /// 口径说明：Antigravity 没有独立「会话」表可计数，一次生成 = 一次模型调用；
    /// 与其它本地采集器「每轮对话计 1」的口径对齐，这里按生成条数计。
    var conversationDelta: Int
}

// MARK: - 文件级模型恢复

/// 文件级模型恢复索引。
///
/// 优先级（任务规格）：
/// ① 自身 `chatModel.#19`（trim 非空且不等于 "gemini-default" 路由标签）；
/// ② 同文件内 `#21 label → #19` 唯一映射（同 label 对应两个不同 #19 → 歧义，丢弃该 label）；
/// ③ 文件内唯一 #19（仅当所有出现过的 label 都能被识别）；
/// ④ `#21` 已知展示名映射表（老版本只有 label 时的兜底）；
/// ⑤ "unknown"。
struct AntigravityModelResolver: Equatable {
    /// 本文件出现过的全部可用 #19。
    private(set) var usableModels: Set<String> = []
    /// label → 出现过的 #19 集合（用于唯一映射与歧义判定）。
    private var labelToModels: [String: Set<String>] = [:]
    /// 本文件出现过的全部非空 label（含没有 #19 的行，用于第 ③ 步的识别度守卫）。
    private(set) var observedLabels: Set<String> = []

    init(records: [AntigravityGenerationRecord]) {
        for record in records {
            let label = AntigravityUsageProcessing.trimmedNonEmpty(record.displayLabel)
            if let label {
                observedLabels.insert(label)
            }
            guard let model = AntigravityUsageProcessing.usableResponseModel(record.responseModel) else {
                continue
            }
            usableModels.insert(model)
            if let label {
                labelToModels[label, default: []].insert(model)
            }
        }
    }

    /// 恢复该行的模型名。
    func model(responseModel: String?, displayLabel: String?) -> String {
        // ① 自身 responseModel 可用 → 直接采用。
        if let direct = AntigravityUsageProcessing.usableResponseModel(responseModel) {
            return direct
        }
        let label = AntigravityUsageProcessing.trimmedNonEmpty(displayLabel)
        // ② 同文件内 label → #19 唯一映射。
        if let label, let mapped = uniqueModel(forLabel: label) {
            return mapped
        }
        // ③ 文件内唯一 #19：只有所有 label 都能识别时才敢套用，避免串模型。
        if usableModels.count == 1, observedLabels.allSatisfy(isRecognizedLabel) {
            return usableModels.first!
        }
        // ④ 已知展示名映射表。
        if let label, let known = AntigravityUsageProcessing.knownDisplayModels[label] {
            return known
        }
        return AntigravityUsageProcessing.defaultModel
    }

    /// label 的唯一 #19 映射（无映射或歧义 → nil）。
    private func uniqueModel(forLabel label: String) -> String? {
        guard let models = labelToModels[label], models.count == 1 else { return nil }
        return models.first
    }

    /// label 是否可识别（唯一映射或已知展示名）。
    private func isRecognizedLabel(_ label: String) -> Bool {
        uniqueModel(forLabel: label) != nil
            || AntigravityUsageProcessing.knownDisplayModels[label] != nil
    }
}

// MARK: - protobuf 字段号语义（纯函数，独立可测）

/// Antigravity 会话库解析与入桶归一化。
///
/// 字段语义（本机 agy 1.1.18+ 逆向确认）：
/// - `gen_metadata.data.#1` = chatModel：
///   `#4` = usage（`#1` 固定系统 prompt tokens、`#2` 非缓存输入、`#5` cacheRead、
///   `#9` 输出净额、`#10` reasoning、`#11` responseId 字符串）；
///   `#19` = responseModel 字符串；`#21` = 展示 label 字符串；
///   `#9.` old = 时间（旧版 `#9.#4` Timestamp；新版无可用时间）。
/// - `steps.metadata`：`#1` Timestamp、`#9.#11` responseId、`#20.#3` 生成序号。
/// - `trajectory_metadata_blob.data.#2` = Timestamp（会话创建时间）；
///   `#1.#1` 为 workspace URI（本层不读取）。
enum AntigravityUsageProcessing {
    /// 模型无法恢复时的兜底名。
    static let defaultModel = "unknown"

    /// 路由标签：部分版本把该值写进 #19，它不代表真实响应模型。
    static let routeLabel = "gemini-default"

    /// #21 展示名 → 模型 id（老版本只有 label 时的兜底映射）。
    static let knownDisplayModels: [String: String] = [
        "Gemini 3.5 Flash (Low)": "gemini-3.5-flash-extra-low",
        "Gemini 3.5 Flash (Medium)": "gemini-3.5-flash-medium",
        "Gemini 3.5 Flash (High)": "gemini-3.5-flash-high",
    ]

    // MARK: - 单 blob 解析

    /// 解析 `gen_metadata.data`；坏 blob / 无 chatModel → nil（调用方跳过该行）。
    static func parseGeneration(data: Data, sequence: Int) -> AntigravityGenerationRecord? {
        guard let root = try? ProtoMessage(data: data) else { return nil }
        guard let chatModel = root.message(1) else { return nil }
        let usageMessage = chatModel.message(4)
        let usage = tokenUsage(from: usageMessage)
        let legacyTimestamp = chatModel.message(9)
            .flatMap { $0.message(4) }
            .flatMap(timestampMilliseconds)
        return AntigravityGenerationRecord(
            sequence: sequence,
            usage: usage,
            hasTokenUsage: !isZeroUsage(usage),
            responseID: trimmedNonEmpty(usageMessage?.string(11)),
            responseModel: chatModel.string(19),
            displayLabel: chatModel.string(21),
            legacyTimestampMilliseconds: legacyTimestamp
        )
    }

    /// 解析 `steps.metadata`；坏 blob → nil。
    static func parseStep(data: Data) -> AntigravityStepRecord? {
        guard let root = try? ProtoMessage(data: data) else { return nil }
        let timestamp = root.message(1).flatMap(timestampMilliseconds)
        let responseID = trimmedNonEmpty(root.message(9)?.string(11))
        var generationSequence: Int?
        if let metadata = root.message(20) {
            // #20 存在但 #3 缺省 = proto3 默认值 0（0-based 生成序号）。
            if let rawSequence = metadata.varint(3) {
                generationSequence = Int(exactly: rawSequence)
            } else {
                generationSequence = 0
            }
        }
        return AntigravityStepRecord(
            responseID: responseID,
            timestampMilliseconds: timestamp,
            generationSequence: generationSequence
        )
    }

    /// 解析 `trajectory_metadata_blob.data` 的会话创建时间（epoch 毫秒）；坏 blob → nil。
    static func parseTrajectoryCreation(data: Data) -> Double? {
        guard let root = try? ProtoMessage(data: data) else { return nil }
        return root.message(2).flatMap(timestampMilliseconds)
    }

    // MARK: - 字段语义归一化

    /// usage 消息 → 六列：
    /// input = #1 + #2；cached = #5；cacheCreation = 0；output = #9；reasoning = #10；
    /// total = input + output + reasoning（缓存是复用流量，不计入总量）。
    static func tokenUsage(from usage: ProtoMessage?) -> TokenUsage {
        guard let usage else { return .zero }
        let fixedInput = tokenCount(usage.varint(1))
        let nonCachedInput = tokenCount(usage.varint(2))
        let cached = tokenCount(usage.varint(5))
        let output = tokenCount(usage.varint(9))
        let reasoning = tokenCount(usage.varint(10))
        let input = safeAdd(fixedInput, nonCachedInput)
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: safeAdd(input, output, reasoning)
        )
    }

    /// 四者全零跳过：纯输入 / 缓存读 / 输出 / reasoning 都无 → 不产生计数。
    static func isZeroUsage(_ usage: TokenUsage) -> Bool {
        usage.inputTokens == 0
            && usage.cachedInputTokens == 0
            && usage.outputTokens == 0
            && usage.reasoningOutputTokens == 0
    }

    /// Timestamp 消息（#1 秒、#2 纳秒）→ epoch 毫秒；非法/零 → nil。
    ///
    /// 纳秒越界（> 999_999_999）视为坏值忽略，仍保留秒级时间；
    /// 秒级时间统一经 `UsageTimestampSanitizer` 清洗（NaN/超界/零值防护）。
    static func timestampMilliseconds(_ message: ProtoMessage) -> Double? {
        guard let rawSeconds = message.varint(1),
              let seconds = UsageTimestampSanitizer.epochSeconds(Double(rawSeconds)) else {
            return nil
        }
        let rawNanos = message.varint(2) ?? 0
        let nanos = rawNanos < 1_000_000_000 ? rawNanos : 0
        return Double(seconds) * 1000 + Double(nanos) / 1_000_000
    }

    /// epoch 毫秒 → UTC 半小时桶起点；非法 → nil。
    static func bucketStart(fromMilliseconds milliseconds: Double) -> Date? {
        guard let seconds = UsageTimestampSanitizer.epochSeconds(fromMilliseconds: milliseconds) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    // MARK: - 文件级组装

    /// 单库文件（一次只读打开）的全部生成行 → 待入桶生成列表。
    ///
    /// - Parameters:
    ///   - generationRows: `gen_metadata` 的 (idx, data)，按 idx 升序。
    ///   - stepRows: `steps` 中 step_type = 15 的 metadata blob。
    ///   - trajectoryData: `trajectory_metadata_blob` 中 id = "main" 的 data。
    ///   - client: 目录来源（cli / ide），参与去重 key。
    ///   - sessionID: 文件名去掉 .db。
    ///   - fileModificationDate: 文件 mtime（最后一级时间兜底）。
    ///
    /// 同一 DB 内 responseId 重复只计一次（无 responseId 时用序号 key）。
    /// 时间完全无法恢复的行直接丢弃：宁可漏计也不把用量记到错误的时间桶。
    static func makeGenerations(
        generationRows: [(sequence: Int, data: Data)],
        stepRows: [Data],
        trajectoryData: Data?,
        client: AntigravityClientKind,
        sessionID: String,
        fileModificationDate: Date?
    ) -> [AntigravityGeneration] {
        let records = generationRows.compactMap { row in
            parseGeneration(data: row.data, sequence: row.sequence)
        }
        guard !records.isEmpty else { return [] }

        let steps = stepRows.compactMap(parseStep)
        var stepsByResponseID: [String: AntigravityStepRecord] = [:]
        var stepsBySequence: [Int: AntigravityStepRecord] = [:]
        for step in steps {
            // 同 responseId/序号出现多行时取第一行（表内 idx 顺序稳定）。
            if let responseID = step.responseID, stepsByResponseID[responseID] == nil {
                stepsByResponseID[responseID] = step
            }
            if let sequence = step.generationSequence, stepsBySequence[sequence] == nil {
                stepsBySequence[sequence] = step
            }
        }

        let conversationCreation = trajectoryData.flatMap(parseTrajectoryCreation)
        let fileModificationMilliseconds = fileModificationDate.map { $0.timeIntervalSince1970 * 1000 }
        let resolver = AntigravityModelResolver(records: records)
        let keyPrefix = "antigravity:\(client.rawValue):\(sessionID)"

        var emittedKeys = Set<String>()
        var generations: [AntigravityGeneration] = []
        for record in records {
            guard record.hasTokenUsage else { continue }
            guard let milliseconds = resolvedTimestampMilliseconds(
                record: record,
                stepsByResponseID: stepsByResponseID,
                stepsBySequence: stepsBySequence,
                conversationCreationMilliseconds: conversationCreation,
                fileModificationMilliseconds: fileModificationMilliseconds
            ), let bucketStart = bucketStart(fromMilliseconds: milliseconds) else {
                continue
            }
            let responseID = trimmedNonEmpty(record.responseID)
            let key = responseID.map { "\(keyPrefix):\($0)" }
                ?? "\(keyPrefix):seq:\(record.sequence)"
            guard emittedKeys.insert(key).inserted else { continue }
            generations.append(AntigravityGeneration(
                sequence: record.sequence,
                model: resolver.model(
                    responseModel: record.responseModel,
                    displayLabel: record.displayLabel
                ),
                usage: record.usage,
                bucketStart: bucketStart,
                deduplicationKey: key,
                conversationDelta: 1
            ))
        }
        return generations
    }

    /// 时间优先级：
    /// 旧版 `chatModel.#9.#4` → steps 按 responseId → steps 按生成序号
    /// → 会话创建时间（trajectory #2）→ 文件 mtime。
    static func resolvedTimestampMilliseconds(
        record: AntigravityGenerationRecord,
        stepsByResponseID: [String: AntigravityStepRecord],
        stepsBySequence: [Int: AntigravityStepRecord],
        conversationCreationMilliseconds: Double?,
        fileModificationMilliseconds: Double?
    ) -> Double? {
        if let legacy = record.legacyTimestampMilliseconds, legacy > 0 {
            return legacy
        }
        if let responseID = trimmedNonEmpty(record.responseID),
           let stepTime = stepsByResponseID[responseID]?.timestampMilliseconds, stepTime > 0 {
            return stepTime
        }
        if let stepTime = stepsBySequence[record.sequence]?.timestampMilliseconds, stepTime > 0 {
            return stepTime
        }
        if let creation = conversationCreationMilliseconds, creation > 0 {
            return creation
        }
        if let modification = fileModificationMilliseconds, modification > 0 {
            return modification
        }
        return nil
    }

    // MARK: - 小工具

    /// trim 后非空 → 原值；否则 nil。
    static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 可用 responseModel：trim 非空且不是路由标签；否则 nil。
    static func usableResponseModel(_ raw: String?) -> String? {
        guard let model = trimmedNonEmpty(raw) else { return nil }
        guard model.lowercased() != routeLabel else { return nil }
        return model
    }

    /// wire varint → 非负 token 计数（超大坏值 clamp 到 Int.max，绝不崩溃）。
    private static func tokenCount(_ value: UInt64?) -> Int {
        guard let value else { return 0 }
        return Int(clamping: value)
    }

    /// 十六列求和防溢出（坏数据只影响计数上限，不触发运行时陷阱）。
    private static func safeAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    private static func safeAdd(_ a: Int, _ b: Int, _ c: Int) -> Int {
        safeAdd(safeAdd(a, b), c)
    }
}
