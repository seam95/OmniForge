import XCTest
@testable import OmniForge

/// 写前意图持久化：无 pending 返回 nil、往返、清理、损坏隔离；
/// 恢复判定只看 published 标记（true 前滚 / false 丢弃）。
final class AggregationPendingStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var pendingURL: URL!
    private var store: AggregationPendingStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationPendingStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        pendingURL = tmpDir.appendingPathComponent("pending.json")
        store = AggregationPendingStore(pendingURL: pendingURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_load_returnsNilWhenNoPending() {
        XCTAssertNil(store.load())
    }

    func test_save_thenLoad_roundTrips() throws {
        try store.save(AggregationPending(tool: .codex, stack: AggregationStack(codex: .init(members: ["a"], keys: ["a": "a"])), published: false))
        XCTAssertEqual(store.load()?.tool, .codex)
    }

    func test_clear_removesPending() throws {
        try store.save(AggregationPending(tool: .claudeCode, stack: AggregationStack(), published: false))
        try store.clear()
        XCTAssertNil(store.load())
    }

    func test_load_quarantinesCorruptPending() throws {
        try Data("broken".utf8).write(to: pendingURL)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    }

    func test_recoveryDecision_publishedFlagDecidesRollForwardVsDiscard() {
        XCTAssertEqual(AggregationPendingStore.recovery(
            for: AggregationPending(tool: .codex, stack: AggregationStack(), published: true)), .rolledForward)
        XCTAssertEqual(AggregationPendingStore.recovery(
            for: AggregationPending(tool: .codex, stack: AggregationStack(), published: false)), .discarded)
    }
}
