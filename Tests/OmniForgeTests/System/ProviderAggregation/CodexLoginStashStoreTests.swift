import XCTest
@testable import OmniForge

/// Codex 官方登录收纳：无登录不收纳、收纳移走原文件、还原放回并清 stash、
/// 用户重新登录后还原不覆盖、重复收纳覆盖而非失败、discard 清 stash。
final class CodexLoginStashStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var authURL: URL!
    private var stashURL: URL!
    private var store: CodexLoginStashStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLoginStashStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        authURL = tmpDir.appendingPathComponent("auth.json")
        stashURL = tmpDir.appendingPathComponent(CodexLoginStashStore.stashFileName)
        store = CodexLoginStashStore(authURL: authURL, stashURL: stashURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeAuth(_ json: String) throws {
        try Data(json.utf8).write(to: authURL)
    }

    func test_hasNativeLogin_falseWhenAuthJSONMissing() {
        XCTAssertFalse(store.hasNativeLogin)
    }

    func test_stash_movesOfficialLoginAsideAndReportsTrue() throws {
        try writeAuth(#"{"tokens":{"access_token":"real"}}"#)
        XCTAssertTrue(try store.stash())
        XCTAssertFalse(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stashURL.path))
    }

    func test_stash_returnsFalseWhenNothingToStash() throws {
        XCTAssertFalse(try store.stash())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stashURL.path))
    }

    func test_restore_putsLoginBackAndClearsStash() throws {
        try writeAuth(#"{"tokens":{"access_token":"real"}}"#)
        _ = try store.stash()
        XCTAssertTrue(try store.restore())
        XCTAssertTrue(FileManager.default.fileExists(atPath: authURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stashURL.path))
    }

    func test_restore_doesNotOverwriteANewerLogin() throws {
        try writeAuth(#"{"tokens":{"access_token":"real"}}"#)
        _ = try store.stash()
        try writeAuth(#"{"tokens":{"access_token":"user-relogged-in"}}"#)   // 用户又跑了一次 codex login
        XCTAssertFalse(try store.restore())
        let text = try String(contentsOf: authURL, encoding: .utf8)
        XCTAssertTrue(text.contains("user-relogged-in"))
    }

    func test_stash_overwritesAnExistingStashRatherThanFailing() throws {
        try writeAuth(#"{"tokens":{"access_token":"real"}}"#)
        _ = try store.stash()
        try writeAuth(#"{"tokens":{"access_token":"real-2"}}"#)
        XCTAssertTrue(try store.stash())
        let text = try String(contentsOf: stashURL, encoding: .utf8)
        XCTAssertTrue(text.contains("real-2"))
    }

    func test_discard_removesStash() throws {
        try writeAuth(#"{"tokens":{"access_token":"real"}}"#)
        _ = try store.stash()
        try store.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stashURL.path))
    }
}
