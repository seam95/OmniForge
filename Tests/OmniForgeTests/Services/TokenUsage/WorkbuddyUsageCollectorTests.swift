import Foundation
import XCTest
@testable import OmniForge

/// WorkBuddy 用量采集器：JSONL rawUsage 主路径、trace 无损兜底、双来源互斥（不叠加）。
final class WorkbuddyUsageCollectorTests: XCTestCase {
    private var homeDir: URL!
    private var projectsDir: URL!
    private var tracesDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: WorkbuddyUsageCollector!

    override func setUpWithError() throws {
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbuddyUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        projectsDir = homeDir.appendingPathComponent("projects", isDirectory: true)
        tracesDir = homeDir.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = WorkbuddyUsageCollector(
            store: store,
            homeDirectory: homeDir,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: homeDir)
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

    private func rawLine(
        messageId: String,
        sessionId: String = "s1",
        prompt: Int,
        completion: Int,
        cached: Int = 0,
        timestampMs: Double = 1_784_502_000_000
    ) -> String {
        let line: [String: Any] = [
            "type": "assistant",
            "sessionId": sessionId,
            "uuid": "u-\(messageId)",
            "id": "a-\(messageId)",
            "timestamp": timestampMs,
            "model": "deepseek-v4",
            "providerData": [
                "messageId": messageId,
                "requestModelId": "deepseek-v4-flash",
                "rawUsage": [
                    "prompt_tokens": prompt,
                    "completion_tokens": completion,
                    "prompt_tokens_details": ["cached_tokens": cached],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: line, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func writeProject(_ name: String, lines: [String]) throws -> URL {
        let url = projectsDir.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func writeTrace(_ name: String, sessionId: String, totalInput: Int, totalOutput: Int, totalCached: Int = 0) throws -> URL {
        try FileManager.default.createDirectory(at: tracesDir, withIntermediateDirectories: true)
        let url = tracesDir.appendingPathComponent(name)
        let json = """
        {"trace":{"traceId":"\(name)","sessionId":"\(sessionId)","startedAt":1784502000000,\
        "modelInfo":{"totalInputTokens":\(totalInput),"totalOutputTokens":\(totalOutput),\
        "totalCachedTokens":\(totalCached),"models":["deepseek-v4"]}}}
        """
        try Data(json.utf8).write(to: url)
        return url
    }

    // MARK: - JSONL 主路径

    func test_scan_countsRawUsage_prefersRequestModelId() throws {
        try writeProject("sess-a.jsonl", lines: [rawLine(messageId: "m1", prompt: 100, completion: 10, cached: 20)])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .workbuddy }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.value.usage.inputTokens, 80, "100 - cached 20")
        XCTAssertEqual(buckets.first?.value.usage.cachedInputTokens, 20)
        XCTAssertEqual(buckets.first?.key.model, "deepseek-v4-flash", "模型链 requestModelId 胜出")
    }

    func test_incrementalAppend_countsOnlyNewRounds() throws {
        let file = try writeProject("sess-a.jsonl", lines: [rawLine(messageId: "m1", prompt: 100, completion: 10)])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 110)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(Data((rawLine(messageId: "m2", prompt: 30, completion: 5) + "\n").utf8))
        try handle.close()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 145)
    }

    // MARK: - trace 兜底

    func test_traceFallback_countsWhenNoJsonlUsage() throws {
        // 无 JSONL（或有但无 rawUsage）→ trace 一次性估算。
        try writeProject("sess-b.jsonl", lines: ["{\"type\":\"user\",\"message\":{}}" ])
        try writeTrace("trace_1.json", sessionId: "sess-b", totalInput: 1000, totalOutput: 200, totalCached: 300)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .workbuddy }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.value.usage.inputTokens, 700)
        XCTAssertEqual(buckets.first?.value.usage.cachedInputTokens, 300)
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 900, "缓存不计入总量")
        XCTAssertEqual(buckets.first?.value.conversationCount, 1)
    }

    func test_jsonlSuppressesTraceForSameSession() throws {
        try writeProject("sess-a.jsonl", lines: [rawLine(messageId: "m1", sessionId: "sess-a", prompt: 100, completion: 10)])
        try writeTrace("trace_1.json", sessionId: "sess-a", totalInput: 900, totalOutput: 90)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 110, "JSONL 权威，trace 不叠加")
    }

    func test_trace_rescanDoesNotDoubleCount() throws {
        try writeTrace("trace_1.json", sessionId: "sess-b", totalInput: 500, totalOutput: 50)
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 550)

        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 550, "traceId 幂等")
    }
}