import XCTest
@testable import OmniForge

/// 编排管理器：切换先快照后写入、失败自动回滚、激活态识别、收编、备份恢复（全部替身）。
@MainActor
final class ProviderSwitchManagerTests: XCTestCase {
    // MARK: - 替身

    private final class StubClaudeStore: ClaudeSettingsStoring {
        var env: [String: String] = [:]
        var envError: ProviderConfigFileError?
        var applied: [ProviderProfile] = []
        var applyError: Error?
        var cleared = 0
        var clearError: Error?

        func readEnv() throws -> [String: String] {
            if let envError { throw envError }
            return env
        }

        func applyProfile(_ profile: ProviderProfile) throws {
            if let applyError { throw applyError }
            applied.append(profile)
            env = [
                "ANTHROPIC_AUTH_TOKEN": profile.token,
                "ANTHROPIC_BASE_URL": profile.baseURL,
            ]
        }

        func clearOverrides() throws {
            if let clearError { throw clearError }
            cleared += 1
            env = [:]
        }
    }

    private final class StubCodexStore: CodexConfigStoring {
        var active: (key: String?, baseURL: String?, token: String?) = (nil, nil, nil)
        var activeError: ProviderConfigFileError?
        var applied: [ProviderProfile] = []
        var applyError: Error?
        var cleared = 0
        var clearError: Error?

        func readActiveProvider() throws -> (key: String?, baseURL: String?, token: String?) {
            if let activeError { throw activeError }
            return active
        }

        func applyProfile(_ profile: ProviderProfile) throws {
            if let applyError { throw applyError }
            applied.append(profile)
            active = (profile.profileKey, profile.baseURL, profile.token)
        }

        func clearOverrides() throws {
            if let clearError { throw clearError }
            cleared += 1
            active = (nil, nil, nil)
        }
    }

    private final class StubBackupStore: ProviderBackupStoring {
        var snapshots: [ProviderTool] = []
        var restored: [ProviderBackup] = []
        var failRestore = false

        func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
            snapshots.append(tool)
            return ProviderBackup(
                id: "\(tool.rawValue)-2026-08-26_12-00-00-1A2B.\(configURL.pathExtension)",
                tool: tool,
                date: Date()
            )
        }

        func list(tool: ProviderTool) -> [ProviderBackup] { [] }

