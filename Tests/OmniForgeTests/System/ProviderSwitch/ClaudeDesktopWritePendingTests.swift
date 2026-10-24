import XCTest
@testable import OmniForge

/// pending 事务存储：持久化往返（0600）、损坏视为无意图；
/// 重放语义（幂等、部分写入补完）经 SettingsStore.replayPendingIfPresent 驱动。
final class ClaudeDesktopWritePendingTests: XCTestCase {
    private var tmpDir: URL!
    private var pendingURL: URL!
    private var store: ClaudeDesktopWritePendingStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDesktopWritePendingTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        pendingURL = tmpDir.appendingPathComponent("pending.json")
        store = ClaudeDesktopWritePendingStore(pendingURL: pendingURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makePending(files: [ClaudeDesktopWritePending.PendingFile]) -> ClaudeDesktopWritePending {
        ClaudeDesktopWritePending(files: files, createdAt: Date())
    }

    func test_saveThenLoadRoundTrips() throws {
        let fileA = tmpDir.appendingPathComponent("a.json")
        try store.save(makePending(files: [.init(url: fileA, object: ["k": "v", "nested": ["x": 1]])]))
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.files.count, 1)
        XCTAssertEqual(loaded.files[0].path, fileA.path)
        XCTAssertEqual(loaded.files[0].object["k"] as? String, "v")
        XCTAssertEqual((loaded.files[0].object["nested"] as? [String: Any])?["x"] as? Int, 1)
    }

    func test_corruptedPendingLoadsAsNil() throws {
        try Data("not json".utf8).write(to: pendingURL)
        XCTAssertNil(try store.load())
    }

    func test_clearRemovesPendingAndIsNoopWhenMissing() throws {
        try store.save(makePending(files: []))
        try store.clear()
        XCTAssertNil(try store.load())
        // 再次 clear 不抛错。
        try store.clear()
    }

    func test_savedPendingIsNotWorldReadable() throws {
        try store.save(makePending(files: []))
        let attrs = try FileManager.default.attributesOfItem(atPath: pendingURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    // MARK: - 重放语义（经 SettingsStore 驱动）

    private func makeSettingsStore(fileA: URL, fileB: URL) -> ClaudeDesktopSettingsStore {
        ClaudeDesktopSettingsStore(
            configURL: fileA,
            config3PURL: fileB,
            profileURL: fileA,
            metaURL: fileB,
            pendingURL: pendingURL
        )
    }

    /// 事务在第一个文件后崩溃（a 已写目标、b 未写、pending 仍在）→ 重放补完全部并删 pending。
    func test_settingsStoreReplayCompletesAfterPartialWrite() throws {
        let fileA = tmpDir.appendingPathComponent("a.json")
        let fileB = tmpDir.appendingPathComponent("b.json")
        try store.save(makePending(files: [
            .init(url: fileA, object: ["k": "a-target"]),
            .init(url: fileB, object: ["k": "b-target"]),
        ]))
        let data = try JSONSerialization.data(withJSONObject: ["k": "a-target"])
        try AtomicFileWriter.write(data, to: fileA)

        let settingsStore = makeSettingsStore(fileA: fileA, fileB: fileB)
        XCTAssertTrue(try settingsStore.replayPendingIfPresent())
        for (url, expected) in [(fileA, "a-target"), (fileB, "b-target")] {
            let object = try XCTUnwrap((try? JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            )) as? [String: Any])
            XCTAssertEqual(object["k"] as? String, expected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        // 再次重放：无 pending → false（幂等，无副作用）。
        XCTAssertFalse(try settingsStore.replayPendingIfPresent())
    }

    /// 旧内容整体覆盖（pending 是完整内容而非补丁）。
    func test_settingsStoreReplayOverwritesStaleContent() throws {
        let fileA = tmpDir.appendingPathComponent("a.json")
        let fileB = tmpDir.appendingPathComponent("b.json")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try Data(#"{"stale":true,"k":"old"}"#.utf8).write(to: fileA)
        try store.save(makePending(files: [
            .init(url: fileA, object: ["k": "a-target"]),
            .init(url: fileB, object: ["k": "b-target"]),
        ]))

        let settingsStore = makeSettingsStore(fileA: fileA, fileB: fileB)
        XCTAssertTrue(try settingsStore.replayPendingIfPresent())
        let object = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(contentsOf: fileA))) as? [String: Any])
        XCTAssertNil(object["stale"], "重放按完整目标内容整体覆盖")
        XCTAssertEqual(object["k"] as? String, "a-target")
    }
}
