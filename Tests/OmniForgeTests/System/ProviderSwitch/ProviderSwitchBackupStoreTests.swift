import XCTest
@testable import OmniForge

/// 快照备份：时间戳文件、保留 10 份、按工具过滤、恢复原子写回。
final class ProviderSwitchBackupStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var backupDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderSwitchBackupStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        backupDir = tmpDir.appendingPathComponent("Backups")
        configURL = tmpDir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore() -> ProviderBackupStore {
        ProviderBackupStore(backupDirectory: backupDir)
    }

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    // MARK: - 快照

    func test_snapshot_createsTimestampedCopy() throws {
        try writeConfig("{\"env\": {\"A\": \"1\"}}")
        let backup = try makeStore().snapshot(tool: .claudeCode, of: configURL)
        XCTAssertTrue(backup.id.hasPrefix("claudeCode-"))
        XCTAssertTrue(backup.id.hasSuffix(".json"))
        let saved = try String(contentsOf: backupDir.appendingPathComponent(backup.id))
        XCTAssertEqual(saved, "{\"env\": {\"A\": \"1\"}}")
    }

    func test_snapshot_missingSourceThrows() {
        XCTAssertThrowsError(try makeStore().snapshot(tool: .claudeCode, of: configURL)) { error in
            XCTAssertEqual(error as? ProviderBackupError, .sourceMissing(path: configURL.path))
        }
    }

    func test_snapshot_retainsLatestTenPerTool() throws {
        let store = makeStore()
        for index in 0..<11 {
            try writeConfig("{\"n\": \(index)}")
            _ = try store.snapshot(tool: .claudeCode, of: configURL)
            try writeConfig("{\"codex\": \(index)}")
            _ = try store.snapshot(tool: .codex, of: configURL)
        }
        XCTAssertEqual(store.list(tool: .claudeCode).count, ProviderBackupStore.retentionLimit)
        XCTAssertEqual(store.list(tool: .codex).count, ProviderBackupStore.retentionLimit)
    }

    // MARK: - 列举

    func test_list_sortsNewestFirstAndFiltersByTool() throws {
        let store = makeStore()
        try writeConfig("{}")
        var backups: [ProviderBackup] = []
        for _ in 0..<3 {
            backups.append(try store.snapshot(tool: .claudeCode, of: configURL))
            _ = try store.snapshot(tool: .codex, of: configURL)
        }
        let listed = store.list(tool: .claudeCode)
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(listed.map(\.id), backups.reversed().map(\.id), "最新在前")
        XCTAssertTrue(store.list(tool: .codex).allSatisfy { $0.tool == .codex })
    }

    // MARK: - 解析

    func test_parse_fileName() throws {
        let backup = try XCTUnwrap(ProviderBackupStore.parse(fileName: "claudeCode-2026-08-26_12-00-00-1A2B.json"))
        XCTAssertEqual(backup.tool, .claudeCode)
        XCTAssertEqual(backup.date, DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 8, day: 26, hour: 12, minute: 0, second: 0
        ).date)
        XCTAssertNil(ProviderBackupStore.parse(fileName: "other-2026-08-26_12-00-00.json"))
        XCTAssertNil(ProviderBackupStore.parse(fileName: "no-date.json"))
    }

    // MARK: - 恢复

    func test_restore_writesSnapshotContentAtomically() throws {
        let store = makeStore()
        try writeConfig("{\"before\": true}")
        let backup = try store.snapshot(tool: .claudeCode, of: configURL)

        // 源文件被改写后恢复 → 回到快照内容
        try writeConfig("{\"broken\": true}")
        try store.restore(backup, to: configURL)
        XCTAssertEqual(try String(contentsOf: configURL), "{\"before\": true}")
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func test_restore_missingBackupThrows() {
        let store = makeStore()
        let backup = ProviderBackup(id: "claudeCode-2026-08-26_12-00-00-1A2B.json", tool: .claudeCode, date: Date())
        XCTAssertThrowsError(try store.restore(backup, to: configURL)) { error in
            XCTAssertEqual(error as? ProviderBackupError, .backupMissing(path: backupDir.appendingPathComponent(backup.id).path))
        }
    }
}
