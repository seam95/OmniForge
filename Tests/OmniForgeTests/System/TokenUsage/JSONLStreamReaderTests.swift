import Foundation
import XCTest
@testable import OmniForge

/// JSONL 增量游标读取：inode/offset、截断归零、尾部不完整行回退 — 纯逻辑（参考 02）。
final class JSONLStreamReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLStreamReaderTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func append(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(Data(contents.utf8))
        try handle.close()
    }

    private func byteLength(_ s: String) -> UInt64 { UInt64(s.utf8.count) }

    private func expectedInode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber).map { $0.uint64Value } ?? 0
    }

    // MARK: - 增量读

    // MARK: - 分块流式读取（审查 R17）

    /// 流式读取与批量读取语义等价（小文件单块）。
    func test_forEachLine_matchesBatchRead() throws {
        let url = try makeFile(name: "eq.jsonl", contents: "a\nb\nc\n")

        var streamed: [String] = []
        let cursor = JSONLStreamReader.forEachLine(fileURL: url, previous: nil) { line in
            streamed.append(line)
        }

        let batch = JSONLStreamReader.read(fileURL: url, previous: nil)
        XCTAssertEqual(streamed, batch?.lines ?? [])
        XCTAssertEqual(cursor?.offset, batch?.cursor.offset)
    }

    /// 跨块边界（1MB+）的行：UTF-8 内容完整、行数正确、游标正确。
    func test_forEachLine_handlesLinesSpanningChunkBoundaries() throws {
        // 两行各约 1.2MB 中文（UTF-8 每字 3 字节），均以换行结尾、跨 1MB 块边界。
        let bigLine = String(repeating: "中文内容行", count: 100_000)  // ≈1.2MB
        let url = try makeFile(name: "big.jsonl", contents: bigLine + "\n" + bigLine + "\n")

        var lengths: [Int] = []
        var lines = 0
        let cursor = JSONLStreamReader.forEachLine(fileURL: url, previous: nil) { line in
            lines += 1
            lengths.append(line.utf8.count)
        }

        XCTAssertEqual(lines, 2, "跨块换行正确分两行")
        XCTAssertEqual(lengths.reduce(0, +), bigLine.utf8.count * 2, "UTF-8 内容完整")
        XCTAssertEqual(cursor?.offset, UInt64(bigLine.utf8.count * 2 + 2), "游标停在最后换行后")
    }

    /// 尾部半行（无换行）回退：游标停在最后完整行之后，半行等下轮。
    func test_forEachLine_partialTrailingLineRolledBack() throws {
        let full = "line1\nline2\n"
        let url = try makeFile(name: "partial.jsonl", contents: full + "half")

        var lines: [String] = []
        let cursor = JSONLStreamReader.forEachLine(fileURL: url, previous: nil) { line in
            lines.append(line)
        }

        XCTAssertEqual(lines, ["line1", "line2"])
        XCTAssertEqual(cursor?.offset, UInt64(full.utf8.count), "半行不计入游标")

        // 下轮补齐后半行后可读。
        try append("line3\n", to: url)
        var followUp: [String] = []
        _ = JSONLStreamReader.forEachLine(fileURL: url, previous: cursor) { line in
            followUp.append(line)
        }
        XCTAssertEqual(followUp, ["halfline3"])
    }

    /// 超长行（> maxLineBytes 无换行）：返回 nil，调用方保留旧游标可重试。
    func test_forEachLine_overlongLineReturnsNil() throws {
        let junk = Data(count: JSONLStreamReader.maxLineBytes + 1024)
        let url = directory.appendingPathComponent("overlong.jsonl")
        try junk.write(to: url)

        var consumed = 0
        let cursor = JSONLStreamReader.forEachLine(fileURL: url, previous: nil) { _ in
            consumed += 1
        }

        XCTAssertNil(cursor, "超长行必须显式失败（不静默跳过）")
        XCTAssertEqual(consumed, 0)
    }

    /// 增量语义：游标后续读只拿新增字节。
    func test_forEachLine_incremental() throws {
        let url = try makeFile(name: "inc.jsonl", contents: "one\n")
        let first = JSONLStreamReader.forEachLine(fileURL: url, previous: nil) { _ in }

        try append("two\n", to: url)
        var lines: [String] = []
        _ = JSONLStreamReader.forEachLine(fileURL: url, previous: first) { line in
            lines.append(line)
        }

        XCTAssertEqual(lines, ["two"], "增量只读新增段")
    }

    func test_firstRead_returnsAllLinesAndCursor() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\nl2\n")
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        XCTAssertEqual(outcome.lines, ["l1", "l2"])
        XCTAssertEqual(outcome.cursor.offset, byteLength("l1\nl2\n"))
        XCTAssertGreaterThan(outcome.cursor.inode, 0)
        XCTAssertFalse(outcome.reset)
    }

    func test_incrementalRead_returnsOnlyNewBytes() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\nl2\n")
        let first = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        try append("l3\n", to: url)
        let second = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: first.cursor))
        XCTAssertFalse(second.reset)
        XCTAssertEqual(second.lines, ["l3"])
        XCTAssertEqual(second.cursor.offset, byteLength("l1\nl2\nl3\n"))
    }

    func test_incrementalRead_noNewBytes_returnsEmpty() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\n")
        let first = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        let second = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: first.cursor))
        XCTAssertTrue(second.lines.isEmpty)
        XCTAssertEqual(second.cursor, first.cursor)
    }

    // MARK: - 截断与换 inode

    func test_truncation_resetsOffsetAndReReadsAll() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\nl2\nl3\n")
        let first = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        XCTAssertEqual(first.cursor.offset, byteLength("l1\nl2\nl3\n"))
        try Data("l1\n".utf8).write(to: url) // 截断：offset > size
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: first.cursor))
        XCTAssertTrue(outcome.reset, "offset 大于 size 必须归零重读")
        XCTAssertEqual(outcome.lines, ["l1"])
        XCTAssertEqual(outcome.cursor.offset, byteLength("l1\n"))
    }

    func test_inodeChange_resetsOffset() throws {
        let urlA = try makeFile(name: "a.jsonl", contents: "l1\n")
        let urlB = try makeFile(name: "b.jsonl", contents: "x1\nx2\n")
        let cursorA = try XCTUnwrap(JSONLStreamReader.read(fileURL: urlA, previous: nil)).cursor
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: urlB, previous: cursorA))
        XCTAssertTrue(outcome.reset, "inode 变化视为新文件，从头读")
        XCTAssertEqual(outcome.lines, ["x1", "x2"])
    }

    // MARK: - 尾部不完整行

    func test_partialTrailingLine_rolledBackUntilNewline() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\nparti")
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        XCTAssertEqual(outcome.lines, ["l1"], "尾部无换行的半行不解析")
        XCTAssertEqual(outcome.cursor.offset, byteLength("l1\n"))
        // 补全后下一轮只读半行
        try append("al\n", to: url)
        let second = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: outcome.cursor))
        XCTAssertEqual(second.lines, ["partial"])
        XCTAssertEqual(second.cursor.offset, byteLength("l1\npartial\n"))
    }

    func test_fileEndingWithNewline_noLeftOver() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\n\nl2\n")
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        XCTAssertEqual(outcome.lines, ["l1", "", "l2"])
        XCTAssertEqual(outcome.cursor.offset, byteLength("l1\n\nl2\n"))
    }

    // MARK: - 边界

    func test_missingFile_returnsNil() throws {
        let url = directory.appendingPathComponent("missing.jsonl")
        XCTAssertNil(JSONLStreamReader.read(fileURL: url, previous: nil))
    }

    func test_emptyFile_returnsZeroCursor() throws {
        let url = try makeFile(name: "a.jsonl", contents: "")
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        XCTAssertTrue(outcome.lines.isEmpty)
        XCTAssertEqual(outcome.cursor.offset, 0)
        XCTAssertGreaterThan(outcome.cursor.inode, 0)
    }

    func test_cursorRecordsSystemFileNumber() throws {
        let url = try makeFile(name: "a.jsonl", contents: "l1\n")
        let outcome = try XCTUnwrap(JSONLStreamReader.read(fileURL: url, previous: nil))
        XCTAssertEqual(outcome.cursor.inode, try expectedInode(url))
    }
}
