import Foundation
import XCTest
@testable import OmniForge

/// Claude 用量采集器：回填调度（非阻塞）、增量扫描、截断/游标丢失重读去重、信号合并、定时兜底。
final class ClaudeUsageCollectorTests: XCTestCase {
    private var projectsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: ClaudeUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    override func setUpWithError() throws {
        projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = ClaudeUsageCollector(
            store: store,
            projectsDirectory: projectsDir,
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
        try? FileManager.default.removeItem(at: projectsDir)
    }

    // MARK: - 工具

    /// 泵主队列直到条件满足（采集器回调走 DispatchQueue.main，需显式泵送）。
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

    private func writeFile(_ name: String, contents: String) throws -> URL {
        let url = projectsDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func appendFile(_ name: String, contents: String) throws {
        let url = projectsDir.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(Data(contents.utf8))
        try handle.close()
    }

    private func usageLine(id: String, model: String = "deepseek-v4-flash", tokens: Int, timestamp: String = "2026-08-22T01:50:04Z") -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","uuid":"u-\(id)","requestId":null,"message":\
        {"id":"\(id)","type":"assistant","model":"\(model)","usage":{"input_tokens":\(tokens),"output_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"s"}]}}
        """
    }

    private func userLine(uuid: String, timestamp: String = "2026-08-22T01:51:00Z") -> String {
        """
        {"type":"user","timestamp":"\(timestamp)","uuid":"\(uuid)","message":{"role":"user",\
        "content":[{"type":"text","text":"hello"}]}}
        """
    }

    // MARK: - 回填调度

    func test_start_triggersBackfillAsynchronously_andPublishesStates() throws {
        let file = try writeFile("sess-a.jsonl", contents: usageLine(id: "m1", tokens: 100) + "\n")
        collector.start()
        // start 立即返回；回填在后台队列执行。
        XCTAssertEqual(collector.scanCount, 0, "扫描尚未开始（队列异步）")
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 && self.backfillStates.count == 2 }

        XCTAssertEqual(backfillStates, [true, false], "首次扫描经历回填中 → 完成")
        XCTAssertEqual(usageChanges, 1)
        XCTAssertEqual(store.totalTokens(), 100)
        XCTAssertEqual(store.seenKeys, ["m1"])
        let expectedCursor = expectCursorFor(file: file, contents: usageLine(id: "m1", tokens: 100) + "\n")
        XCTAssertEqual(store.cursors[file.standardizedFileURL.path], expectedCursor)
        XCTAssertEqual(watcher.watchedURL, projectsDir)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(scheduler.lastInterval, ClaudeUsageCollector.defaultScanInterval, "5 分钟兜底")
    }

    func test_start_timerFallbackTriggersScans() throws {
        try writeFile("sess-a.jsonl", contents: usageLine(id: "m1", tokens: 100) + "\n")
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 100)

        scheduler.fire()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(collector.scanCount, 2, "定时兜底触发增量扫描")
        XCTAssertEqual(store.totalTokens(), 100, "无新字节不重复计数")
    }

    func test_stop_stopsWatcherAndTimer() throws {
        try writeFile("sess-a.jsonl", contents: usageLine(id: "m1", tokens: 1) + "\n")
        collector.start()
        collector.waitForIdle()
        collector.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertNil(watcher.watchedURL)
        XCTAssertEqual(scheduler.activeScheduleCount, 0, "定时器被取消")
    }

    func test_start_isIdempotent() throws {
        try writeFile("sess-a.jsonl", contents: usageLine(id: "m1", tokens: 1) + "\n")
        collector.start()
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(collector.scanCount, 1, "重复 start 不应重复扫描")
    }

    // MARK: - 增量与去重

    func test_rescan_withPersistedCursor_readsOnlyNewMessages() throws {
        let file = try writeFile("sess-a.jsonl", contents: usageLine(id: "m1", tokens: 100) + "\n")
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let contents2 = usageLine(id: "m1", tokens: 100) + "\n" + usageLine(id: "m2", tokens: 40) + "\n"
        try appendFile("sess-a.jsonl", contents: usageLine(id: "m2", tokens: 40) + "\n")
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(store.totalTokens(), 140, "增量只读新增行")
        XCTAssertEqual(store.seenKeys, ["m1", "m2"])
        XCTAssertEqual(store.cursors[file.standardizedFileURL.path]?.offset, UInt64(contents2.utf8.count))
    }

    func test_missingCursor_rescansFromZeroWithoutDoubleCount() throws {
        let name = "sess-a.jsonl"
        let contents = usageLine(id: "m1", tokens: 100) + "\n" + usageLine(id: "m2", tokens: 40) + "\n"
        try writeFile(name, contents: contents)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 140)

        // 游标丢失（如备份恢复/首次迁移）→ 从头重读，但已见 key 去重。
        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 140, "重读被去重，不重复计数")
        XCTAssertEqual(store.seenKeys, ["m1", "m2"])
    }

    func test_duplicateMessageIdWithNoRequestId_countsOnce() throws {
        let name = "sess-a.jsonl"
        let base = usageLine(id: "dup-1", tokens: 100)
        try writeFile(name, contents: base + "\n" + base + "\n")
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 100, "同 message.id 重复行只计一次（无 requestId 兜底）")

        // 游标丢失重读仍然只计一次（已见集合跨 sync 持久化）。
        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 100, "重读被去重，不重复计数")
    }

    func test_conversationCounting_perUserLine() throws {
        try writeFile("sess-a.jsonl", contents: userLine(uuid: "turn-1") + "\n" + userLine(uuid: "turn-2") + "\n")
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.conversations(), 2, "每条 user 行计 1 会话（turn）")
        XCTAssertEqual(store.seenKeys, ["u:turn-1", "u:turn-2"])

        // user 行去重（游标丢失重读）。
        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.conversations(), 2)
    }

    func test_subagentFiles_usageCountedConversionsNot() {
        let sub = projectsDir.appendingPathComponent("subagents", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data((userLine(uuid: "sub-1") + "\n").utf8).write(to: sub.appendingPathComponent("s.jsonl"))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.conversations(), 0, "subagents 内 user 行不计会话")
        XCTAssertTrue(store.seenKeys.isEmpty, "subagents 内 user 行也不写 key")
    }

    // MARK: - 信号合并

    func test_signalsDuringScan_coalesce() {
        store.upsertDelay = 0.25
        try? Data((usageLine(id: "m1", tokens: 10) + "\n").utf8).write(to: projectsDir.appendingPathComponent("sess-a.jsonl"))
        collector.start()
        // 等扫描进入 performScan（upsert 睡眠窗口）再投信号：信号在扫描中到达 → 合并。
        Thread.sleep(forTimeInterval: 0.05)
        for _ in 0..<6 { watcher.simulateChange() }
        // rescan 由扫描循环内部从队列再入队，waitForIdle 可能赶在其前返回，需泵到计数。
        pumpUntil { self.collector.scanCount == 2 }
        collector.waitForIdle()
        XCTAssertEqual(collector.scanCount, 2, "扫描中到达的信号合并为一次后续扫描")
        XCTAssertEqual(store.totalTokens(), 10)
    }

    // MARK: - 目录/文件枚举

    func test_scan_parsesAllJsonlRecursively_andSkipsBadLines() throws {
        try writeFile("sess-a.jsonl", contents: usageLine(id: "m1", tokens: 20) + "\n")
        let sub = projectsDir.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data((usageLine(id: "m2", tokens: 30) + "\n").utf8).write(to: sub.appendingPathComponent("sub.jsonl"))
        try writeFile("notes.txt", contents: "not jsonl")
        // 坏行：非 JSON → 跳过不崩
        try appendFile("sess-a.jsonl", contents: "{broken json\n")

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 50, "递归含 subagents 且坏行跳过")
    }

    private func expectCursorFor(file: URL, contents: String) -> JSONLCursor? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return JSONLCursor(inode: inode, offset: UInt64(contents.utf8.count))
    }
}
