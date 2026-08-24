import Foundation
import XCTest
@testable import OmniForge

/// CodeBuddy 用量采集器：rawUsage 减法、往返级 messageId 去重、增量扫描、settings 默认模型。
final class CodebuddyUsageCollectorTests: XCTestCase {
    private var projectsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: CodebuddyUsageCollector!

    override func setUpWithError() throws {
        projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodebuddyUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = CodebuddyUsageCollector(
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

    /// 构造带 providerData.rawUsage 的 transcript 行（JSONSerialization 生成，避免手写括号错误）。
    private func rawLine(
        messageId: String,
        id: String? = nil,
        sessionId: String? = "s1",
        model: String = "deepseek-v4",
        prompt: Int,
        completion: Int,
        cached: Int = 0,
        cacheCreation: Int = 0,
        reasoning: Int = 0,
        timestampMs: Double = 1_784_502_000_000
    ) -> String {
        var line: [String: Any] = [
            "type": "assistant",
            "uuid": "u-\(messageId)",
            "timestamp": timestampMs,
            "model": model,
            "providerData": [
                "messageId": messageId,
                "model": model,
                "rawUsage": [
                    "prompt_tokens": prompt,
                    "completion_tokens": completion,
                    "prompt_tokens_details": ["cached_tokens": cached],
                    "completion_tokens_details": ["reasoning_tokens": reasoning],
                    "cache_creation_input_tokens": cacheCreation,
                ],
            ],
        ]
        if let sessionId {
            line["sessionId"] = sessionId
        }
        if let id {
            line["id"] = id
        }
        let data = try! JSONSerialization.data(withJSONObject: line, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func writeSession(_ name: String, lines: [String]) throws -> URL {
        let url = projectsDir.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    // MARK: - 基本扫描

    func test_scan_countsRawUsageWithSubtraction() throws {
        try writeSession("sess-a.jsonl", lines: [
            rawLine(messageId: "m1", prompt: 1000, completion: 300, cached: 200, cacheCreation: 50, reasoning: 30),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .codebuddy }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.value.usage.inputTokens, 750)
        XCTAssertEqual(buckets.first?.value.usage.cachedInputTokens, 200)
        XCTAssertEqual(buckets.first?.value.usage.outputTokens, 270)
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 750 + 200 + 50 + 270 + 30)
        XCTAssertEqual(buckets.first?.value.conversationCount, 1)
        XCTAssertEqual(buckets.first?.key.model, "deepseek-v4")
    }

    func test_scan_dedupesByMessageIdAcrossRecordTypes() throws {
        // 同一往返的 function_call 与 assistant 记录共享 messageId → 只计一次。
        let functionCall = rawLine(messageId: "round-1", id: "rec-1", prompt: 500, completion: 100)
            .replacingOccurrences(of: "\"type\":\"assistant\"", with: "\"type\":\"function_call\"")
        let assistant = rawLine(messageId: "round-1", id: "rec-2", prompt: 500, completion: 100)
        try writeSession("sess-a.jsonl", lines: [functionCall, assistant])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 600, "同往返两次记录只计一次")
    }

    func test_scan_skipsLinesWithoutRawUsage() throws {
        try writeSession("sess-a.jsonl", lines: [
            "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}",
            "{broken json",
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 0)
    }

    // MARK: - 增量与去重

    func test_incrementalAppend_countsOnlyNewRounds() throws {
        let file = try writeSession("sess-a.jsonl", lines: [
            rawLine(messageId: "m1", prompt: 100, completion: 10),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 110)

        try append(file, lines: [rawLine(messageId: "m2", prompt: 30, completion: 5)])
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 145)
    }

    func test_cursorLoss_rescanDoesNotDoubleCount() throws {
        try writeSession("sess-a.jsonl", lines: [
            rawLine(messageId: "m1", prompt: 100, completion: 10),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 110)

        store.cursors.removeAll()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 110, "messageId 去重，游标丢失重读不重复计数")
    }

    private func append(_ file: URL, lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }
}