import GRDB
import XCTest
@testable import OmniForge

/// 断言异步表达式抛出错误。XCTest 没有 async 版 `XCTAssertThrowsError`，这里补一个本文件专用辅助。
private func assertThrowsAsync<T>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> T,
    check: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("预期抛出错误，但调用成功", file: file, line: line)
    } catch {
        check(error)
    }
}

/// 翻译历史存储定向测试：容量裁剪、重开持久化、事务回滚、取消不落库、删除失败可见与稳定排序。
final class GRDBTranslationHistoryStoreTests: XCTestCase {
    private var rootDirectory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBTranslationHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = rootDirectory.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - 辅助

    private func makeStore() -> GRDBTranslationHistoryStore {
        GRDBTranslationHistoryStore(databaseURL: databaseURL)
    }

    private func makeEntry(
        index: Int,
        completedAt: Date,
        id: UUID = UUID()
    ) -> TranslationHistoryEntry {
        let request = TranslationRequest(
            id: id,
            text: "原文 \(index)",
            sourceLanguage: "en",
            targetLanguage: "zh-Hans"
        )
        let result = TranslationResult(
            text: "译文 \(index)",
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            engine: .ai,
            model: "test-model"
        )
        return TranslationHistoryEntry(request: request, result: result, completedAt: completedAt)
    }

    private func makeEntry(index: Int) -> TranslationHistoryEntry {
        makeEntry(index: index, completedAt: Date(timeIntervalSince1970: Double(index)))
    }

