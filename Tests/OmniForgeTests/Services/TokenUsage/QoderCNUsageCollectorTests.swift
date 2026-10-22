import Foundation
import XCTest
@testable import OmniForge

/// Qoder CN 采集器：Claude 兼容 JSONL 扫描、消息级去重、子代理 token 计入与会话不重复、
/// 增量续读、游标丢失幂等、默认目录 env 覆盖。
final class QoderCNUsageCollectorTests: XCTestCase {
    private var projectsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: QoderCNUsageCollector!

    override func setUpWithError() throws {
        projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QoderCNUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = QoderCNUsageCollector(
            store: store,
            projectsDirectory: projectsDir,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: projectsDir)
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

    // MARK: - 样本行

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func assistantLine(
        messageId: String?,
        requestId: String? = nil,
        sessionId: String = "sess-1",
        model: String = "qwen3-coder-plus",
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        timestamp: String = "2026-09-23T06:06:19.706Z"
    ) -> String {
        var message: [String: Any] = [
            "model": model,
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": cacheRead,
                "cache_creation_input_tokens": cacheCreation,
            ],
        ]
        if let messageId {
            message["id"] = messageId
        }
        var line: [String: Any] = [
            "type": "assistant",
            "sessionId": sessionId,
            "uuid": "u-\(messageId ?? requestId ?? UUID().uuidString)",
            "timestamp": timestamp,
            "message": message,
        ]
        if let requestId {
            line["requestId"] = requestId
        }
        return jsonString(line)
    }

    private func userLine(
        uuid: String,
        sessionId: String = "sess-1",
        hasText: Bool = true,
        timestamp: String = "2026-09-23T06:05:00.000Z"
    ) -> String {
        let blockType = hasText ? "text" : "tool_result"
        return jsonString([
            "type": "user",
            "sessionId": sessionId,
            "uuid": uuid,
            "timestamp": timestamp,
            "message": ["content": [["type": blockType, "text": "synthetic"]]],
        ])
    }

    @discardableResult
    private func writeFile(relativePath: String, lines: [String]) throws -> URL {
        let url = projectsDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func append(_ file: URL, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    // MARK: - 基本扫描

    func test_scan_countsAssistantUsageAndUserConversation() throws {
        try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            userLine(uuid: "u-1"),
            assistantLine(messageId: "m1", input: 100, output: 50, cacheRead: 200, cacheCreation: 30),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .qoderCN }
        XCTAssertEqual(store.totalTokens(), 150, "缓存读写不计入总量")
        XCTAssertEqual(store.conversations(), 1, "user 文本行计 1 会话")
        let usageBreakdown = buckets.reduce(TokenUsage.zero) { $0.adding($1.value.usage) }
        XCTAssertEqual(usageBreakdown.inputTokens, 100)
        XCTAssertEqual(usageBreakdown.outputTokens, 50)
        XCTAssertEqual(usageBreakdown.cachedInputTokens, 200)
        XCTAssertEqual(usageBreakdown.cacheCreationInputTokens, 30)
        XCTAssertTrue(buckets.contains { $0.key.model == "qwen3-coder-plus" })
    }

    func test_scan_dedupesByMessageId() throws {
        // 同一 assistant 消息被重复写入（流式补写/重试）→ 只计一次。
        try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            assistantLine(messageId: "m1", input: 100, output: 50),
            assistantLine(messageId: "m1", input: 100, output: 50),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 150)
    }

    func test_scan_dedupesByRequestIdWhenMessageIdMissing() throws {
        try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            assistantLine(messageId: nil, requestId: "req-1", input: 40, output: 10),
            assistantLine(messageId: nil, requestId: "req-1", input: 40, output: 10),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 50)
    }

    func test_scan_subagentUsageCountedWithoutExtraConversation() throws {
        try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            userLine(uuid: "u-1"),
            assistantLine(messageId: "m1", input: 100, output: 50),
        ])
        try writeFile(relativePath: "enc/sess-1/subagents/agent-1.jsonl", lines: [
            userLine(uuid: "u-agent", hasText: true),
            assistantLine(messageId: "m-agent", input: 40, output: 10),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 200, "子代理 token 计入")
        XCTAssertEqual(store.conversations(), 1, "子代理 user 行不计会话")
    }

    func test_scan_ignoresMalformedAndUsageLessLines() throws {
        try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            "{broken json",
            userLine(uuid: "u-1", hasText: false),
            assistantLine(messageId: "m-empty", input: 0, output: 0),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 0)
        XCTAssertEqual(store.conversations(), 0)
    }

    // MARK: - 增量与幂等

    func test_incrementalAppend_countsOnlyNewRounds() throws {
        let file = try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            assistantLine(messageId: "m1", input: 100, output: 50),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 150)

        try append(file, lines: [assistantLine(messageId: "m2", input: 30, output: 5)])
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 185)
    }

    func test_cursorLoss_rescanDoesNotDoubleCount() throws {
        try writeFile(relativePath: "enc/sess-1.jsonl", lines: [
            userLine(uuid: "u-1"),
            assistantLine(messageId: "m1", input: 100, output: 50),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 150)
        XCTAssertEqual(store.conversations(), 1)

        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 150, "消息 id 去重，重读不重复计数")
        XCTAssertEqual(store.conversations(), 1, "user uuid 去重")
    }

    // MARK: - 默认目录

    func test_defaultProjectsDirectory_envOverride() {
        XCTAssertEqual(
            QoderCNUsageCollector.defaultProjectsDirectory(
                homePath: "/Users/tester",
                environment: [:]
            ).path,
            "/Users/tester/.qoder-cn/projects"
        )
        XCTAssertEqual(
            QoderCNUsageCollector.defaultProjectsDirectory(
                homePath: "/Users/tester",
                environment: ["QODERCN_CONFIG_DIR": "/tmp/qoder-config"]
            ).path,
            "/tmp/qoder-config/projects",
            "QODERCN_CONFIG_DIR 覆盖 projects 父目录"
        )
    }

    func test_usesRealDirectories_onlyForDefaultPath() {
        XCTAssertFalse(collector.usesRealDirectories, "临时构造目录不触发真实扫描守卫")
        let real = QoderCNUsageCollector(store: store, scheduler: scheduler, watcher: watcher)
        XCTAssertTrue(real.usesRealDirectories)
    }
}
