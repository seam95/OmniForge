import Foundation
import XCTest
@testable import OmniForge

/// Codex 用量采集器：rollout JSONL 回填/增量/截断重读去重、cached 减法、model 归桶、首尾通知。
final class CodexUsageCollectorTests: XCTestCase {
    private var codexHome: URL!
    private var sessionsDir: URL!
    private var archivedDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: CodexUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    override func setUpWithError() throws {
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        sessionsDir = codexHome.appendingPathComponent("sessions", isDirectory: true)
        archivedDir = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = CodexUsageCollector(
            store: store,
            sessionsDirectory: sessionsDir,
            archivedDirectory: archivedDir,
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
        try? FileManager.default.removeItem(at: codexHome)
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

    private func appendText(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(Data(contents.utf8))
        try handle.close()
    }

    private func writeRollout(
        _ base: URL,
        name: String = "rollout-2026-08-22-11111111-2222-3333-4444-555555555555.jsonl",
        contents: String
    ) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func readLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private func sessionMetaLine(
        id: String = "11111111-2222-3333-4444-555555555555",
        provider: String = "openai"
    ) -> String {
        """
        {"type":"session_meta","timestamp":"2026-08-22T01:30:00Z","payload":{"id":"\(id)","cwd":"/work","cli_version":"1.0","model_provider":"\(provider)"}}
        """
    }

    private func turnContextLine(model: String) -> String {
        """
        {"type":"turn_context","timestamp":"2026-08-22T01:31:00Z","payload":{"cwd":"/work","model":"\(model)"}}
        """
    }

    private func tokenCountLine(
        last: [String: Int]?,
        total: [String: Int],
        timestamp: String = "2026-08-22T01:50:04Z"
    ) -> String {
        let info: [String: Any] = (last.map { ["last_token_usage": $0] } ?? [:])
            .merging(["total_token_usage": total]) { _, new in new }
        let json = try! JSONSerialization.data(withJSONObject: [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ] as [String: Any],
        ])
        return String(decoding: json, as: UTF8.self)
    }

    private func usageDict(input: Int = 0, cached: Int = 0, creation: Int? = nil, output: Int = 0, total: Int) -> [String: Int] {
        var dict: [String: Int] = [
            "input_tokens": input, "cached_input_tokens": cached,
            "output_tokens": output, "total_tokens": total,
        ]
        if let creation { dict["cache_creation_input_tokens"] = creation }
        return dict
    }

    // MARK: - 回填

    func test_start_backfillsAndBucketsByModel() throws {
        let file = try writeRollout(sessionsDir, contents: readLines([
            sessionMetaLine(),
            turnContextLine(model: "gpt-5-codex"),
            tokenCountLine(last: usageDict(input: 30, cached: 5, output: 5, total: 40), total: usageDict(input: 30, cached: 5, output: 5, total: 40)),
            tokenCountLine(last: usageDict(input: 20, output: 2, total: 22), total: usageDict(input: 50, cached: 5, output: 7, total: 62), timestamp: "2026-08-22T01:55:00Z"),
        ]))
        collector.start()
        XCTAssertEqual(collector.scanCount, 0, "start 立即返回，回填后台执行")
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 && self.backfillStates.count == 2 }

        XCTAssertEqual(backfillStates, [true, false], "首次扫描经历回填中 → 完成")
        XCTAssertEqual(usageChanges, 1)
        XCTAssertEqual(store.totalTokens(), 52, "两条 last 事件（25+5=30 与 22）cached 减法后合计 52")
        let bucket = store.bucketsByKey.first { $0.value.key.model == "gpt-5-codex" }?.value
        XCTAssertEqual(bucket?.usage.inputTokens, 25 + 20, "i1 = max(0, 30-5) = 25；i2 = 20")
        XCTAssertEqual(bucket?.usage.cachedInputTokens, 5)
        XCTAssertEqual(bucket?.usage.totalTokens, 52)

        let stored = store.cursors[file.standardizedFileURL.path]
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.offset, UInt64(readLines([
            sessionMetaLine(),
            turnContextLine(model: "gpt-5-codex"),
            tokenCountLine(last: usageDict(input: 30, cached: 5, output: 5, total: 40), total: usageDict(input: 30, cached: 5, output: 5, total: 40)),
            tokenCountLine(last: usageDict(input: 20, output: 2, total: 22), total: usageDict(input: 50, cached: 5, output: 7, total: 62), timestamp: "2026-08-22T01:55:00Z"),
        ]).utf8.count), "游标停在文件末尾（只读新增）")
        XCTAssertEqual(store.seenKeys.count, 2, "两条 token_count 事件写入去重 key")
        XCTAssertEqual(watcher.watchedURL, sessionsDir)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(scheduler.lastInterval, CodexUsageCollector.defaultScanInterval, "5 分钟兜底")
    }

    func test_backfill_streamStartWithoutLastCountsCumulativeTotal() throws {
        // 整读起点无 last 的事件：累计值即首次增量（参考 consumeUsageDelta 兜底）。
        try writeRollout(sessionsDir, contents: readLines([
            sessionMetaLine(),
            tokenCountLine(last: nil, total: usageDict(input: 60, cached: 10, output: 5, total: 75)),
        ]))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 55, "cached 减法后 input 50 + output 5 = 55（缓存不计入总量）")
    }

    // MARK: - 增量 / 去重 / 截断

    func test_rescan_readsOnlyNewBytes() throws {
        let contents1 = readLines([
            sessionMetaLine(),
            turnContextLine(model: "gpt-5-codex"),
            tokenCountLine(last: usageDict(input: 100, total: 100), total: usageDict(input: 100, total: 100)),
        ])
        let file = try writeRollout(sessionsDir, contents: contents1)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 100)

        try appendText(readLines([
            tokenCountLine(last: usageDict(input: 40, total: 40), total: usageDict(input: 140, total: 140), timestamp: "2026-08-22T01:56:00Z"),
        ]), to: file)
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(store.totalTokens(), 140, "增量只读新增尾部")
        XCTAssertEqual(store.cursors[file.standardizedFileURL.path]?.offset,
                       UInt64(contents1.utf8.count + readLines([
                           tokenCountLine(last: usageDict(input: 40, total: 40), total: usageDict(input: 140, total: 140), timestamp: "2026-08-22T01:56:00Z"),
                       ]).utf8.count))
    }

    func test_missingCursor_rescansFromZeroWithoutDoubleCount() throws {
        try writeRollout(sessionsDir, contents: readLines([
            sessionMetaLine(),
            tokenCountLine(last: usageDict(input: 100, total: 100), total: usageDict(input: 100, total: 100)),
            tokenCountLine(last: usageDict(input: 40, total: 40), total: usageDict(input: 140, total: 140), timestamp: "2026-08-22T01:56:00Z"),
        ]))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 140)

        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 140, "游标丢失重读被已见 key 去重")
    }

    func test_truncatedFile_resetsOffsetAndDeduplicates() throws {
        let contents = readLines([
            sessionMetaLine(),
            tokenCountLine(last: usageDict(input: 500, total: 500), total: usageDict(input: 500, total: 500)),
        ])
        let file = try writeRollout(sessionsDir, contents: contents)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 500)

        // 截断重写（内容更短且换代）：offset > size → 归零重读；去重 key 防重复计费。
        try Data("x".utf8).write(to: file)
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 500, "截断重读不重复计费")
        XCTAssertEqual(store.cursors[file.standardizedFileURL.path]?.offset, 0, "残行无完整行 → 游标回到 0（未消费字节）")
    }

    func test_cachedSubtraction_preventsDoubleCount() throws {
        let gpt = try writeRollout(sessionsDir, name: "rollout-2026-08-22-22222222-2222-3333-4444-555555555555.jsonl", contents: readLines([
            sessionMetaLine(id: "22222222-2222-3333-4444-555555555555"),
            turnContextLine(model: "gpt-5.2-codex"),
            tokenCountLine(last: usageDict(input: 100, cached: 80, output: 10, total: 110), total: usageDict(input: 100, cached: 80, output: 10, total: 110)),
        ]))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        let bucket = try XCTUnwrap(store.bucketsByKey.first { $0.value.key.model == "gpt-5.2-codex" }?.value)
        XCTAssertEqual(bucket.usage.inputTokens, 20, "input = max(0, 100-80)")
        XCTAssertEqual(bucket.usage.cachedInputTokens, 80)
        XCTAssertEqual(bucket.usage.totalTokens, 30, "20 + 0 + 0 + 10，缓存不计入总量")
        XCTAssertEqual(store.totalTokens(), 30)
        XCTAssertEqual(store.seenKeys.count, 1)
        XCTAssertNotNil(store.cursors[gpt.standardizedFileURL.path])
    }

    func test_incrementalTailWithoutLast_isSkipped() throws {
        try writeRollout(sessionsDir, contents: readLines([
            sessionMetaLine(),
            tokenCountLine(last: usageDict(input: 100, total: 100), total: usageDict(input: 100, total: 100)),
        ]))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 100)

        // 增量尾部出现「无 last」事件：无法确定差值 → 保守跳过，绝不把累计值当增量。
        let tail = tokenCountLine(last: nil, total: usageDict(input: 130, total: 130), timestamp: "2026-08-22T01:57:00Z")
        try appendText(readLines([tail]), to: sessionsDir.appendingPathComponent("rollout-2026-08-22-11111111-2222-3333-4444-555555555555.jsonl"))
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 100, "无 last 且无本文件上一轮累计 → 跳过")
    }

    // MARK: - 文件枚举与跨备份去重

    func test_archivedDuplicate_countedOnce() throws {
        let contents = readLines([
            sessionMetaLine(),
            tokenCountLine(last: usageDict(input: 200, total: 200), total: usageDict(input: 200, total: 200)),
        ])
        try writeRollout(sessionsDir, contents: contents)
        try writeRollout(archivedDir, contents: contents)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 200, "session 与 archived 同流事件只计一次（跨文件去重）")
        XCTAssertEqual(store.seenKeys.count, 1)
    }

    func test_scan_ignoresNonRolloutJsonl_andBadLines() throws {
        // 无关 jsonl（如 conversations.jsonl / notes.jsonl）不在采集范围；坏行跳过。
        let noise = sessionsDir.appendingPathComponent("conversations.jsonl")
        try Data(readLines([
            sessionMetaLine(),
            tokenCountLine(last: usageDict(input: 999, total: 999), total: usageDict(input: 999, total: 999)),
        ]).utf8).write(to: noise)
        let rollout = try writeRollout(sessionsDir, contents: readLines([
            sessionMetaLine(),
            "{broken json\n",
            tokenCountLine(last: usageDict(input: 12, total: 12), total: usageDict(input: 12, total: 12)),
        ]))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 12, "非 rollout 文件不解析；坏行跳过")
        XCTAssertNil(store.cursors[noise.standardizedFileURL.path], "无关文件无游标")
        XCTAssertNotNil(store.cursors[rollout.standardizedFileURL.path])
    }

    func test_modelFallsBackToSessionMetaProvider() throws {
        // 无 turn_context 时按 session_meta.model_provider 归桶（参考 parseCodexRolloutFile）。
        try writeRollout(sessionsDir, contents: readLines([
            sessionMetaLine(provider: "openai"),
            tokenCountLine(last: usageDict(input: 30, total: 30), total: usageDict(input: 30, total: 30)),
        ]))
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        let bucket = store.bucketsByKey.first { $0.value.key.provider == .codex }?.value
        XCTAssertEqual(bucket?.key.model, "openai")
        XCTAssertEqual(bucket?.usage.totalTokens, 30)
    }

    func test_start_inUnitTestProcess_doesNotScanRealUserDirectory() throws {
        // 生产接线（FeatureRuntime bootstrap / AppState）会以默认目录构造并启动采集器；
        // 测试进程不得扫描用户正在写入的 ~/.codex（与真实应用争用 GRDB → 游标写入
        // 失败回调、反复全量重扫）。注入目录的测试不受此限制。
        let realCollector = CodexUsageCollector(store: store)
        realCollector.start()
        realCollector.waitForIdle()
        XCTAssertEqual(realCollector.scanCount, 0, "测试进程下默认目录采集器不启动扫描")
        XCTAssertNil(store.cursors.first, "不写入任何游标")
        realCollector.stop()
    }

    // MARK: - 生命周期

    func test_stop_stopsWatcherAndTimer() throws {
        collector.start()
        collector.waitForIdle()
        collector.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertNil(watcher.watchedURL)
        XCTAssertEqual(scheduler.activeScheduleCount, 0, "定时器被取消")
    }
}
