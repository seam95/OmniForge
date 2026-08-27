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

    // MARK: - v2 schema（opencode2 重写存储层）

    /// v2 行：角色在 type 列（data 无 role），模型为嵌套对象 {id, providerID}。
    private func v2MessageData(
        modelID: String = "glm-5.3",
        providerID: String = "zcode",
        createdMs: Double,
        completedMs: Double,
        input: Int,
        output: Int
    ) -> String {
        let dict: [String: Any] = [
            "model": ["id": modelID, "providerID": providerID],
            "time": ["created": createdMs, "completed": completedMs],
            "tokens": ["input": input, "output": output],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    @discardableResult
    private func createV2Db(rows: [MessageRow]) throws -> URL {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session_message (
                    id TEXT NOT NULL, session_id TEXT NOT NULL, type TEXT,
                    time_created INTEGER, time_updated INTEGER, data TEXT
                )
            """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO session_message (id, session_id, type, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [row.id, row.session, "assistant", 1_784_500_000, 1_784_500_000, row.data]
                )
            }
        }
        return databaseURL
    }

    func test_scan_v2Schema_readsSessionMessageTable() throws {
        try createV2Db(rows: [
            MessageRow(id: "m1", session: "s1", data: v2MessageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)),
        ])
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .opencode }
        XCTAssertEqual(buckets.count, 1, "v2 库正常采集，不再静默变空")
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 120)
        XCTAssertEqual(buckets.first?.key.model, "glm-5.3", "模型名取自嵌套 model.id")
    }

    func test_scan_pureV1_emptySessionMessageTable_stillReadsV1() throws {
        // session_message 表在纯 v1 库也存在但为空：按行存在性判定，仍走 v1。
        try createDb(rows: [
            MessageRow(id: "m1", session: "s1", data: messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)),
        ])
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session_message (
                    id TEXT NOT NULL, session_id TEXT NOT NULL, type TEXT,
                    time_created INTEGER, time_updated INTEGER, data TEXT
                )
            """)
        }
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120, "空 session_message 不影响 v1 读取")
    }

    func test_scan_mixedSchema_sameKeyAcrossTables_noDoubleCounting() throws {
        // 升级期混合库：同 key 消息同时存在于 v1/v2 两表，totals 相同 → 差分 0。
        let shared = messageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)
        let v2Shared = v2MessageData(createdMs: 1_784_502_000_000, completedMs: 1_784_502_000_000, input: 100, output: 20)
        try createDb(rows: [MessageRow(id: "m1", session: "s1", data: shared)])
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session_message (
                    id TEXT NOT NULL, session_id TEXT NOT NULL, type TEXT,
                    time_created INTEGER, time_updated INTEGER, data TEXT
                )
            """)
            try db.execute(
                sql: "INSERT INTO session_message (id, session_id, type, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["m1", "s1", "assistant", 1_784_500_000, 1_784_500_000, v2Shared]
            )
        }
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120, "同 key 跨表重放不重复计数")
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