    /// 在历史表上安装“删除即失败”的触发器，用真实 SQLite 约束制造写入/删除失败，
    /// 不依赖只读目录等易受环境影响的技巧。
    private func installFailingDeleteTrigger() throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failHistoryDelete BEFORE DELETE ON translationHistory
                BEGIN
                    SELECT RAISE(ABORT, 'history delete blocked');
                END
                """)
        }
    }

    // MARK: - 容量裁剪

    func test_insertPrunesToNewest100Atomically() async throws {
        let store = makeStore()
        var entries: [TranslationHistoryEntry] = []
        for index in 0...100 {
            let entry = makeEntry(index: index)
            entries.append(entry)
            try await store.insertAndPrune(entry, limit: 100)
        }

        let loaded = try await store.load(limit: 1_000)
        XCTAssertEqual(loaded.count, 100, "裁剪后应只保留最近 100 条")
        XCTAssertEqual(loaded.first?.id, entries[100].id, "应保留最新记录")
        XCTAssertEqual(loaded.last?.id, entries[1].id, "最旧的一条应被裁剪")
        XCTAssertFalse(loaded.contains { $0.id == entries[0].id }, "被裁剪记录不应存在")
        // 完成时间严格递增插入，读取顺序应严格降序。
        XCTAssertEqual(loaded.map(\.completedAt), loaded.map(\.completedAt).sorted(by: >))
    }

    // MARK: - 持久化与排序

    func test_reopenPreservesHistory() async throws {
        let entries = [
            makeEntry(index: 0, completedAt: Date(timeIntervalSince1970: 10)),
            makeEntry(index: 1, completedAt: Date(timeIntervalSince1970: 20)),
            makeEntry(index: 2, completedAt: Date(timeIntervalSince1970: 30)),
        ]
        let store = makeStore()
        for entry in entries {
            try await store.insertAndPrune(entry, limit: 100)
        }

        // 新实例重新打开同一文件：迁移可重入，已有记录完整保留。
        let reopened = makeStore()
        let loaded = try await reopened.load(limit: 100)
        XCTAssertEqual(loaded, entries.sorted { $0.completedAt > $1.completedAt })
    }

    func test_loadOrdersByCompletedAtDescending() async throws {
        let store = makeStore()
        // 固定 UUID 让同一完成时间下的 id 排序断言可预期（SQLite 对 TEXT 主键按二进制比较）。
        let oldest = makeEntry(
            index: 0,
            completedAt: Date(timeIntervalSince1970: 50),
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        )
        let newestLowerID = makeEntry(
            index: 1,
            completedAt: Date(timeIntervalSince1970: 100),
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        )
        let newestHigherID = makeEntry(
            index: 2,
            completedAt: Date(timeIntervalSince1970: 100),
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        )
        let middle = makeEntry(
            index: 3,
            completedAt: Date(timeIntervalSince1970: 75),
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        )
        // 乱序插入，验证读取排序不依赖写入顺序。
        for entry in [middle, oldest, newestLowerID, newestHigherID] {
            try await store.insertAndPrune(entry, limit: 100)
        }

        let loaded = try await store.load(limit: 100)
        XCTAssertEqual(
            loaded.map(\.id),
            [newestHigherID.id, newestLowerID.id, middle.id, oldest.id],
            "应按完成时间倒序，同一时间按 id 倒序"
        )
    }

    // MARK: - 失败与回滚

    func test_failedTransactionRollsBackInsertAndPrune() async throws {
        let store = makeStore()
        var existing: [TranslationHistoryEntry] = []
        for index in 0..<3 {
            let entry = makeEntry(index: index)
            existing.append(entry)
            try await store.insertAndPrune(entry, limit: 3)
        }
        try installFailingDeleteTrigger()

        // 第 4 条插入成功但裁剪被拒绝：整个写事务回滚，新记录不得落库。
        let newest = makeEntry(index: 99, completedAt: Date(timeIntervalSince1970: 99))
        await assertThrowsAsync(
            { try await store.insertAndPrune(newest, limit: 3) },
            check: { error in
                XCTAssertTrue(error is DatabaseError, "裁剪失败应抛出数据库错误，实际：\(error)")
            }
        )

        let loaded = try await store.load(limit: 100)
        XCTAssertEqual(loaded.map(\.id), existing.reversed().map(\.id), "失败事务不得改变已有记录")
        XCTAssertFalse(loaded.contains { $0.id == newest.id }, "回滚后新记录不应存在")
    }

    func test_cancelledInsertDoesNotPersist() async throws {
        let store = makeStore()
        let entry = makeEntry(index: 0)
        // 用 AsyncStream 作为调用闸门：任务被取消后等待结束，随后进入存储时必然已观察到取消。
        let (gateStream, gateContinuation) = AsyncStream<Void>.makeStream()

        let task = Task {
            for await _ in gateStream { break }
            try await store.insertAndPrune(entry, limit: 100)
        }
        task.cancel()
        gateContinuation.finish()

        await assertThrowsAsync({ try await task.value }, check: { error in
            XCTAssertTrue(error is CancellationError, "取消应以 CancellationError 结束，实际：\(error)")
        })

        let loaded = try await store.load(limit: 100)
        XCTAssertTrue(loaded.isEmpty, "已取消的写入不得落库")
    }

    func test_deleteAndClearPropagateFailure() async throws {
        let store = makeStore()
        let first = makeEntry(index: 0)
        let second = makeEntry(index: 1)
        try await store.insertAndPrune(first, limit: 100)
        try await store.insertAndPrune(second, limit: 100)
        try installFailingDeleteTrigger()

        // 删除与清空失败必须抛出，不能静默忽略。
        await assertThrowsAsync({ try await store.delete(id: first.id) }, check: { error in
            XCTAssertTrue(error is DatabaseError, "单条删除失败应抛出数据库错误，实际：\(error)")
        })
        await assertThrowsAsync({ try await store.deleteAll() }, check: { error in
            XCTAssertTrue(error is DatabaseError, "清空失败应抛出数据库错误，实际：\(error)")
        })

        // 失败操作不得改变已有数据。
        let loaded = try await store.load(limit: 100)
        XCTAssertEqual(loaded.map(\.id), [second.id, first.id])
    }

    // MARK: - 读取边界

    func test_loadWithNonPositiveLimit_returnsEmpty() async throws {
        let store = makeStore()
        try await store.insertAndPrune(makeEntry(index: 0), limit: 100)
        // XCTest 断言的 autoclosure 不支持 async，先 await 到局部变量再断言。
        let zeroLimit = try await store.load(limit: 0)
        let negativeLimit = try await store.load(limit: -1)
        XCTAssertEqual(zeroLimit, [])
        XCTAssertEqual(negativeLimit, [])
    }
}
