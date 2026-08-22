import Foundation
import XCTest
@testable import OmniForge

/// GRDB 用量存储：主键 upsert 幂等/last-writer-wins、窗口查询、已见 key 持久化 + LRU、文件游标。
final class GRDBUsageStoreTests: XCTestCase {
    private var databaseURL: URL!
    private var store: GRDBUsageStore!
    private let provider: TokenUsageProvider = .claude

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBUsageStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("usage.sqlite")
        store = GRDBUsageStore(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func state(
        model: String = "claude-sonnet-4-5",
        bucket: Date = Date(timeIntervalSince1970: 1_784_700_000),
        total: Int = 100,
        conversations: Int = 0,
        provider: TokenUsageProvider? = nil
    ) -> UsageBucketState {
        UsageBucketState(
            key: UsageBucketKey(provider: provider ?? self.provider, model: model, bucketStart: bucket),
            usage: TokenUsage(
                inputTokens: total,
                cachedInputTokens: total / 2,
                cacheCreationInputTokens: total / 4,
                outputTokens: total / 8,
                reasoningOutputTokens: 0,
                totalTokens: total
            ),
            conversationCount: conversations
        )
    }

    // MARK: - 桶 upsert

    func test_upsertBucket_idempotent() {
        let s = state(total: 160, conversations: 2)
        store.upsertBucket(s)
        store.upsertBucket(s)
        XCTAssertEqual(store.loadBucket(s.key), s, "重复写同一累计快照结果一致")
    }

    func test_upsertBucket_lastWriterWins() {
        let early = state(total: 100, conversations: 1)
        let latest = state(total: 260, conversations: 2)
        store.upsertBucket(early)
        store.upsertBucket(latest)
        let loaded = store.loadBucket(latest.key)
        XCTAssertEqual(loaded?.usage.totalTokens, 260)
        XCTAssertEqual(loaded?.conversationCount, 2)
        // 仍是单行
        XCTAssertEqual(store.loadBuckets(from: .distantPast, to: .distantFuture, providers: nil).count, 1)
    }

    func test_upsertBucket_separatesModelAndProvider() {
        store.upsertBucket(state(model: "a", total: 1))
        store.upsertBucket(state(model: "b", total: 2))
        store.upsertBucket(state(model: "a", total: 3, provider: .codex))
        XCTAssertEqual(store.loadBuckets(from: .distantPast, to: .distantFuture, providers: nil).count, 3)
    }

    func test_loadBuckets_windowFilter() {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        store.upsertBucket(state(bucket: base, total: 10))
        store.upsertBucket(state(bucket: base.addingTimeInterval(1800), total: 20))
        store.upsertBucket(state(bucket: base.addingTimeInterval(-7200), total: 30))
        let inWindow = store.loadBuckets(from: base.addingTimeInterval(-3600), to: base.addingTimeInterval(3600), providers: nil)
        XCTAssertEqual(inWindow.map { $0.usage.totalTokens }.sorted(), [10, 20])
        let providerFiltered = store.loadBuckets(from: .distantPast, to: .distantFuture, providers: [.codex])
        XCTAssertTrue(providerFiltered.isEmpty)
    }

    // MARK: - 已见 key

    func test_seenKeys_roundTrip() {
        let now = Date(timeIntervalSince1970: 1_784_700_000)
        XCTAssertTrue(store.loadSeenKeys().isEmpty)
        store.storeSeenKeys(["msg:a", "msg:b", "u:line1"], asOf: now)
        XCTAssertEqual(store.loadSeenKeys(), ["msg:a", "msg:b", "u:line1"])
        store.storeSeenKeys(["msg:c"], asOf: now.addingTimeInterval(1))
        XCTAssertEqual(store.loadSeenKeys().count, 4)
    }

    func test_seenKeys_lruTrimKeepsNewest() {
        let store = GRDBUsageStore(databaseURL: databaseURL, maxSeenKeys: 3)
        let now = Date(timeIntervalSince1970: 1_784_700_000)
        store.storeSeenKeys(["k1", "k2"], asOf: now)
        store.storeSeenKeys(["k3"], asOf: now.addingTimeInterval(1))
        store.storeSeenKeys(["k4"], asOf: now.addingTimeInterval(2))
        XCTAssertEqual(store.loadSeenKeys(), ["k2", "k3", "k4"], "超出上限淘汰最旧")
    }

    // MARK: - 游标

    func test_cursors_roundTripAndClear() {
        let cursor = JSONLCursor(inode: 123, offset: 456)
        XCTAssertNil(store.loadCursors()["/tmp/a.jsonl"])
        store.storeCursor(path: "/tmp/a.jsonl", cursor: cursor)
        XCTAssertEqual(store.loadCursors()["/tmp/a.jsonl"], cursor)
        XCTAssertNil(store.loadCursors()["/tmp/b.jsonl"])
        let all = store.loadCursors()
        XCTAssertEqual(all["/tmp/a.jsonl"], cursor)
        store.clearCursors()
        XCTAssertTrue(store.loadCursors().isEmpty)
    }

    func test_filePermissions_0600() throws {
        // 隐私红线：落盘文件权限 0600。
        let attrs = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertNotNil(permissions)
        XCTAssertEqual(permissions! & 0o777, 0o600, "数据库文件须 0600")
    }
}
