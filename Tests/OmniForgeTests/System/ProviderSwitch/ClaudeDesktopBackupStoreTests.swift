import XCTest
@testable import OmniForge

/// Desktop bundle 备份：4 文件快照（缺失记 absent 不抛错）、absent 恢复（删除后来文件）、
/// 10 份保留、预览内容为 bundle 格式化 JSON。
final class ClaudeDesktopBackupStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var configURL: URL!
    private var config3PURL: URL!
    private var profileURL: URL!
    private var metaURL: URL!
    private var backupDir: URL!
    private var store: ClaudeDesktopBackupStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDesktopBackupStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configURL = tmpDir.appendingPathComponent("Claude/claude_desktop_config.json")
        config3PURL = tmpDir.appendingPathComponent("Claude-3p/claude_desktop_config.json")
        profileURL = tmpDir.appendingPathComponent("Claude-3p/configLibrary/profile.json")
        metaURL = tmpDir.appendingPathComponent("Claude-3p/configLibrary/_meta.json")
        backupDir = tmpDir.appendingPathComponent("backups")
        store = ClaudeDesktopBackupStore(
            configURL: configURL,
            config3PURL: config3PURL,
            profileURL: profileURL,
            metaURL: metaURL,
            backupDirectory: backupDir
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func test_snapshot_allMissingFilesRecordedAsAbsentWithoutThrowing() throws {
        // 本机 1P/3P 目录不存在正是首次切换场景：快照必须成功（SPEC 决策 3）。
        let backup = try store.snapshot4Files()
        XCTAssertEqual(backup.tool, .claudeDesktop)
        let content = try store.content(of: backup)
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any])
        let files = try XCTUnwrap(root["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 4)
        for file in files {
            XCTAssertEqual(file["absent"] as? Bool, true)
        }
    }

    func test_snapshot_capturesExistingContents() throws {
        try write(#"{"deploymentMode":"1p"}"#, to: configURL)
        try write(#"{"inferenceProvider":"gateway"}"#, to: profileURL)
        let backup = try store.snapshot4Files()
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(
            with: Data(try store.content(of: backup).utf8)
        )) as? [String: Any])
        let files = try XCTUnwrap(root["files"] as? [[String: Any]])
        let profileEntry = try XCTUnwrap(files.first { ($0["key"] as? String) == "profile" })
        XCTAssertNil(profileEntry["absent"])
        XCTAssertTrue((profileEntry["content"] as? String)?.contains("gateway") == true)
        let metaEntry = try XCTUnwrap(files.first { ($0["key"] as? String) == "meta" })
        XCTAssertEqual(metaEntry["absent"] as? Bool, true)
    }

    func test_restore_restoresContentsAndDeletesFilesAbsentInSnapshot() throws {
        // 快照时只有 config1P 存在。
        try write(#"{"deploymentMode":"1p"}"#, to: configURL)
        let backup = try store.snapshot4Files()

        // 快照后：config 被改动、profile 新出现。
        try write(#"{"deploymentMode":"3p"}"#, to: configURL)
        try write(#"{"inferenceProvider":"gateway"}"#, to: profileURL)

        try store.restore(backup)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("1p"), "恢复回快照内容")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path), "快照中 absent 的文件恢复为不存在")
    }

    func test_retention_keepsOnlyTenSnapshots() throws {
        try write(#"{"a":1}"#, to: configURL)
        for _ in 0..<12 {
            _ = try store.snapshot4Files()
        }
        XCTAssertEqual(store.list(tool: .claudeDesktop).count, 10)
    }

    func test_list_isEmptyForOtherTools() throws {
        try write(#"{"a":1}"#, to: configURL)
        _ = try store.snapshot4Files()
        XCTAssertTrue(store.list(tool: .claudeCode).isEmpty)
        XCTAssertTrue(store.list(tool: .codex).isEmpty)
    }
}
