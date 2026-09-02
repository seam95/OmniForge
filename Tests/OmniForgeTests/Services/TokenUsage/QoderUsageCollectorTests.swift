import Foundation
import GRDB
import XCTest
@testable import OmniForge

/// qoder 用量采集器：JOIN 读取、请求级会话归属、整行「减旧加新」。
final class QoderUsageCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: QoderUsageCollector!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QoderUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("local.db")
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = QoderUsageCollector(
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

    private func createSchema() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE chat_session (
                    session_id TEXT PRIMARY KEY, preferred_model_info TEXT, project_uri TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE chat_record (request_id TEXT, extra TEXT)
            """)
            try db.execute(sql: """
                CREATE TABLE chat_message (
                    rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT, session_id TEXT, request_id TEXT, role TEXT,
                    token_info TEXT, model_info TEXT, gmt_create INTEGER
                )
            """)
        }
        return queue
    }

    private func insertMessage(
        _ queue: DatabaseQueue,
        id: String,
        request: String,
        prompt: Int,
        cached: Int,
        completion: Int,
        gmtCreateMs: Int64
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chat_message (id, session_id, request_id, role, token_info, model_info, gmt_create)
                VALUES (?, ?, ?, 'assistant', ?, ?, ?)
                """,
                arguments: [
                    id, "s1", request,
                    #"{"prompt_tokens":\#(prompt),"cached_tokens":\#(cached),"completion_tokens":\#(completion)}"#,
                    #"{"model_key":"glm-4.6"}"#,
                    gmtCreateMs,
                ]
            )
        }
    }

    // MARK: - 基本读取与请求级会话

    func test_scan_countsWithRequestOwnedConversation() throws {
        let queue = try createSchema()
        try insertMessage(queue, id: "m1", request: "r1", prompt: 1000, cached: 200, completion: 300, gmtCreateMs: 1_784_502_000_000)
        try insertMessage(queue, id: "m2", request: "r1", prompt: 500, cached: 100, completion: 50, gmtCreateMs: 1_784_502_300_000)

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .qoder }
        XCTAssertEqual(buckets.count, 1, "同一半小时桶")
        XCTAssertEqual(buckets.first?.value.usage.totalTokens, 1100 + 450, "缓存不计入总量")
        XCTAssertEqual(buckets.first?.value.conversationCount, 1, "同 request 只计 1 会话")
        XCTAssertEqual(buckets.first?.key.model, "glm-4.6")
    }

    // MARK: - 整行减旧加新

    func test_scan_rowChangeRetractsOldAndAddsNewBucket() throws {
        let queue = try createSchema()
        try insertMessage(queue, id: "m1", request: "r1", prompt: 1000, cached: 200, completion: 300, gmtCreateMs: 1_784_502_000_000)
        try insertMessage(queue, id: "m2", request: "r1", prompt: 500, cached: 100, completion: 50, gmtCreateMs: 1_784_502_300_000)

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 1550)

        // m1 变化：token_info 增长 + gmt_create 移到下一个半小时桶。
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE chat_message SET token_info = ?, gmt_create = ? WHERE id = 'm1'
                """,
                arguments: [#"{"prompt_tokens":2000,"cached_tokens":200,"completion_tokens":300}"#, 1_784_503_800_000]
            )
        }

        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        // 减旧加新：旧桶（A）只剩 m2 的 550；新桶（B）为 m1 的 2300。
        // 归属重算：m1 时间后移后 m2 成为 request 拥有者 → 会话计数随 m2 留在 A。
        let buckets = store.bucketsByKey.filter { $0.key.provider == .qoder }
        XCTAssertEqual(buckets.count, 2)
        let bucketA = buckets.first { $0.key.bucketStart.timeIntervalSince1970 == 1_784_502_000 }
        let bucketB = buckets.first { $0.key.bucketStart.timeIntervalSince1970 == 1_784_503_800 }
        XCTAssertEqual(bucketA?.value.usage.totalTokens, 450, "旧桶减旧后只剩 m2")
        XCTAssertEqual(bucketB?.value.usage.totalTokens, 2100, "新桶加新")
        XCTAssertEqual(store.totalTokens(), 2550)
        XCTAssertEqual(bucketA?.value.conversationCount, 1, "归属重算后 m2 拥有会话计数")
        XCTAssertEqual(bucketB?.value.conversationCount, 0)
    }

    // MARK: - DB 缺失

    func test_scan_missingDbSilentlySkips() throws {
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertTrue(store.bucketsByKey.isEmpty)
    }
}