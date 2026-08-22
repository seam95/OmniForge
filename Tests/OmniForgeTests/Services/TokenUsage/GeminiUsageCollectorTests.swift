import Foundation
import XCTest
@testable import OmniForge

/// Gemini 用量采集器：整文件 JSON 会话快照解析（消息级累计差量）、去重、
/// size/inode 变更重扫、单元测试环境防探针。
final class GeminiUsageCollectorTests: XCTestCase {
    private var geminiHome: URL!
    private var tmpDir: URL!
    private var chatsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: GeminiUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    override func setUpWithError() throws {
        geminiHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        tmpDir = geminiHome.appendingPathComponent("tmp", isDirectory: true)
        chatsDir = tmpDir.appendingPathComponent("deadbeef/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = GeminiUsageCollector(
            store: store,
            tmpDirectory: tmpDir,
            scheduler: scheduler,
            watcher: watcher
        )
        backfillStates = []
        usageChanges = 0
        collector.onBackfillStateChange = { [weak self] value in
            self?.backfillStates.append(value)
        }
        collector.onUsageDidChange = { [weak self] _ in
            self?.usageChanges += 1
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: geminiHome)
    }

    // MARK: - 工具

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

    private func message(
        id: String,
        timestamp: String? = "2025-12-26T08:05:00.000Z",
        model: String = "gemini-3-flash-preview",
        tokens: [String: Int]? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = ["id": id, "type": "assistant"]
        if let timestamp { dict["timestamp"] = timestamp }
        dict["model"] = model
        if let tokens { dict["tokens"] = tokens }
        return dict
    }

    private func tokens(input: Int, output: Int, cached: Int = 0, thoughts: Int = 0, tool: Int = 0, total: Int) -> [String: Int] {
        ["input": input, "output": output, "cached": cached, "thoughts": thoughts, "tool": tool, "total": total]
    }

    private func writeSession(named name: String = "session-abc123.json", messages: [[String: Any]]) throws -> URL {
        let url = chatsDir.appendingPathComponent(name)
        let root: [String: Any] = [
            "sessionId": "session-id",
            "projectHash": "project-hash",
            "startTime": "2025-12-26T08:00:00.000Z",
            "lastUpdated": "2025-12-26T09:00:00.000Z",
            "messages": messages,
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    // MARK: - 回填

    func test_start_backfillsAndBucketsByModel() throws {
        // 参考固定：m1/m2/m3 为单调累计快照，m3 可比的差量仅计增量。
        let file = try writeSession(messages: [
            message(id: "m1", tokens: tokens(input: 5, output: 1, total: 6)),
            message(id: "m2", timestamp: "2025-12-26T08:10:00.000Z", tokens: tokens(input: 8, output: 2, total: 10)),
            message(id: "m3", timestamp: "2025-12-26T08:15:00.000Z", tokens: tokens(input: 9, output: 3, total: 12)),
        ])
        collector.start()
        XCTAssertEqual(collector.scanCount, 0, "start 立即返回，回填后台执行")
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 && self.backfillStates.count == 2 }

        XCTAssertEqual(backfillStates, [true, false], "首次扫描经历回填中 → 完成")
        XCTAssertEqual(usageChanges, 1)
        let bucket = store.bucketsByKey.first { $0.value.key.provider == .gemini }?.value
        XCTAssertEqual(bucket?.key.model, "gemini-3-flash-preview")
        XCTAssertEqual(bucket?.usage.inputTokens, 9, "m1 5 + m2 3 + m3 1")
        XCTAssertEqual(bucket?.usage.cachedInputTokens, 0)
        XCTAssertEqual(bucket?.usage.outputTokens, 3, "1 + 1 + 1")
        XCTAssertEqual(bucket?.usage.totalTokens, 12)
        XCTAssertEqual(bucket?.conversationCount, 3, "三条可计数消息")
        XCTAssertEqual(store.seenKeys.count, 3)

        let stored = store.cursors[file.standardizedFileURL.path]
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.offset, UInt64((try! Data(contentsOf: file)).count), "整文件游标停在文件大小")
        XCTAssertEqual(watcher.watchedURL, tmpDir)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(scheduler.lastInterval, GeminiUsageCollector.defaultScanInterval, "5 分钟兜底")
    }

