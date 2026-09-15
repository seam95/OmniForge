import Foundation

/// 极简 TOML 文档（覆盖 `~/.codex/config.toml` 实际用到的子集）。
///
/// 设计目标：**行级原样保留**。注释、空行、未知键、未知表在读写后保持字节不变，
/// 只允许通过 `setValue` / `remove` / `removeTable` 修改被显式声明的键 — 这正是
/// 「字段所有权合并」（SPEC 2.3）所需的机器边界：其余键一律不动。
struct TOMLFile: Equatable {
    /// 一行内的键值条目解析结果。
    struct Entry: Equatable {
        /// 所属表路径（nil = 顶层）。
        var tablePath: [String]?
        var key: String
        /// 值前的原文（含缩进、key、`=` 与分隔空白），如 `model = `。
        var prefix: String
        /// 值原文（含引号或裸值）。
        var value: String
        /// 值后的原文（行尾注释等）。
        var suffix: String
        /// 在 `lines` 中的行号（由 TOMLFile 维护）。
        var lineIndex: Int
    }

    private(set) var lines: [String]
    private(set) var entries: [Entry]

    init(lines: [String] = [], entries: [Entry] = []) {
        self.lines = lines
        self.entries = entries
    }

    // MARK: - 解析

    /// 解析失败（非注释行无法归类、引号未闭合）→ nil，调用方按「损坏」处理（不硬写）。
    static func parse(_ text: String) -> TOMLFile? {
        var lines: [String] = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 文件通常以单个换行结尾；去掉拆出的尾部空行，避免 round-trip 多出一行空白。
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard let entries = reparseEntries(lines: lines) else { return nil }
        return TOMLFile(lines: lines, entries: entries)
    }

