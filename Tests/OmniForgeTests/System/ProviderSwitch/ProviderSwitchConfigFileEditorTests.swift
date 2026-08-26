import XCTest
@testable import OmniForge

/// 配置文件原文编辑器（SPEC 2.10）：读取缺失返回 nil、JSON/TOML 校验、
/// 保存走「备份 + 原子写」、非法内容拒绝保存且不落盘。
final class ProviderSwitchConfigFileEditorTests: XCTestCase {
    private var tmp: URL!
    private var settingsURL: URL!
    private var configURL: URL!
    private var backupDir: URL!
    private var editor: ConfigFileEditorStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderSwitchConfigFileEditorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        settingsURL = tmp.appendingPathComponent("settings.json")
        configURL = tmp.appendingPathComponent("config.toml")
        backupDir = tmp.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        editor = ConfigFileEditorStore(
            claudeConfigURL: settingsURL,
            codexConfigURL: configURL,
            backupStore: ProviderBackupStore(backupDirectory: backupDir)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_read_missingFileReturnsNil() throws {
        XCTAssertNil(try editor.read(tool: .claudeCode))
        XCTAssertNil(try editor.read(tool: .codex))
    }

    func test_read_returnsFileContent() throws {
        try Data("{\"env\":{}}".utf8).write(to: settingsURL)
        XCTAssertEqual(try editor.read(tool: .claudeCode), "{\"env\":{}}")
    }

    func test_isValid_claudeRequiresTopLevelJSONObject() {
        XCTAssertTrue(editor.isValid(tool: .claudeCode, content: "{\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"x\"}}"))
        XCTAssertFalse(editor.isValid(tool: .claudeCode, content: "[1,2,3]"), "顶层必须是对象")
        XCTAssertFalse(editor.isValid(tool: .claudeCode, content: "not json"))
    }

    func test_isValid_codexRequiresParsableTOML() {
        let valid = "model_provider = \"glm\"\n\n[model_providers.glm]\nname = \"GLM\"\n"
        XCTAssertTrue(editor.isValid(tool: .codex, content: valid))
        XCTAssertFalse(editor.isValid(tool: .codex, content: "model_provider = \"unterminated"))
    }

    func test_save_invalidContentThrowsAndWritesNothing() {
        XCTAssertThrowsError(try editor.save(tool: .claudeCode, content: "not json")) { error in
            XCTAssertEqual(error as? ConfigFileEditorError, .invalidContent(tool: .claudeCode))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path), "非法内容不落盘")
    }

    func test_save_existingFileBacksUpThenWrites() throws {
        try Data("{\"env\":{}}".utf8).write(to: settingsURL)
        try editor.save(tool: .claudeCode, content: "{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://x\"}}")
        XCTAssertEqual(
            try String(contentsOf: settingsURL, encoding: .utf8),
            "{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://x\"}}"
        )
        let backups = try ProviderBackupStore(backupDirectory: backupDir).list(tool: .claudeCode)
        XCTAssertEqual(backups.count, 1, "文件已存在 → 保存前产生快照")
    }

    func test_save_missingFileSkipsBackup() throws {
        try editor.save(tool: .claudeCode, content: "{\"env\":{}}")
        let backups = try ProviderBackupStore(backupDirectory: backupDir).list(tool: .claudeCode)
        XCTAssertTrue(backups.isEmpty, "文件不存在时无需备份")
    }

    func test_save_codexRoundTripPreservesOtherKeys() throws {
        let original = """
        model_provider = "openai"

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"

        [hooks]
        # 非供应商键原样保留
        PostToolUse = "echo hi"
        """
        try Data(original.utf8).write(to: configURL)
        try editor.save(tool: .codex, content: original)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }
}
