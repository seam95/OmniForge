import Foundation

// MARK: - 增量游标

/// 文件级字节游标：`{inode, offset}`（参考 02 第一层防重）。
struct JSONLCursor: Codable, Equatable {
    /// 文件 inode（`.systemFileNumber`）。
    var inode: UInt64
    /// 起始字节偏移；文件被截断（offset > size）时归零重读。
    var offset: UInt64
    /// 可选附加信息 — Kimi Code 增量续读时的模型归属（config.update 在偏移之下）。
    /// 既有全量数据兼容位（nil）。
    var model: String?

    init(inode: UInt64, offset: UInt64, model: String? = nil) {
        self.inode = inode
        self.offset = offset
        self.model = model
    }
}

/// 一次增量读的结果。
struct JSONLReadOutcome: Equatable {
    /// 本次新读到的**完整行**（尾部无换行的半行被回退，等补齐后再读）。
    var lines: [String]
    /// 新的字节游标。
    var cursor: JSONLCursor
    /// 本次是否因 inode 变化/截断而归零重读。
    var reset: Bool
}

// MARK: - 流式读取

/// JSONL 增量读取器 — 纯逻辑（文件 I/O 封装），可单测。
///
/// 规则（参考 02）：
/// - 有游标且 inode 一致、offset <= size → 只读新增尾部；
/// - inode 变了或 offset > size（截断）→ 归零重读；
/// - 尾部不完整行（无换行结尾）延后处理：offset 回退到上一个换行之后，避免半行被解析。
enum JSONLStreamReader {
    /// 单块读取字节数（审查 R17：分块读取逐行消费，峰值内存由块与未完成尾行决定，
    /// 不随整个新增段线性增长）。
    static let chunkBytes = 1024 * 1024
    /// 单行字节预算：超过视为损坏/非预期输入，停止该文件并保留可重试进度
    /// （静默跳过会引入漏计；审查 4.3 的取舍）。
    static let maxLineBytes = 4 * 1024 * 1024

    /// 返回 nil 表示文件缺失/不可读（调用方跳过并保留旧游标）。
    static func read(
        fileURL: URL,
        previous cursor: JSONLCursor?,
        fileManager: FileManager = .default
    ) -> JSONLReadOutcome? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        let size = u64(attributes[.size])
        let inode = u64(attributes[.systemFileNumber])

        let sameInode = cursor?.inode == inode
        let truncated = sameInode && (cursor?.offset ?? 0) > size
        let startOffset = sameInode && !truncated ? (cursor?.offset ?? 0) : 0
        let reset = (!sameInode || truncated) && cursor != nil

        guard size >= startOffset else {
            // 理论不可达（truncated 分支已归零），防御性兜底。
            return JSONLReadOutcome(
                lines: [],
                cursor: JSONLCursor(inode: inode, offset: size),
                reset: true
            )
        }

        let data = readRange(of: fileURL, from: startOffset, to: size) ?? Data()
        let (lines, consumed) = splitCompleteLines(data)
        let newOffset = startOffset + consumed
        return JSONLReadOutcome(
            lines: lines,
            cursor: JSONLCursor(inode: inode, offset: newOffset),
            reset: reset
        )
    }

    /// 分块流式读取：固定块大小逐块读、逐完整行回调消费，内存峰值 =
    /// 块 + 未完成尾行（不随新增段总量线性增长，审查 R17）。
    /// 语义与 `read` 一致（inode/截断/半行回退）；超长行（> maxLineBytes）
    /// 返回 nil（停止该文件、保留旧游标，下轮可重试）。
    /// - Parameters:
    ///   - consume: 每个完整行回调（与 read 的 lines 数组同序）。
    /// - Returns: 新游标；nil = 文件缺失/不可读/超长行（调用方跳过并保留旧游标）。
    static func forEachLine(
        fileURL: URL,
        previous cursor: JSONLCursor?,
        fileManager: FileManager = .default,
        consume: (String) -> Void
    ) -> JSONLCursor? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        let size = u64(attributes[.size])
        let inode = u64(attributes[.systemFileNumber])

        let sameInode = cursor?.inode == inode
        let truncated = sameInode && (cursor?.offset ?? 0) > size
        var offset = sameInode && !truncated ? (cursor?.offset ?? 0) : 0

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        var pending = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: Self.chunkBytes),
                  !chunk.isEmpty else {
                break
            }
            offset += UInt64(chunk.count)
            pending.append(chunk)

            // 消费 pending 中的全部完整行；只保留未完成尾行。
            var rest = pending[...]
            while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
                consume(String(decoding: rest[..<newline], as: UTF8.self))
                rest = rest[rest.index(after: newline)...]
            }
            pending = Data(rest)
            if pending.count > Self.maxLineBytes {
                return nil
            }
        }

        // 尾部半行回退：游标停在最后一个完整行之后，半行等下轮补齐。
        return JSONLCursor(inode: inode, offset: offset - UInt64(pending.count))
    }

    // MARK: - private

    /// `start..< end` 内的原始字节。
    private static func readRange(of fileURL: URL, from start: UInt64, to end: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(end - start)) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// 拆行 + 不完整尾部回退。返回（完整行，已消费字节数）。
    private static func splitCompleteLines(_ data: Data) -> (lines: [String], consumed: UInt64) {
        guard !data.isEmpty else { return ([], 0) }
        var components = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard let last = components.last else { return ([], 0) }

        if data.last == UInt8(ascii: "\n") {
            // 正常结尾：全部消费，去掉 split 产生的空尾元素。
            components.removeLast()
            return (components.map { String(decoding: $0, as: UTF8.self) }, UInt64(data.count))
        }
        // 尾部半行（无换行）：回退到最后一个换行之后。
        let consumed = UInt64(data.count - last.count)
        components.removeLast()
        return (components.map { String(decoding: $0, as: UTF8.self) }, consumed)
    }

    private static func u64(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}
