import Foundation
import GRDB
import XCTest
@testable import OmniForge

/// zcode 用量采集器：providerID 黑名单过滤（子代理剔除、自定义 provider 保留）。
final class ZcodeUsageCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: ZcodeUsageCollector!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcodeUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("db.sqlite")
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = ZcodeUsageCollector(
            store: store,
            databaseURL: databaseURL,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: tempDir)
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

    private func createDb(providerIDs: [String]) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE message (
                    id TEXT NOT NULL, session_id TEXT NOT NULL,
                    time_created INTEGER, time_updated INTEGER, data TEXT
                )
            """)
            for (index, providerID) in providerIDs.enumerated() {
                let dict: [String: Any] = [
                    "role": "assistant",
                    "modelID": "glm-4.6",
                    "providerID": providerID,
                    "time": ["created": 1_784_502_000_000 + Double(index) * 1000, "completed": 1_784_502_000_000 + Double(index) * 1000],
                    "tokens": ["input": 100, "output": 10, "reasoning": 0, "cache": ["read": 0, "write": 0]],
                ]
                let data = String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
                try db.execute(
                    sql: "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["m\(index)", "s1", 1_784_500_000, 1_784_500_000, data]
                )
            }
        }
    }

    /// 新 schema 行（2026-09-14 起）：仅 `modelId`，无 providerID / modelID / model。
    private func createDb(modelIds: [String]) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE message (
                    id TEXT NOT NULL, session_id TEXT NOT NULL,
                    time_created INTEGER, time_updated INTEGER, data TEXT
                )
            """)
            for (index, modelId) in modelIds.enumerated() {
                let dict: [String: Any] = [
                    "role": "assistant",
                    "modelId": modelId,
                    "time": ["created": 1_784_502_000_000 + Double(index) * 1000, "completed": 1_784_502_000_000 + Double(index) * 1000],
                    "tokens": ["input": 100, "output": 10, "reasoning": 0, "cache": ["read": 0, "write": 0]],
                ]
                let data = String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
                try db.execute(
                    sql: "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["m\(index)", "s1", 1_784_500_000, 1_784_500_000, data]
                )
            }
        }
    }

    func test_scan_blacklistsSubagentProviders() throws {
        // anthropic/openai/google 子代理由 Claude/Codex/Gemini 独立采集 → 剔除；
        // Z.ai 计划 provider 与自定义 UUID provider 保留。
        try createDb(providerIDs: [
            "builtin:zai-start-plan",
            "265956bf-8f2a-4b61-9c9a-aa5c7d0c3d11",
            "anthropic",
            "openai",
            "google",
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .zcode }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.value.conversationCount, 2, "仅两条原生消息计数")
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 220)
    }

    func test_scan_newSchemaWithoutProvider_keepsNativeAndFiltersSubagentByModelPrefix() throws {
        // 2026-09-14 起 fork 只落 modelId、provider 字段缺失：原生模型照常采集并
        // 以真实模型名归桶；子代理模型（claude/gpt 系）按前缀剔除，防重复计数。
        try createDb(modelIds: [
            "GLM-5.3",
            "deepseek-flash",
            "k3-256k",
            "gpt-5.2",
            "claude-sonnet-4.5",
            "gemini-2.5-pro",
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .zcode }
        XCTAssertEqual(buckets.count, 3, "三个原生模型各成一桶，子代理模型零桶")
        let models = Set(buckets.map(\.key.model))
        XCTAssertEqual(models, ["GLM-5.3", "deepseek-flash", "k3-256k"])
        for bucket in buckets.values {
            XCTAssertEqual(bucket.usage.totalTokens, 110, "每模型一条消息 100+10")
        }
        XCTAssertFalse(models.contains("unknown"), "原生消息不得因 provider 缺失落入 unknown")
    }
}