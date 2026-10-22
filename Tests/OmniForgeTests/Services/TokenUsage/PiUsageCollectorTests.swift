import Foundation
import XCTest
@testable import OmniForge

/// Pi 采集器：session 头 + model_change + assistant usage 回填、模型持久化、
/// 模型切换、消息去重、坏行跳过、会话计数与测试进程守卫。
final class PiUsageCollectorTests: XCTestCase {
    private var root: URL!
    private var sessionsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: PiUsageCollector!
    private var backfillStates: [Bool] = []

    private let sessionID = "01a161a6-d655-7217-90e9-911de238f142"
    private let fileName = "2026-10-22T03-28-06-230Z_01a161a6-d655-7217-90e9-911de238f142.jsonl"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = PiUsageCollector(
            store: store,
            sessionsDirectory: sessionsDir,
            scheduler: scheduler,
            watcher: watcher
        )
        backfillStates = []
        collector.onBackfillStateChange = { [weak self] value in
            self?.backfillStates.append(value)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 回填

    func test_backfill_parsesSessionModelChangeAndUsage() throws {
        let file = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash", provider: "opencode-go"),
            messageLine(role: "user", timestamp: "2026-10-22T03:28:10.000Z"),
            messageLine(
                id: "m1",
                usage: ["input": 1000, "output": 100, "cacheRead": 200, "cacheWrite": 50, "reasoning": 40, "totalTokens": 1350]
            ),
            messageLine(
                id: "m2",
                timestamp: "2026-10-22T03:29:00.000Z",
                usage: ["input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 15]
            ),
        ])

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 && self.backfillStates.count == 2 }

        XCTAssertEqual(backfillStates, [true, false], "首次扫描为回填")
        XCTAssertEqual(store.conversations(), 1, "每个 session 文件只计 1 次会话")
        let bucket = try XCTUnwrap(store.bucketsByKey.first { $0.value.key.provider == .pi }?.value)
        XCTAssertEqual(bucket.key.model, "deepseek-v4.1-flash", "模型取最近 model_change 的 modelId")
        XCTAssertEqual(bucket.usage.inputTokens, 1010)
        XCTAssertEqual(bucket.usage.cachedInputTokens, 200)
        XCTAssertEqual(bucket.usage.cacheCreationInputTokens, 50)
        XCTAssertEqual(bucket.usage.outputTokens, 65, "output 拆掉 reasoning 子集：60 + 5")
        XCTAssertEqual(bucket.usage.reasoningOutputTokens, 40)
        XCTAssertEqual(bucket.usage.totalTokens, 1115, "缓存不计入总量")
        XCTAssertEqual(store.seenKeys.count, 3, "2 条消息 + 1 个会话 marker")

