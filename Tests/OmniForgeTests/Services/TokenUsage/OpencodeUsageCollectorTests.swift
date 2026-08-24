import Foundation
import GRDB
import XCTest
@testable import OmniForge

/// opencode 用量采集器：累积值差分、fork 复制指纹去重、DB 缺失静默。
final class OpencodeUsageCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: OpencodeUsageCollector!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpencodeUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("opencode.db")
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = OpencodeUsageCollector(
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

    private struct MessageRow {
        var id: String
        var session: String
        var data: String
    }

    private func messageData(
        role: String = "assistant",
        modelID: String = "deepseek-v4",
        providerID: String = "opencode",
        createdMs: Double,
        completedMs: Double,
        input: Int,
        output: Int,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> String {
        let dict: [String: Any] = [
            "role": role,
            "modelID": modelID,
            "providerID": providerID,
            "time": ["created": createdMs, "completed": completedMs],
            "tokens": [
                "input": input, "output": output, "reasoning": reasoning,
                "cache": ["read": cacheRead, "write": cacheWrite],
            ],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    @discardableResult
    private func createDb(rows: [MessageRow]) throws -> URL {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE message (
                    id TEXT NOT NULL, session_id TEXT NOT NULL,
                    time_created INTEGER, time_updated INTEGER, data TEXT
                )
            """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
                    arguments: [row.id, row.session, 1_784_500_000, 1_784_500_000, row.data]
                )
            }
        }
        return databaseURL
    }

    private func updateRow(id: String, data: String) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE message SET data = ?, time_updated = ? WHERE id = ?",
                arguments: [data, 1_784_500_100, id]
            )
        }
    }

    // MARK: - 基本差分

    func test_scan_countsMessages() throws {
        try createDb(rows: [
            MessageRow(id: "m1", session: "s1", data: messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)),
            MessageRow(id: "m2", session: "s1", data: messageData(createdMs: 1_784_502_600_000, completedMs: 1_784_502_600_000, input: 50, output: 10)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .opencode }
        XCTAssertEqual(buckets.count, 1, "同模型同时段聚合到一个桶")
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 180)
        XCTAssertEqual(buckets.first?.value.conversationCount, 2)
        XCTAssertEqual(buckets.first?.key.model, "deepseek-v4")
    }

    func test_scan_cumulativeGrowthAddsOnlyDelta() throws {
        try createDb(rows: [
            MessageRow(id: "m1", session: "s1", data: messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120)

        // 消息流式增长：同消息累积值 100→150（20 输出不变）。
        try updateRow(id: "m1", data: messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 150, output: 20))
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 170, "只加增量 50")
    }

    func test_scan_unchangedNoNewDelta() throws {
        try createDb(rows: [
            MessageRow(id: "m1", session: "s1", data: messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120)

        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 120, "数据不变不重复计数")
    }

    // MARK: - fork 复制去重

    func test_scan_forkCopyCountedOnce() throws {
        let base = messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_600_000, input: 100, output: 20)
        try createDb(rows: [
            MessageRow(id: "orig", session: "s1", data: base),
            // fork 复制：只改 id/session，其余字段（time/model/tokens/provider）原样。
            MessageRow(id: "copy", session: "s2", data: base),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120, "fork 复制跨会话去重，只计一次")
    }

    // MARK: - DB 缺失

    func test_scan_missingDbSilentlySkips() throws {
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 0)
        XCTAssertTrue(store.bucketsByKey.isEmpty)
    }
}