    func test_backfill_normalizesCachedAndTool_singleSnapshot() throws {
        // 参考 recomputes-total：Gemini 自报 total 不含 cached → 四列重算；tool 并入 output。
        try writeSession(messages: [
            message(id: "m1", tokens: tokens(input: 10, output: 5, cached: 20, thoughts: 3, tool: 2, total: 17)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        let bucket = try XCTUnwrap(store.bucketsByKey.first { $0.value.key.provider == .gemini }?.value)
        XCTAssertEqual(bucket.usage.inputTokens, 10)
        XCTAssertEqual(bucket.usage.cachedInputTokens, 20)
        XCTAssertEqual(bucket.usage.outputTokens, 7, "output + tool")
        XCTAssertEqual(bucket.usage.reasoningOutputTokens, 3)
        XCTAssertEqual(bucket.usage.totalTokens, 40, "input + cached + output + thoughts")
        XCTAssertEqual(store.totalTokens(), 40)
    }

    // MARK: - 差量口径

    func test_duplicateCumulativeSnapshot_countedOnce() throws {
        let snapshot = tokens(input: 5, output: 1, total: 6)
        try writeSession(messages: [
            message(id: "m1", tokens: snapshot),
            message(id: "m2", timestamp: "2025-12-26T08:10:00.000Z", tokens: snapshot),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 6, "重复累计快照零差量 → 只计一次")
        XCTAssertEqual(store.bucketsByKey.first?.value.conversationCount, 1)
    }

    func test_messagesWithoutTimestamp_advanceBaselineButNotCounted() throws {
        try writeSession(messages: [
            message(id: "m1", tokens: tokens(input: 5, output: 1, total: 6)),
            message(id: "m2", timestamp: nil, tokens: tokens(input: 8, output: 2, total: 10)),
            message(id: "m3", timestamp: "2025-12-26T08:15:00.000Z", tokens: tokens(input: 9, output: 3, total: 12)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 8, "m1 6 + (m3 - m2) 2；无时间戳的 m2 只推进基线")
        XCTAssertEqual(store.seenKeys.count, 2, "m2 无时间戳不计数也不写 key（之后补时间戳仍可计数）")
    }

    func test_messageWithoutID_isNotCounted() throws {
        try writeSession(messages: [
            message(id: "m1", tokens: tokens(input: 5, output: 1, total: 6)),
            message(id: "", timestamp: "2025-12-26T08:10:00.000Z", tokens: tokens(input: 9, output: 2, total: 11)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 6, "无 id 不可去重 → 保守跳过，避免重扫重复计费")
    }

    // MARK: - 增量 / 重扫 / 截断

    func test_rescan_afterFileGrows_countsOnlyNewMessages() throws {
        let file = try writeSession(messages: [
            message(id: "m1", tokens: tokens(input: 5, output: 1, total: 6)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 6)

        // 同文件追加新消息（重写整文件，size 变大）。
        try writeSession(named: file.lastPathComponent, messages: [
            message(id: "m1", tokens: tokens(input: 5, output: 1, total: 6)),
            message(id: "m2", timestamp: "2025-12-26T08:10:00.000Z", tokens: tokens(input: 8, output: 2, total: 10)),
        ])
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(store.totalTokens(), 10, "重扫整文件：m1 已见跳过，m2 差量(8-5,2-1,10-6) = (3,1,4)")
    }

    func test_truncatedFile_rewrittenShorter_rescansSafely() throws {
        let file = try writeSession(messages: [
            message(id: "m1", tokens: tokens(input: 500, output: 1, total: 501)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 501)

        try writeSession(named: file.lastPathComponent, messages: [])
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 501, "截断后重扫：空文件无消息 + 已见 key 防重复")
        XCTAssertEqual(
            store.cursors[file.standardizedFileURL.path]?.offset,
            UInt64((try! Data(contentsOf: file)).count),
            "截断后游标停在新的文件大小（下次重写仍会重扫）"
        )
    }

    func test_scan_ignoresUnrelatedFiles_andBadJSON() throws {
        let noise = chatsDir.appendingPathComponent("notes.json")
        try Data("{\"messages\":[{\"id\":\"n1\",\"tokens\":{\"total\":999}}]}".utf8).write(to: noise)
        try Data("broken".utf8).write(to: chatsDir.appendingPathComponent("session-zzz.json"))
        try writeSession(messages: [message(id: "m1", tokens: tokens(input: 12, output: 1, total: 13))])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 13, "非 session-*.json 不解析；坏 JSON 跳过")
        XCTAssertNil(store.cursors[noise.standardizedFileURL.path])
    }

    // MARK: - 测试环境保护

    func test_start_inUnitTestProcess_doesNotScanRealUserDirectory() throws {
        let realCollector = GeminiUsageCollector(store: store)
        realCollector.start()
        realCollector.waitForIdle()
        XCTAssertEqual(realCollector.scanCount, 0, "测试进程下默认目录采集器不启动扫描")
        XCTAssertNil(store.cursors.first, "不写入任何游标")
        realCollector.stop()
    }

    func test_stop_stopsWatcherAndTimer() throws {
        collector.start()
        collector.waitForIdle()
        collector.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertNil(watcher.watchedURL)
        XCTAssertEqual(scheduler.activeScheduleCount, 0, "定时器被取消")
    }
}