    /// 按行数组重建全部条目：行号、词法前缀均以实际行为准。
    /// 返回 nil 表示存在无法归类的行（修改路径只写入合法行，理论不可达）。
    private static func reparseEntries(lines: [String]) -> [Entry]? {
        var entries: [Entry] = []
        var currentTable: [String]? = nil

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("[") {
                guard let path = parseTableHeaderPath(trimmed) else { return nil }
                currentTable = path
                continue
            }

            guard let (key, valueText, prefix, suffix) = parseKeyValue(line: line, trimmed: trimmed),
                  valueIsWellFormed(valueText) else {
                return nil
            }
            entries.append(Entry(
                tablePath: currentTable,
                key: key,
                prefix: prefix,
                value: valueText,
                suffix: suffix,
                lineIndex: index
            ))
        }
        return entries
    }

    /// 解析表头 `[a.b]` / `[a.b] # 注释` → 路径。
    private static func parseTableHeaderPath(_ trimmed: String) -> [String]? {
        var rest = trimmed
        rest.removeFirst() // [
        guard let close = rest.firstIndex(of: "]") else { return nil }
        let pathText = rest[rest.startIndex..<close]
        let pathParts = pathText.split(separator: ".", omittingEmptySubsequences: false)
            .map { unquoteBare($0.trimmingCharacters(in: .whitespaces)) }
        guard !pathParts.isEmpty, pathParts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return pathParts
    }

    /// 解析 `key = value`：返回 (key, 值原文, 值前文本, 值后文本)。
    /// 值前/值后文本保留**真实词法**（原空格、Tab、注释前空白），
    /// 使条目行恒满足 `hasPrefix(prefix)`，原地更新时不改写用户原文风格。
    private static func parseKeyValue(line: String, trimmed: String) -> (String, String, String, String)? {
        guard let eq = indexOfEqualsOutsideQuotes(trimmed) else { return nil }
        let keyRaw = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !keyRaw.isEmpty else { return nil }
        let key = unquoteBare(keyRaw)

        var valueStart = trimmed.index(after: eq)
        while valueStart < trimmed.endIndex, trimmed[valueStart].isWhitespace {
            valueStart = trimmed.index(after: valueStart)
        }
        let (valueText, _) = splitTrailingComment(String(trimmed[valueStart...]))
        guard !valueText.isEmpty else { return nil }

        let leadingCount = line.count - line.drop(while: { $0.isWhitespace }).count
        let leading = String(line.prefix(leadingCount))
        let prefix = leading + String(trimmed[trimmed.startIndex..<valueStart])
        // 值后原文：从值结束到行尾（含尾部空白与注释），保留原始间隔。
        let valueEnd = trimmed.index(valueStart, offsetBy: valueText.count, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        let suffix = String(trimmed[valueEnd...])
        return (key, valueText, prefix, suffix)
    }

    /// 值合法性：引号字符串必须闭合。
    private static func valueIsWellFormed(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        guard first == "\"" || first == "'" else { return true }
        var i = value.index(after: value.startIndex)
        var escaped = false
        while i < value.endIndex {
            let ch = value[i]
            if first == "\"", ch == "\\", !escaped {
                escaped = true
            } else if ch == first, !escaped {
                let after = value.index(after: i)
                return after == value.endIndex
                    || value[after...].trimmingCharacters(in: .whitespaces).isEmpty
            } else {
                escaped = false
            }
            i = value.index(after: i)
        }
        return false
    }

    /// 取 `=` 的索引（跳过引号内的 `=`）。
    private static func indexOfEqualsOutsideQuotes(_ text: String) -> String.Index? {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for index in text.indices {
            let ch = text[index]
            if inBasic {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inBasic = false }
            } else if inLiteral {
                if ch == "'" { inLiteral = false }
            } else {
                if ch == "\"" { inBasic = true }
                else if ch == "'" { inLiteral = true }
                else if ch == "=" { return index }
            }
        }
        return nil
    }

    /// 值尾部注释分离：值外首个 ` #` 起为注释（`#` 在引号内不算）。
    private static func splitTrailingComment(_ text: String) -> (String, String?) {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        var lastWasSpace = true
        var commentStart: String.Index?
        for index in text.indices {
            let ch = text[index]
            if inBasic {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inBasic = false }
            } else if inLiteral {
                if ch == "'" { inLiteral = false }
            } else {
                if ch == "\"" { inBasic = true }
                else if ch == "'" { inLiteral = true }
                else if ch == "#", lastWasSpace {
                    commentStart = index
                    break
                }
            }
            lastWasSpace = ch == " " || ch == "\t"
        }
        if let commentStart {
            let value = text[text.startIndex..<commentStart].trimmingCharacters(in: .whitespaces)
            let comment = text[text.index(after: commentStart)...].trimmingCharacters(in: .whitespaces)
            return (String(value), comment.isEmpty ? nil : "# " + comment)
        }
        return (text.trimmingCharacters(in: .whitespaces), nil)
    }

    /// 裸键/引号键去引号（键几乎总是裸键，这里兜底处理引号键）。
    private static func unquoteBare(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("\""), text.hasSuffix("\"") {
            return unescape(String(text.dropFirst().dropLast()))
        }
        if text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: - 值解码 / 编码

    /// 读取字符串值：引号字符串去引号去转义；裸值（bool/int/float/数组）返回原文。
    func stringValue(key: String, table: [String]? = nil) -> String? {
        guard let entry = entries.last(where: { $0.tablePath == table && $0.key == key }) else {
            return nil
        }
        let value = entry.value
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return Self.unescape(String(value.dropFirst().dropLast()))
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// 基本字符串转义（写入用）。
    static func escape(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// 基本字符串去转义。
    static func unescape(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\\", index < text.index(before: text.endIndex) {
                let next = text.index(after: index)
                switch text[next] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u":
                    let hexStart = text.index(next, offsetBy: 1)
                    if let hexEnd = text.index(hexStart, offsetBy: 4, limitedBy: text.endIndex) {
                        let hex = String(text[hexStart..<hexEnd])
                        if let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) {
                            out.unicodeScalars.append(scalar)
                            index = text.index(hexStart, offsetBy: 3)
                        }
                    }
                default:
                    out.append(text[next])
                }
                index = text.index(after: index)
            } else {
                out.append(ch)
            }
            index = text.index(after: index)
        }
        return out
    }

    // MARK: - 修改

    /// 设置键值（写入转义后的基本字符串）。目标键已存在 → 原地替换（保留行尾注释）；否则追加到所在段末尾。
    mutating func setValue(_ value: String, key: String, table: [String]?) {
        let escaped = Self.escape(value)
        if let entryIndex = validEntryIndex(key: key, table: table) {
            let entry = entries[entryIndex]
            lines[entry.lineIndex] = entry.prefix + escaped + entry.suffix
            entries[entryIndex].value = escaped
            return
        }
        let insertionLine = insertionPosition(for: table)
        let entry = Entry(
            tablePath: table,
            key: key,
            prefix: "\(key) = ",
            value: escaped,
            suffix: "",
            lineIndex: insertionLine
        )
        lines.insert(entry.prefix + entry.value, at: insertionLine)
        entries.append(entry)
        rebuildEntriesFromLines()
    }

    /// 确保表存在（缺失时在文档末尾追加表头）。
    mutating func ensureTable(path: [String]) {
        guard !path.isEmpty else { return }
        if lines.contains(where: { Self.tableHeaderPath(of: $0) == path }) {
            return
        }
        if !lines.isEmpty, !lines[lines.count - 1].isEmpty {
            lines.append("")
        }
        lines.append("[" + path.joined(separator: ".") + "]")
    }

    /// 删除键（含其整行）。
    mutating func remove(key: String, table: [String]?) {
        guard let entryIndex = validEntryIndex(key: key, table: table) else {
            return
        }
        lines.remove(at: entries[entryIndex].lineIndex)
        entries.remove(at: entryIndex)
        rebuildEntriesFromLines()
    }

    /// 删除整张表（表头 + 段内所有键行 + 子表）。
    mutating func removeTable(path: [String]) {
        let entryLines = entries.filter { entry in
            guard let tablePath = entry.tablePath else { return false }
            return tablePath.starts(with: path)
        }.map(\.lineIndex)
        let headerLines = lines.indices.filter { index in
            guard let headerPath = Self.tableHeaderPath(of: lines[index]) else { return false }
            return headerPath.starts(with: path)
        }
        let toRemove = Set(entryLines + headerLines)
        guard !toRemove.isEmpty else { return }
        entries.removeAll { entry in
            guard let tablePath = entry.tablePath else { return false }
            return tablePath.starts(with: path)
        }
        var removal = toRemove
        // 顺带吸收被删表前的分隔空行（其前一行非空时），避免删除后残留双空行。
        if let minHeader = headerLines.min(),
           minHeader > 0,
           lines[minHeader - 1].isEmpty,
           minHeader < 2 || !lines[minHeader - 2].isEmpty {
            removal.insert(minHeader - 1)
        }
        for index in removal.sorted(by: >) {
            lines.remove(at: index)
        }
        rebuildEntriesFromLines()
    }

    /// 清理删除后遗留的空白：去掉行首空行、将连续 3 行以上空行折叠为 2 行（仅影响空白，不动任何键）。
    mutating func normalizeBlankLines() {
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        var result: [String] = []
        var run = 0
        for line in lines {
            if line.isEmpty {
                run += 1
                if run <= 2 { result.append(line) }
            } else {
                run = 0
                result.append(line)
            }
        }
        lines = result
        rebuildEntriesFromLines()
    }

    /// 序列化回文本。
    func serialize() -> String {
        lines.joined(separator: "\n") + "\n"
    }

    // MARK: - private

    private static func tableHeaderPath(of line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        return parseTableHeaderPath(trimmed)
    }

    /// 新条目插入位置：顶层 → 最后一个顶层条目之后（无则首个表头之前/文档末尾）；
    /// 表内 → 该表最后一行（表头/段内键行/段内注释）之后。
    private func insertionPosition(for table: [String]?) -> Int {
        guard let table else {
            if let lastTopLevel = entries.last(where: { $0.tablePath == nil }) {
                return lastTopLevel.lineIndex + 1
            }
            if let firstTable = lines.firstIndex(where: { Self.tableHeaderPath(of: $0) != nil }) {
                return firstTable
            }
            return lines.count
        }
        var lastLine = -1
        var inTable = false
        for (index, line) in lines.enumerated() {
            if let headerPath = Self.tableHeaderPath(of: line) {
                if headerPath.starts(with: table) {
                    inTable = true
                    lastLine = index
                } else if inTable {
                    break // 遇到下一张表 → 本表结束
                }
            } else if inTable, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lastLine = index // 段内键行/注释行都属于本表
            }
        }
        return lastLine + 1
    }

    /// 结构修改后按当前行重解析全部条目：行号与词法前缀都以实际行为唯一真源，
    /// 不再用格式化字符串回查原文（原文 `key="v"` 等无空格写法会使回查错位，曾导致行号越界）。
    /// 重解析失败（修改路径只写入合法行，理论不可达）时清除越界条目，防止后续写错行。
    private mutating func rebuildEntriesFromLines() {
        if let reparsed = Self.reparseEntries(lines: lines) {
            entries = reparsed
        } else {
            entries.removeAll { $0.lineIndex >= lines.count }
        }
    }

    /// 查找键的最后一个有效条目：行号越界的条目（结构异常的防御路径）视为不存在并移除，
    /// 避免更新/删除写错行。
    private mutating func validEntryIndex(key: String, table: [String]?) -> Int? {
        guard let entryIndex = entries.lastIndex(where: { $0.tablePath == table && $0.key == key }) else {
            return nil
        }
        guard entries[entryIndex].lineIndex < lines.count else {
            entries.remove(at: entryIndex)
            return nil
        }
        return entryIndex
    }
}