        let cursor = try XCTUnwrap(store.cursors[file.standardizedFileURL.path])
        XCTAssertEqual(cursor.model, "deepseek-v4.1-flash", "模型持久化到游标（增量续读归属）")
        XCTAssertEqual(watcher.watchedURL, sessionsDir)
        XCTAssertEqual(scheduler.lastInterval, JSONLUsageCollectorBase.defaultScanInterval)
    }

    func test_incrementalResume_usesPersistedModelAndCursor() throws {
        let file = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash"),
            messageLine(id: "m1", usage: ["input": 100, "output": 10]),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 110)
        XCTAssertEqual(store.cursors[file.standardizedFileURL.path]?.model, "deepseek-v4.1-flash")

        // 追加新 assistant 用量：model_change 在消费偏移之下，靠游标里的模型归属。
        try append(
            messageLine(
                id: "m2",
                timestamp: "2026-10-22T03:29:30.000Z",
                usage: ["input": 200, "output": 20]
            ),
            to: file
        )
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(store.totalTokens(), 330, "增量续读 110 + 220")
        let piBuckets = store.bucketsByKey.values.filter { $0.key.provider == .pi }
        XCTAssertEqual(piBuckets.count, 1)
        XCTAssertEqual(piBuckets.first?.key.model, "deepseek-v4.1-flash", "沿用游标持久化模型")
        XCTAssertEqual(store.conversations(), 1, "增量续读不重复计会话")
        XCTAssertEqual(store.seenKeys.count, 3)
    }

    func test_modelChangeSwitch_attributesEachMessageToItsModel() throws {
        _ = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash"),
            messageLine(id: "m1", usage: ["input": 100, "output": 10]),
            modelChangeLine(model: "claude-opus-5", provider: "anthropic", timestamp: "2026-10-22T03:29:00.000Z"),
            messageLine(
                id: "m2",
                timestamp: "2026-10-22T03:30:00.000Z",
                usage: ["input": 200, "output": 20]
            ),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let byModel = Dictionary(uniqueKeysWithValues: store.bucketsByKey.values.map { ($0.key.model, $0.usage.totalTokens) })
        XCTAssertEqual(byModel["deepseek-v4.1-flash"], 110)
        XCTAssertEqual(byModel["claude-opus-5"], 220)
        XCTAssertEqual(store.conversations(), 1)
    }

    func test_duplicateMessageID_countedOnce() throws {
        let line = messageLine(id: "dup-1", usage: ["input": 100, "output": 10]);
        _ = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash"),
            line,
            line,
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 110, "同 message.id 只计一次")
        XCTAssertEqual(store.conversations(), 1)
        XCTAssertEqual(store.seenKeys.count, 2)
    }

    // MARK: - 健壮性

    func test_badLinesAndNonAssistantMessagesAreSkipped() throws {
        _ = try writeSession(project: "--tmp-proj--", lines: [
            "not json",
            "",
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash"),
            messageLine(role: "user", usage: ["input": 999, "output": 999]),
            messageLine(id: "no-usage", role: "assistant"),
            messageLine(
                id: "bad-ts",
                timestamp: "not-a-timestamp",
                usage: ["input": 888, "output": 888]
            ),
            messageLine(id: "ok", usage: ["input": 100, "output": 10]),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 110, "坏行/非 assistant/无用量/坏时间戳全部跳过")
        XCTAssertEqual(store.conversations(), 1)
    }

    func test_messageWithoutID_usesRowNumberFallbackKey() throws {
        _ = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            messageLine(id: nil, usage: ["input": 7, "output": 3]),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 10)
        XCTAssertTrue(
            store.seenKeys.contains { $0.hasPrefix("pi:\(self.sessionID):line:") },
            "无 message.id 用行号兜底去重"
        )
    }

    func test_noModelChange_fallsBackToMessageModelAndPersistsIt() throws {
        let file = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            messageLine(
                id: "m1",
                usage: ["input": 10, "output": 1],
                model: "gpt-5"
            ),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let bucket = store.bucketsByKey.values.first { $0.key.provider == .pi }
        XCTAssertEqual(bucket?.key.model, "gpt-5", "没有 model_change 时回退消息自带 model")
        XCTAssertEqual(store.cursors[file.standardizedFileURL.path]?.model, "gpt-5", "回退模型同样持久化")
    }

    func test_titleRecordBeforeSession_isIgnored() throws {
        _ = try writeSession(project: "--tmp-proj--", lines: [
            jsonLine(["type": "title", "v": 1, "title": ""]),
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash"),
            messageLine(id: "m1", usage: ["input": 100, "output": 10]),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 110, "session 前的 title 元数据不破坏解析")
        XCTAssertEqual(store.conversations(), 1)
    }

    func test_twoSessionFiles_countTwoConversations() throws {
        _ = try writeSession(project: "--tmp-proj--", lines: [
            sessionLine(id: sessionID),
            modelChangeLine(model: "deepseek-v4.1-flash"),
            messageLine(id: "a1", usage: ["input": 100, "output": 10]),
        ])
        _ = try writeSession(
            project: "--tmp-proj--",
            fileName: "2026-10-22T04-00-00-000Z_01a161b0-0000-7000-0000-000000000000.jsonl",
            lines: [
                sessionLine(id: "01a161b0-0000-7000-0000-000000000000", timestamp: "2026-10-22T04:00:00.000Z"),
                modelChangeLine(model: "deepseek-v4.1-flash"),
                messageLine(
                    id: "b1",
                    timestamp: "2026-10-22T04:00:10.000Z",
                    usage: ["input": 100, "output": 10]
                ),
            ]
        )
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 220)
        XCTAssertEqual(store.conversations(), 2, "两个 session 文件 = 两个会话")
    }

    // MARK: - 生命周期 / 保护

    func test_defaultSessionsDirectory_isPiAgentSessions() {
        XCTAssertTrue(
            PiUsageCollector.defaultSessionsDirectory.path.hasSuffix("/.pi/agent/sessions")
        )
    }

    func test_start_inUnitTestProcess_doesNotScanRealUserDirectory() {
        let realCollector = PiUsageCollector(store: store)
        realCollector.start()
        realCollector.waitForIdle()
        XCTAssertEqual(realCollector.scanCount, 0, "测试进程下默认目录采集器不启动扫描")
        XCTAssertTrue(store.cursors.isEmpty)
        realCollector.stop()
    }

    func test_stop_stopsWatcherAndTimer() {
        collector.start()
        collector.waitForIdle()
        collector.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertNil(watcher.watchedURL)
        XCTAssertEqual(scheduler.activeScheduleCount, 0, "定时器被取消")
    }

    // MARK: - 工具

    private func pumpUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    @discardableResult
    private func writeSession(
        project: String,
        fileName: String? = nil,
        lines: [String]
    ) throws -> URL {
        let directory = sessionsDir.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName ?? self.fileName)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(Data((line + "\n").utf8))
        try handle.close()
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func sessionLine(id: String, timestamp: String = "2026-10-22T03:28:06.230Z") -> String {
        jsonLine([
            "type": "session",
            "version": 3,
            "id": id,
            "timestamp": timestamp,
            "cwd": "/tmp/proj",
        ])
    }

    private func modelChangeLine(
        model: String,
        provider: String? = "opencode-go",
        timestamp: String = "2026-10-22T03:28:06.253Z"
    ) -> String {
        var object: [String: Any] = [
            "type": "model_change",
            "id": UUID().uuidString,
            "timestamp": timestamp,
            "modelId": model,
        ]
        if let provider { object["provider"] = provider }
        return jsonLine(object)
    }

    private func messageLine(
        id: String? = nil,
        role: String = "assistant",
        timestamp: String? = "2026-10-22T03:28:13.641Z",
        usage: [String: Any]? = nil,
        model: String? = nil,
        provider: String? = nil
    ) -> String {
        var message: [String: Any] = ["role": role]
        var object: [String: Any] = ["type": "message"]
        if let id { object["id"] = id }
        if let timestamp { object["timestamp"] = timestamp }
        if let usage { message["usage"] = usage }
        if let model { message["model"] = model }
        if let provider { message["provider"] = provider }
        object["message"] = message
        return jsonLine(object)
    }
}
