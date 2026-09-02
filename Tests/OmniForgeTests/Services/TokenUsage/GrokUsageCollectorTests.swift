import Foundation
import XCTest
@testable import OmniForge

/// grok 用量采集器：turn_completed 增量、modelUsage 多模型、游标丢失去重、
/// signals-only 会话快照兜底、turn 与信号不重叠。
final class GrokUsageCollectorTests: XCTestCase {
    private var sessionsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: GrokUsageCollector!

    override func setUpWithError() throws {
        sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = GrokUsageCollector(
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

    private func sessionDir(_ cwd: String, _ sessionID: String) -> URL {
        sessionsDir.appendingPathComponent(cwd, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    /// 构造带 `modelUsage` 单模型的 turn_completed 行。
    private func turnLine(
        eventID: String,
        model: String,
        input: Double,
        output: Double,
        cached: Double = 0,
        reasoning: Double = 0,
        tsMs: Double = 1_784_356_200_000
    ) -> String {
        """
        {"timestamp":\(Int(tsMs / 1000)),"params":{"sessionId":"s","update":{"sessionUpdate":"turn_completed",\
        "prompt_id":"p","usage":{"inputTokens":\(input),"outputTokens":\(output),"totalTokens":\(input + output),\
        "cachedReadTokens":\(cached),"reasoningTokens":\(reasoning),"modelUsage":{"\(model)":\
        {"inputTokens":\(input),"outputTokens":\(output),"totalTokens":\(input + output),\
        "cachedReadTokens":\(cached),"reasoningTokens":\(reasoning)}}}},"_meta":\
        {"eventId":"\(eventID)","agentTimestampMs":\(Int(tsMs))}}}
        """
    }

    private func writeUpdates(_ dir: URL, lines: [String]) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("updates.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func append(_ file: URL, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func writeSignals(_ dir: URL, json: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("signals.json"))
    }

    // MARK: - turn 主路径

    func test_scan_countsTurnInputSplittingCached() throws {
        let dir = sessionDir("cwd", "s1")
        try writeUpdates(dir, lines: [
            turnLine(eventID: "e1", model: "grok-4.5-build", input: 100_000, output: 500, cached: 20_000, reasoning: 100, tsMs: 1_784_356_200_000),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .grok }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.key.model, "grok-4.5-build")
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 80_000 + 500 + 100, "缓存不计入总量（含 reasoning）")
        XCTAssertEqual(buckets.first?.value.usage.cachedInputTokens, 20_000)
        XCTAssertEqual(buckets.first?.value.conversationCount, 1)
    }

    func test_scan_multiModelUsageCreatesSeparateBuckets() throws {
        let dir = sessionDir("cwd", "s1")
        let line = """
        {"timestamp":1784357100,"params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed",\
        "usage":{"inputTokens":100,"outputTokens":200,"totalTokens":300,"cachedReadTokens":40,"reasoningTokens":10,\
        "modelUsage":{"grok-4.5-build":{"inputTokens":100,"outputTokens":200,"totalTokens":300,"cachedReadTokens":40,"reasoningTokens":10},\
        "grok-mini":{"inputTokens":50,"outputTokens":20,"totalTokens":70}}}},"_meta":{"eventId":"e1","agentTimestampMs":1784357100000}}}
        """
        try writeUpdates(dir, lines: [line])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .grok }
        XCTAssertEqual(buckets.count, 2, "modelUsage 拆分为两家模型桶")
        XCTAssertTrue(buckets.contains { $0.key.model == "grok-4.5-build" })
        XCTAssertTrue(buckets.contains { $0.key.model == "grok-mini" })
    }

    // MARK: - 增量与去重

    func test_incrementalAppend_countsNewTurnsOnly() throws {
        let dir = sessionDir("cwd", "s1")
        let file = try writeUpdates(dir, lines: [
            turnLine(eventID: "e1", model: "grok-4.5-build", input: 10_000, output: 100),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 10_100)

        try append(file, lines: [turnLine(eventID: "e2", model: "grok-4.5-build", input: 5_000, output: 50)])
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 15_150, "增量只读新增 turn")
    }

    func test_cursorLoss_rescanDoesNotDoubleCount() throws {
        let dir = sessionDir("cwd", "s1")
        try writeUpdates(dir, lines: [
            turnLine(eventID: "e1", model: "grok-4.5-build", input: 9_000, output: 90),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 9_090)

        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 9_090, "eventId 去重，游标丢失重读不重复计数")
    }

    // MARK: - 快照兜底

    func test_signalsOnlySession_countsOnce() throws {
        let dir = sessionDir("cwd", "sig-only")
        try writeSignals(dir, json: """
        {"primaryModelId":"grok-4.5-build","contextTokensUsed":18000,"totalTokensBeforeCompaction":0,\
        "totalTokens":20000,"lastActiveAt":"2026-07-18T10:00:00.000Z"}
        """)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .grok }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.key.model, "grok-4.5-build")
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 20_000, "信号兜底一次性估算")

        // 再次扫描不重复估算（grok:fb:<id> 幂等）。
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 20_000)
    }

    func test_signalsAlongsideUpdates_ignored() throws {
        let dir = sessionDir("cwd", "s1")
        try writeUpdates(dir, lines: [
            turnLine(eventID: "e1", model: "grok-4.5-build", input: 10_000, output: 500, cached: 2_000),
        ])
        try writeSignals(dir, json: """
        {"primaryModelId":"grok-4.5-build","contextTokensUsed":90000,"totalTokensBeforeCompaction":200000}
        """)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 10_000 - 2_000 + 500, "有 updates.jsonl 时不叠加信号兜底（缓存不计入总量）")
    }

    // MARK: - 目录监听

    func test_start_watchesSessionsDirectory() throws {
        collector.start()
        XCTAssertEqual(watcher.watchedURL, sessionsDir)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(scheduler.lastInterval, JSONLUsageCollectorBase.defaultScanInterval)
        collector.waitForIdle()
    }
}