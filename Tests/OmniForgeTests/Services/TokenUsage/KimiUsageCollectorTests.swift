import Foundation
import XCTest
@testable import OmniForge

/// Kimi 用量采集器：wire.jsonl 增量读（Kimi Code append_loop_event + 旧版 StatusUpdate）、
/// config.update 模型持久化、三种 usage 形状、去重、单测环境防探针。
final class KimiUsageCollectorTests: XCTestCase {
    private var codeHome: URL!
    private var codeSessionsDir: URL!
    private var legacyHome: URL!
    private var legacySessionsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: KimiUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    override func setUpWithError() throws {
        codeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".kimi-code", isDirectory: true)
        codeSessionsDir = codeHome.appendingPathComponent("sessions", isDirectory: true)
        legacyHome = codeHome.deletingLastPathComponent().appendingPathComponent(".kimi", isDirectory: true)
        legacySessionsDir = legacyHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codeSessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacySessionsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = KimiUsageCollector(
            store: store,
            codeSessionsDirectory: codeSessionsDir,
            legacySessionsDirectory: legacySessionsDir,
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
        try? FileManager.default.removeItem(at: codeHome.deletingLastPathComponent())
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

    private func writeWire(_ base: URL, relative: String, lines: [String]) throws -> URL {
        let dir = base.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wire.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func appendWire(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(Data((line + "\n").utf8))
        try handle.close()
    }

    private func stepEndLine(uuid: String, usage: [String: Any], timeMs: Double = 1_780_000_001_000) -> String {
        let json = try! JSONSerialization.data(withJSONObject: [
            "type": "context.append_loop_event",
            "event": ["type": "step.end", "uuid": uuid, "turnId": "0", "step": 1, "usage": usage],
            "time": timeMs,
        ])
        return String(decoding: json, as: UTF8.self)
    }

    private func statusUpdateLine(messageId: String, usage: [String: Any], timestamp: Double = 1_775_833_108) -> String {
        let json = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp,
            "message": ["type": "StatusUpdate", "payload": ["message_id": messageId, "token_usage": usage]],
        ])
        return String(decoding: json, as: UTF8.self)
    }

    // MARK: - Kimi Code 回填

    func test_start_backfillsKimiCodeStepEndWithModelFromConfigUpdate() throws {
        let file = try writeWire(codeSessionsDir, relative: "wd_a_123/session_x/agents/main", lines: [
            #"{"type":"metadata","protocol_version":"1.0"}"#,
            #"{"type":"config.update","modelAlias":"kimi-code/kimi-k2.6","time":1780000000000}"#,
            stepEndLine(uuid: "se1", usage: ["input_tokens": 9000, "output_tokens": 250, "cache_read_input_tokens": 8000, "cache_creation_input_tokens": 100]),
            stepEndLine(uuid: "se2", usage: ["input_tokens": 2000, "output_tokens": 80], timeMs: 1_780_000_002_000),
        ])
        collector.start()
        XCTAssertEqual(collector.scanCount, 0, "start 立即返回，回填后台执行")
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 && self.backfillStates.count == 2 }

