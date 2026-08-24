import Foundation
import XCTest
@testable import OmniForge

/// dsh 用量采集器：回填调度、seq/字节游标幂等、头部模型回退、zstd 跳过。
final class DshUsageCollectorTests: XCTestCase {
    private var sessionsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: DshUsageCollector!

    override func setUpWithError() throws {
        sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DshUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = DshUsageCollector(
            store: store,
            sessionsDirectory: sessionsDir,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: sessionsDir.deletingLastPathComponent())
    }

    private func pumpUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    /// 写入单会话 `session.jsonl`，返回文件 URL。
    private func writeSession(
        project: String = "p",
        session: String = "s1",
        lines: [String]
    ) throws -> URL {
        let dir = sessionsDir.appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func sessionHeader(_ id: String) -> String {
        "{\"type\":\"session\",\"id\":\"\(id)\"}"
    }

    private func requestHeader(model: String) -> String {
        "{\"type\":\"request/header\",\"seq\":1,\"data\":{\"header\":{\"config\":{\"model\":\"\(model)\"}}}}"
    }

    private func assistantLine(
        seq: Int,
        time: Double = 1_784_502_000_000,
        model: String? = nil,
        input: Int,
        output: Int
    ) -> String {
        let source = model.map { "\"message\":{\"source\":{\"model\":\"\($0)\"}}," } ?? ""
        return "{\"type\":\"assistant/message\",\"seq\":\(seq),\"time\":\(Int(time)),\"data\":{\(source)\"usage\":{\"inputTokens\":\(input),\"outputTokens\":\(output),\"cacheReadTokens\":0,\"cacheWriteTokens\":0,\"reasoningTokens\":0}}}"
    }

    // MARK: - 基本扫描

    func test_scan_countsUsageWithHeaderModelFallback() throws {
        try writeSession(lines: [
            sessionHeader("s1"),
            requestHeader(model: "deepseek/deepseek-v4-pro"),
            assistantLine(seq: 3, input: 100, output: 20),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 120)
        XCTAssertEqual(store.conversations(), 1, "每条 assistant/message 计 1 会话")
        // 模型回退链：行内 source.model 缺失 → headerModel（剥离前缀）。
        let buckets = store.bucketsByKey.filter { $0.key.provider == .dsh }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.key.model, "deepseek-v4-pro")
    }

    func test_scan_sourceModelWinsOverHeader() throws {
        try writeSession(lines: [
            sessionHeader("s1"),
            requestHeader(model: "deepseek/deepseek-v4-pro"),
            assistantLine(seq: 3, model: "deepseek-v4-flash", input: 10, output: 5),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        let buckets = store.bucketsByKey.filter { $0.key.provider == .dsh }
        XCTAssertEqual(buckets.first?.key.model, "deepseek-v4-flash")
    }

    func test_scan_skipsLinesWithoutUsageAndBadJson() throws {
        try writeSession(lines: [
            sessionHeader("s1"),
            requestHeader(model: "deepseek-v4-pro"),
            assistantLine(seq: 4, input: 50, output: 0),
            "{broken json",
            "{\"type\":\"user/message\",\"seq\":5,\"data\":{\"message\":{\"content\":\"hello\"}}}",
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 50, "坏行/无 usage 行跳过，不影响整文件")
    }

    // MARK: - 增量与去重

    func test_incrementalAppend_countsOnlyNewLines() throws {
        let file = try writeSession(lines: [
            sessionHeader("s1"),
            requestHeader(model: "deepseek-v4-pro"),
            assistantLine(seq: 3, input: 100, output: 20),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120)

        try append(file, lines: [assistantLine(seq: 4, input: 30, output: 10)])
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 160, "增量只读新增行")
    }

    func test_cursorLoss_rescanDoesNotDoubleCount() throws {
        try writeSession(lines: [
            sessionHeader("s1"),
            requestHeader(model: "deepseek-v4-pro"),
            assistantLine(seq: 3, input: 100, output: 20),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120)

        // 游标丢失 → 从头重读，但 seq→dedup key 去重（dsh:<sessionId>:<seq>）。
        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 120, "重读被去重，不重复计数")
    }

    func test_stop_stopsWatcherAndTimer() throws {
        try writeSession(lines: [sessionHeader("s1"), assistantLine(seq: 1, input: 1, output: 0)])
        collector.start()
        collector.waitForIdle()
        collector.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(scheduler.activeScheduleCount, 0)
    }

    // MARK: - 文件枚举

    func test_zstdArtifactsSkipped() throws {
        // 仅未压缩 session.jsonl 被采集；.zstd 文件存在不报错、不计数。
        let dir = sessionsDir.appendingPathComponent("p", isDirectory: true)
            .appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not actually zstd".utf8).write(
            to: dir.appendingPathComponent("session.jsonl.zstd")
        )
        try writeSession(project: "p2", session: "s2", lines: [
            sessionHeader("s2"),
            requestHeader(model: "deepseek-v4-flash"),
            assistantLine(seq: 1, input: 77, output: 1),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 78, "zstd 文件跳过，未压缩行照常计数")
    }

    private func append(_ file: URL, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }
}