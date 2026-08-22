import Foundation

// MARK: - 云端账单 CSV（strategy=tokens）解析

/// Cursor 云端账单 CSV 单行（export-usage-events-csv?strategy=tokens）。
///
/// 列序随 Cursor 更新随时插入（Cloud Agent ID / Automation ID 等），解析一律
/// 按**表头名**解析列（参考 parseCursorCsv）；只保留日期/模型/六列 token 计数 —
/// Cost 等计费字段从不读取落库（隐私红线：只存 token 数字与时间，SPEC 2.6）。
struct CursorCsvRow: Equatable {
    /// 行时间（ISO 或 `yyyy-MM-dd` 归一为 UTC 日期）；不可解析 → 行被丢弃。
    var date: Date
    /// 计费 kind（Included / On-Demand / Free …），仅作来源标注，不落库。
    var kind: String
    var model: String
    var maxMode: String
    var inputWithoutCache: Int
    /// `Input (w/ Cache Write) - Input (w/o Cache Write)`（≥ 0）。
    var cacheWrite: Int
    var cacheRead: Int
    var outputTokens: Int
    /// CSV 总列（若有）；归一化计数以四列之和为准。
    var totalTokens: Int?
}

/// CSV 解析与桶构建 — 纯函数，独立可测。
enum CursorUsageProcessing {
    static let defaultModel = "unknown"

    // MARK: CSV → 行

    /// 解析 CSV 文本：表头缺必要列 → 空；全零行 / 日期不可解析行 → 丢弃（防御式降级不崩）。
    static func parseCSV(_ csv: String) -> [CursorCsvRow] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count >= 2 else { return [] }

        let header = parseCSVLine(lines[0]).map(stripQuotes)
        var columnIndex: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            columnIndex[name] = index
        }
        guard let dateIdx = columnIndex["Date"],
              let modelIdx = columnIndex["Model"],
              let inWithIdx = columnIndex["Input (w/ Cache Write)"],
              let inWithoutIdx = columnIndex["Input (w/o Cache Write)"],
              let cacheReadIdx = columnIndex["Cache Read"],
              let outputIdx = columnIndex["Output Tokens"] else {
            return []
        }
        let kindIdx = columnIndex["Kind"]
        let maxModeIdx = columnIndex["Max Mode"]
        let totalIdx = columnIndex["Total Tokens"]
        let minFields = [dateIdx, modelIdx, inWithIdx, inWithoutIdx, cacheReadIdx, outputIdx]
            .compactMap { $0 }
            .max()! + 1

        var rows: [CursorCsvRow] = []
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= minFields else { continue }
            let inputWithCache = toInt(stripQuotes(fields[inWithIdx]))
            let inputWithoutCache = toInt(stripQuotes(fields[inWithoutIdx]))
            let cacheRead = toInt(stripQuotes(fields[cacheReadIdx]))
            let output = toInt(stripQuotes(fields[outputIdx]))
            let cacheWrite = max(0, inputWithCache - inputWithoutCache)
            let total = totalIdx.flatMap { toInt(stripQuotes(fields[$0])) }
            guard inputWithoutCache > 0 || cacheRead > 0 || output > 0 || cacheWrite > 0 else {
                continue // 全零行不产生计数
            }
            let model = normalizeModel(stripQuotes(fields[modelIdx]))
            guard let date = parseDate(stripQuotes(fields[dateIdx])) else { continue }
            rows.append(CursorCsvRow(
                date: date,
                kind: kindIdx.flatMap { stripQuotes(fields[$0]) } ?? "unknown",
                model: model,
                maxMode: maxModeIdx.flatMap { stripQuotes(fields[$0]) } ?? "No",
                inputWithoutCache: inputWithoutCache,
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                outputTokens: output,
                totalTokens: total
            ))
        }
        return rows
    }

    /// 六列归一化：`input` = 不含缓存写列，`cached` = Cache Read，`cacheCreation` = 缓存写差，
    /// `total` = 四列之和（规格口径，不以 CSV 的 Total 列为准）。
    static func tokenUsage(from row: CursorCsvRow) -> TokenUsage? {
        let usage = TokenUsage(
            inputTokens: row.inputWithoutCache,
            cachedInputTokens: row.cacheRead,
            cacheCreationInputTokens: row.cacheWrite,
            outputTokens: row.outputTokens,
            reasoningOutputTokens: 0,
            totalTokens: row.inputWithoutCache + row.cacheRead + row.cacheWrite + row.outputTokens
        )
        return usage.totalTokens > 0 ? usage : nil
    }

    // MARK: 行 → 桶

    /// 半小时桶起点（UTC 对齐，与既有桶复用口径一致）。
    static func bucketFloor(for date: Date) -> Date {
        let seconds = Int(date.timeIntervalSince1970)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// CSV 行 → 半小时桶累计快照：同 (model, 桶) 合并求和；行数记入会话数（每行一条云端用量记录）。
    /// 快照语义：以「本次导出内该桶的全部行」为准；导出窗口外的旧桶保持不动（绝不回零覆盖）。
    static func bucketStates(rows: [CursorCsvRow], provider: TokenUsageProvider) -> [UsageBucketState] {
        var grouped: [UsageBucketKey: (usage: TokenUsage, conversations: Int)] = [:]
        for row in rows {
            let key = UsageBucketKey(
                provider: provider,
                model: row.model,
                bucketStart: bucketFloor(for: row.date)
            )
            let current = grouped[key] ?? (.zero, 0)
            let usage = current.usage.adding(tokenUsage(from: row) ?? .zero)
            grouped[key] = (usage, current.conversations + 1)
        }
        return grouped
            .map { key, value in
                UsageBucketState(key: key, usage: value.usage, conversationCount: value.conversations)
            }
            .sorted { lhs, rhs in
                lhs.key.bucketStart != rhs.key.bucketStart
                    ? lhs.key.bucketStart < rhs.key.bucketStart
                    : lhs.key.model < rhs.key.model
            }
    }

    // MARK: 模型名

    static func normalizeModel(_ raw: String?) -> String {
        guard let raw else { return defaultModel }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    // MARK: CSV 底层

    /// 支持引号分隔（引号内逗号不断行）；与 TokenTracker parseCsvLine 对齐。
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private static func stripQuotes(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func toInt(_ value: String) -> Int {
        let cleaned = value.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(cleaned) ?? 0
    }

    // MARK: 日期

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 行时间解析：带小数秒 ISO / 无小数秒 ISO / `yyyy-MM-dd`（UTC 当天 0 点）。
    static func parseDate(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string) ?? dayFormatter.date(from: string)
    }
}