        XCTAssertEqual(backfillStates, [true, false])
        let bucket = try XCTUnwrap(store.bucketsByKey.first { $0.value.key.provider == .kimi }?.value)
        XCTAssertEqual(bucket.key.model, "kimi-k2.6", "config.update 前缀剥离")
        XCTAssertEqual(bucket.usage.inputTokens, 11_000)
        XCTAssertEqual(bucket.usage.cachedInputTokens, 8_000)
        XCTAssertEqual(bucket.usage.cacheCreationInputTokens, 100)
        XCTAssertEqual(bucket.usage.outputTokens, 330)
        XCTAssertEqual(bucket.usage.totalTokens, 11_000 + 330 + 8_000 + 100)
        XCTAssertEqual(store.seenKeys.count, 2, "step.end 消息级去重")
        XCTAssertEqual(watcher.watchedURL, codeSessionsDir)
        XCTAssertEqual(scheduler.lastInterval, KimiUsageCollector.defaultScanInterval)
        let stored = store.cursors[file.standardizedFileURL.path]
        XCTAssertEqual(stored?.model, "kimi-k2.6", "模型持久化到游标（增量续读时 model 归属）")
    }

    func test_incrementalResume_usesPersistedModel() throws {
        let file = try writeWire(codeSessionsDir, relative: "wd_z_999/session_r/agents/main", lines: [
            #"{"type":"metadata","protocol_version":"1.0"}"#,
            #"{"type":"config.update","modelAlias":"kimi-code/kimi-k2.6","time":1780000000000}"#,
            stepEndLine(uuid: "r1", usage: ["input_tokens": 100, "output_tokens": 50], timeMs: 1_780_000_000_500),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 150)

        // 追加 step.end，增量续读只读新尾部；config.update 在消费偏移之下 → 用游标中的 model。
        try appendWire(
            stepEndLine(uuid: "r2", usage: ["input_tokens": 200, "output_tokens": 30], timeMs: 1_780_000_002_000),
            to: file
        )
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(store.totalTokens(), 380, "增量续读 150 + 230")
        let kimiBucket = store.bucketsByKey.first { $0.value.key.provider == .kimi }?.value
        XCTAssertEqual(kimiBucket?.key.model, "kimi-k2.6", "r2 沿用游标持久化模型")
        XCTAssertEqual(store.seenKeys.count, 2, "增量去重")
    }

    func test_duplicateStepEndUuids_countedOnce() throws {
        let usage: [String: Any] = ["input_tokens": 123, "output_tokens": 45]
        let line = stepEndLine(uuid: "dup-1", usage: usage)
        try writeWire(codeSessionsDir, relative: "wd_x_1/session_1/agents/main", lines: [
            #"{"type":"config.update","modelAlias":"kimi-k2.6"}"#,
            line,
            line,
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 168, "同 uuid 只计一次")
        XCTAssertEqual(store.seenKeys.count, 1)
    }

    func test_camelCaseUsage_kimiCode06() throws {
        try writeWire(codeSessionsDir, relative: "wd_p_1/session_2/agents/main", lines: [
            #"{"type":"config.update","modelAlias":"kimi-code/kimi-k2.6","time":1780000000000}"#,
            stepEndLine(uuid: "ce1", usage: ["inputOther": 1500, "inputCacheRead": 8000, "inputCacheCreation": 100, "output": 250]),
            #"{"type":"usage.record","model":"kimi-code/kimi-k2.6","usage":{"inputOther":1500,"inputCacheRead":8000,"inputCacheCreation":100,"output":250},"usageScope":"session","time":1780000001000}"#,
            stepEndLine(uuid: "ce2", usage: ["inputOther": 2000, "output": 80], timeMs: 1_780_000_002_000),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        let bucket = store.bucketsByKey.first { $0.value.key.provider == .kimi }?.value
        XCTAssertEqual(bucket?.usage.inputTokens, 3_500, "inputOther 已是纯输入；usage.record 不重复计费")
        XCTAssertEqual(bucket?.usage.cachedInputTokens, 8_000)
        XCTAssertEqual(bucket?.usage.cacheCreationInputTokens, 100)
        XCTAssertEqual(bucket?.usage.outputTokens, 330)
        XCTAssertEqual(store.totalTokens(), 3_500 + 330 + 8_000 + 100)
        XCTAssertEqual(store.seenKeys.count, 2, "usage.record 不计")
    }

    // MARK: - 旧版 StatusUpdate

    func test_legacyStatusUpdate_countedOnceWithDedup() throws {
        let usage: [String: Any] = [
            "input_other": 14_218, "output": 123, "input_cache_read": 6_144, "input_cache_creation": 0,
        ]
        try writeWire(legacySessionsDir, relative: "ws1/sess1", lines: [
            #"{"type":"metadata","protocol_version":"1.5"}"#,
            statusUpdateLine(messageId: "chatcmpl-TEST1", usage: usage),
            statusUpdateLine(messageId: "chatcmpl-TEST1", usage: usage),
            statusUpdateLine(messageId: "chatcmpl-TEST2", usage: ["input_other": 553, "output": 357, "input_cache_read": 20_224]),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 14_218 + 123 + 6_144 + 553 + 357 + 20_224, "重复 TEST1 跳过")
        XCTAssertEqual(store.seenKeys.count, 2)
        let bucket = store.bucketsByKey.first { $0.value.key.provider == .kimi }?.value
        XCTAssertEqual(bucket?.key.model, KimiUsageProcessing.defaultModel, "旧版无模型信息 → unknown")
    }

    // MARK: - 生命周期 / 保护

    func test_start_inUnitTestProcess_doesNotScanRealUserDirectory() throws {
        let realCollector = KimiUsageCollector(store: store)
        realCollector.start()
        realCollector.waitForIdle()
        XCTAssertEqual(realCollector.scanCount, 0, "测试进程下默认目录采集器不启动扫描")
        XCTAssertNil(store.cursors.first)
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