        func restore(_ backup: ProviderBackup, to configURL: URL) throws {
            if failRestore { throw ProviderBackupError.backupMissing(path: backup.id) }
            restored.append(backup)
        }
    }

    private final class StubProfileStore: ProviderProfileStoring {
        var stored: [ProviderProfile] = []
        var upsertError: Error?
        var deleted: [ProviderProfile] = []

        func list(for tool: ProviderTool) -> [ProviderProfile] {
            stored.filter { $0.tool == tool }
        }

        func upsert(_ profile: ProviderProfile) throws {
            if let upsertError { throw upsertError }
            stored.removeAll { $0.id == profile.id }
            stored.append(profile)
        }

        func delete(_ profile: ProviderProfile) throws {
            deleted.append(profile)
            stored.removeAll { $0.id == profile.id }
        }

        func adopt(
            name: String,
            tool: ProviderTool,
            baseURL: String,
            token: String,
            modelOverride: String?
        ) throws -> ProviderProfile {
            let profile = ProviderProfile(
                id: name,
                name: name,
                tool: tool,
                baseURL: baseURL,
                token: token,
                modelOverride: modelOverride,
                modelMapping: nil,
                extraEnv: [:],
                managedBy: "omniforge"
            )
            stored.append(profile)
            return profile
        }
    }

    private final class StubDetector: RunningProcessDetecting {
        var runningTools: Set<ProviderTool> = []

        func isRunning(tool: ProviderTool) -> Bool {
            runningTools.contains(tool)
        }
    }

    // MARK: - 夹具

    private var claudeStore: StubClaudeStore!
    private var codexStore: StubCodexStore!
    private var backupStore: StubBackupStore!
    private var profileStore: StubProfileStore!
    private var detector: StubDetector!
    private var manager: ProviderSwitchManager!
    private var claudeConfigURL: URL!
    private var codexConfigURL: URL!

    override func setUpWithError() throws {
        claudeStore = StubClaudeStore()
        codexStore = StubCodexStore()
        backupStore = StubBackupStore()
        profileStore = StubProfileStore()
        detector = StubDetector()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderSwitchManagerTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        claudeConfigURL = tmp.appendingPathComponent("settings.json")
        codexConfigURL = tmp.appendingPathComponent("config.toml")
        manager = ProviderSwitchManager(
            claudeStore: claudeStore,
            codexStore: codexStore,
            backupStore: backupStore,
            profileStore: profileStore,
            claudeConfigURL: claudeConfigURL,
            codexConfigURL: codexConfigURL,
            processDetector: detector,
            fileManager: .default
        )
    }

    private func seedProfile(
        name: String = "GLM",
        tool: ProviderTool = .claudeCode,
        baseURL: String = "https://open.bigmodel.cn/api/anthropic"
    ) -> ProviderProfile {
        let profile = ProviderProfile(
            id: ProviderProfile.slugify(name),
            name: name,
            tool: tool,
            baseURL: baseURL,
            token: "sk-x",
            modelOverride: nil,
            modelMapping: nil,
            extraEnv: [:],
            managedBy: "omniforge"
        )
        profileStore.stored.append(profile)
        return profile
    }

    // MARK: - 激活态识别（SPEC 2.6）

    func test_refresh_detectsOfficialWhenNoOverride() {
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .official)
        XCTAssertEqual(manager.active(tool: .codex), .official)
    }

    func test_refresh_detectsProfileByBaseURL() {
        seedProfile()
        claudeStore.env = [
            "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
            "ANTHROPIC_AUTH_TOKEN": "sk-x",
        ]
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .profile(profileID: "glm"))
    }

    func test_refresh_detectsUnmanagedWhenNoProfileMatches() {
        claudeStore.env = ["ANTHROPIC_BASE_URL": "https://manual.example"]
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .unmanaged(summary: "https://manual.example"))
    }

    func test_refresh_detectsUnreadableWhenCorrupted() {
        claudeStore.envError = .corrupted(path: "settings.json")
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .unreadable)
    }

    func test_refresh_detectsCodexProfileByProviderKey() {
        seedProfile(name: "GLM", tool: .codex, baseURL: "https://open.bigmodel.cn/api/paas/v4")
        codexStore.active = ("glm", "https://open.bigmodel.cn/api/paas/v4", "sk-x")
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .codex), .profile(profileID: "glm"))
    }

    func test_refresh_detectsCodexBuiltInAsOfficial() {
        codexStore.active = ("openai", "https://api.openai.com/v1", nil)
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .codex), .official)
    }

    func test_refresh_detectsCodexUnknownKeyAsUnmanaged() {
        codexStore.active = ("weird", nil, nil)
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .codex), .unmanaged(summary: "weird"))
    }

    func test_refresh_loadsProfilesForBothTools() {
        _ = seedProfile(name: "GLM", tool: .claudeCode)
        _ = seedProfile(name: "Kimi", tool: .codex)
        manager.refresh()
        XCTAssertEqual(manager.profiles(for: .claudeCode).map(\.name), ["GLM"])
        XCTAssertEqual(manager.profiles(for: .codex).map(\.name), ["Kimi"])
    }

    // MARK: - 切换

    func test_switchTo_snapshotsThenAppliesAndRefreshes() throws {
        let profile = seedProfile()
        claudeStore.env = ["ANTHROPIC_BASE_URL": "https://old.example"]
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .unmanaged(summary: "https://old.example"))

        let outcome = try manager.switchTo(profile: profile)
        XCTAssertEqual(backupStore.snapshots, [.claudeCode], "写入前先快照")
        XCTAssertEqual(claudeStore.applied.map(\.id), ["glm"])
        XCTAssertEqual(outcome.target, .profile(name: "GLM"))
        XCTAssertFalse(outcome.cliRunning)
        XCTAssertEqual(manager.active(tool: .claudeCode), .profile(profileID: "glm"))
    }

    func test_switchTo_codexRoutesToCodexStore() throws {
        let profile = seedProfile(name: "GLM", tool: .codex)
        let outcome = try manager.switchTo(profile: profile)
        XCTAssertEqual(backupStore.snapshots, [.codex])
        XCTAssertEqual(codexStore.applied.map(\.id), ["glm"])
        XCTAssertEqual(outcome.tool, .codex)
    }

    func test_switchTo_reportsRunningProcess() throws {
        detector.runningTools = [.claudeCode]
        let profile = seedProfile()
        let outcome = try manager.switchTo(profile: profile)
        XCTAssertTrue(outcome.cliRunning, "检测到运行中进程 → 提示需重启")
    }

    func test_switchTo_writeFailureRollsBackFromSnapshot() throws {
        let profile = seedProfile()
        claudeStore.applyError = ProviderConfigFileError.writeFailed(path: "settings.json")
        XCTAssertThrowsError(try manager.switchTo(profile: profile)) { error in
            XCTAssertEqual(error as? ProviderConfigFileError, .writeFailed(path: "settings.json"))
        }
        XCTAssertEqual(backupStore.restored.count, 1, "写入失败自动从快照回滚")
        XCTAssertEqual(backupStore.restored[0].tool, .claudeCode)
    }

    func test_switchTo_rollbackFailureThrowsRollbackFailed() throws {
        let profile = seedProfile()
        claudeStore.applyError = ProviderConfigFileError.writeFailed(path: "settings.json")
        backupStore.failRestore = true
        XCTAssertThrowsError(try manager.switchTo(profile: profile)) { error in
            XCTAssertEqual(error as? ProviderSwitchManagerError, .rollbackFailed(tool: .claudeCode))
        }
    }

    func test_switchToOfficial_clearsOverrides() throws {
        seedProfile()
        claudeStore.env = [
            "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
            "ANTHROPIC_AUTH_TOKEN": "sk-x",
        ]
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .profile(profileID: "glm"))

        let outcome = try manager.switchToOfficial(tool: .claudeCode)
        XCTAssertEqual(claudeStore.cleared, 1)
        XCTAssertEqual(outcome.target, .official)
        XCTAssertEqual(manager.active(tool: .claudeCode), .official)
    }

    func test_switchToOfficial_codexClears() throws {
        _ = seedProfile(name: "GLM", tool: .codex)
        codexStore.active = ("glm", "https://open.bigmodel.cn/api/paas/v4", "sk-x")
        manager.refresh()
        let outcome = try manager.switchToOfficial(tool: .codex)
        XCTAssertEqual(codexStore.cleared, 1)
        XCTAssertEqual(outcome.target, .official)
        XCTAssertEqual(manager.active(tool: .codex), .official)
    }

    // MARK: - profile 管理

    func test_upsertProfile_delegatesAndRefreshes() throws {
        let profile = seedProfile(name: "新档案")
        try manager.upsertProfile(profile)
        XCTAssertEqual(profileStore.stored.map(\.name), ["新档案"])
        XCTAssertEqual(manager.profiles(for: .claudeCode).count, 1)
    }

    func test_deleteProfile_delegates() throws {
        let profile = seedProfile()
        manager.refresh()
        try manager.deleteProfile(profile)
        XCTAssertEqual(profileStore.deleted.map(\.id), ["glm"])
        XCTAssertTrue(manager.profiles(for: .claudeCode).isEmpty)
    }

    // MARK: - 收编（SPEC 2.6）

    func test_adoptUnmanaged_claudeReadsEnvAndCreatesProfile() throws {
        claudeStore.env = [
            "ANTHROPIC_BASE_URL": "https://manual.example",
            "ANTHROPIC_AUTH_TOKEN": "sk-manual",
        ]
        let profile = try manager.adoptUnmanaged(tool: .claudeCode, name: "手改供应商")
        XCTAssertEqual(profile.baseURL, "https://manual.example")
        XCTAssertEqual(profile.token, "sk-manual")
        XCTAssertEqual(manager.profiles(for: .claudeCode).map(\.name), ["手改供应商"])
    }

    func test_adoptUnmanaged_codexReadsActiveProvider() throws {
        codexStore.active = ("weird", "https://manual.example", "sk-manual")
        let profile = try manager.adoptUnmanaged(tool: .codex, name: "手改 Codex")
        XCTAssertEqual(profile.baseURL, "https://manual.example")
        XCTAssertEqual(profile.token, "sk-manual")
        XCTAssertEqual(manager.active(tool: .codex), .unmanaged(summary: "https://manual.example"), "收编不改变激活态")
    }

    func test_adoptUnmanaged_missingValuesThrows() {
        XCTAssertThrowsError(try manager.adoptUnmanaged(tool: .claudeCode, name: "x")) { error in
            XCTAssertEqual(error as? ProviderSwitchManagerError, .missingUnmanagedValues(tool: .claudeCode))
        }
    }

    // MARK: - 备份恢复

    func test_restoreBackup_restoresToToolConfigURL() throws {
        let backup = ProviderBackup(
            id: "claudeCode-2026-08-26_12-00-00-1A2B.json",
            tool: .claudeCode,
            date: Date()
        )
        try manager.restoreBackup(backup)
        XCTAssertEqual(backupStore.restored.map(\.id), [backup.id])
    }

    // MARK: - 损坏配置重建（SPEC 2.8.2）

    func test_rebuildCorruptedConfig_snapshotsAndRemovesCorruptedFile() throws {
        try Data("not json".utf8).write(to: claudeConfigURL)
        claudeStore.envError = .corrupted(path: "settings.json")
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .unreadable)

        try manager.rebuildCorruptedConfig(tool: .claudeCode)
        XCTAssertEqual(backupStore.snapshots, [.claudeCode], "坏文件先复制进备份目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeConfigURL.path), "坏文件被移除")
        // 坏文件移除后配置可读 → 回到无 override 状态
        claudeStore.envError = nil
        manager.refresh()
        XCTAssertEqual(manager.active(tool: .claudeCode), .official, "重建后回到无 override 状态")
    }

    func test_rebuildCorruptedConfig_missingFileIsNoop() throws {
        try manager.rebuildCorruptedConfig(tool: .claudeCode)
        XCTAssertTrue(backupStore.snapshots.isEmpty, "文件不存在时不产生备份")
    }
}
