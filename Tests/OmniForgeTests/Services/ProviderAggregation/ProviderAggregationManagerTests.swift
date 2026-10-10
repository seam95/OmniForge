import XCTest
@testable import OmniForge

/// 聚合编排管理器：进入先起代理后写配置、代理起不来不写配置、Codex 登录收纳/还原、
/// 快照进入与恢复、按工具独立、单工具退出不停代理、名单与 key 保留、
/// 官方账号禁入、默认成员聚合期间禁移、删 profile 摘名单留 key、契约未变不重写、
/// 部分写入语义、看门狗重启与回落。
@MainActor
final class ProviderAggregationManagerTests: XCTestCase {
    private var tmpDir: URL!
    private var profileStore: StubProfileStore!
    private var backupStore: StubBackupStore!
    private var loginStash: StubLoginStashStore!
    private var staleDetector: StubStaleDetector!
    private var proxy: StubProxy!
    private var claudeWriter: StubClaudeWriter!
    private var codexWriter: StubCodexWriter!
    private var manager: ProviderAggregationManager!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAggregationManagerTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        profileStore = StubProfileStore()
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .claudeCode,
                baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
                stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
            ),
            ProviderProfile(
                id: "glm", name: "GLM", tool: .claudeCode,
                baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
            ),
            ProviderProfile(
                id: "anthropic-official", name: "Anthropic", tool: .claudeCode,
                baseURL: "https://api.anthropic.com", token: "sk-official"
            ),
            ProviderProfile(
                id: "deepseek", name: "DeepSeek", tool: .codex,
                baseURL: "https://api.deepseek.com/v1", token: "sk-ds",
                codexModels: ["deepseek-v4-pro"]
            ),
        ]
        backupStore = StubBackupStore()
        loginStash = StubLoginStashStore()
        staleDetector = StubStaleDetector()
        proxy = StubProxy()
        claudeWriter = StubClaudeWriter()
        codexWriter = StubCodexWriter()
        manager = makeManager()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeManager() -> ProviderAggregationManager {
        ProviderAggregationManager(
            profileStore: profileStore,
            backupStore: backupStore,
            stackStore: AggregationStackStore(stackURL: tmpDir.appendingPathComponent("stack.json")),
            pendingStore: AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending.json")),
            loginStashStore: loginStash,
            staleDetector: staleDetector,
            proxy: proxy,
            claudeWriter: claudeWriter,
            codexWriter: codexWriter,
            profiles: profileStore.stubProfiles
        )
    }

    // MARK: - 进入/退出

    func test_enterAggregation_startsProxyBeforeWritingConfig() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertTrue(manager.isProxyRunning)
        XCTAssertEqual(claudeWriter.lastAppliedPort, manager.resolvedPort)
        XCTAssertEqual(claudeWriter.lastDefaultProfile?.id, "kimi")
    }

    func test_enterAggregation_doesNotWriteConfigWhenProxyFailsToStart() {
        proxy.stubStartError = AggregationProxyError.allPortsTaken
        XCTAssertThrowsError(try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi"))
        XCTAssertNil(claudeWriter.lastAppliedPort)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
    }

    func test_enterAggregation_stashesCodexOfficialLogin() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertEqual(loginStash.stashCallCount, 1)
    }

    func test_exitAggregation_restoresLoginAndStopsProxyWhenNoToolAggregates() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        try manager.exitAggregation(tool: .codex)
        XCTAssertEqual(loginStash.restoreCallCount, 1)
        XCTAssertFalse(manager.isProxyRunning)
    }

    func test_exitAggregation_restoresPreAggregationSnapshot() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertEqual(backupStore.snapshotCallCount, 1)   // 进入聚合的写流程以快照开头
        try manager.exitAggregation(tool: .claudeCode)
        XCTAssertEqual(backupStore.restoreCallCount, 1)   // 退出 = 从进入前快照恢复直连配置
    }

    func test_enterAggregation_isIndependentPerTool() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertEqual(manager.mode(tool: .codex), .aggregation)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
    }

    func test_exitOneToolKeepsProxyRunningWhileOtherStillAggregates() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        try manager.exitAggregation(tool: .codex)
        XCTAssertTrue(manager.isProxyRunning)
    }

    // MARK: - 成员管理

    func test_exitAggregation_retainsMembersAndKeys() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm")
        try manager.exitAggregation(tool: .claudeCode)
        XCTAssertEqual(manager.toolStack(.claudeCode).members, ["kimi", "glm"])
        XCTAssertEqual(manager.toolStack(.claudeCode).keys["glm"], "glm")
    }

    func test_addMember_allocatesPermanentKey() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm")
        XCTAssertEqual(manager.toolStack(.claudeCode).keyOf(profileID: "glm"), "glm")
    }

    func test_addMember_rejectsOfficialAccount() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertThrowsError(try manager.addMember("anthropic-official"))
        XCTAssertFalse(manager.toolStack(.claudeCode).isMember("anthropic-official"))
    }

    func test_removeDefaultMemberIsRejectedWhileAggregating() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertThrowsError(try manager.removeMember("kimi"))
    }

    func test_removeDefaultMemberIsAllowedOnceAggregationExited() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.exitAggregation(tool: .claudeCode)
        try manager.removeMember("kimi")
        XCTAssertFalse(manager.toolStack(.claudeCode).isMember("kimi"))
        XCTAssertNotNil(manager.toolStack(.claudeCode).keys["kimi"])   // key 仍保留
    }

    func test_deletingProfileRemovesItFromMembersButKeepsKey() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm")
        profileStore.stubProfiles.removeAll { $0.id == "glm" }
        manager.refresh()
        XCTAssertFalse(manager.toolStack(.claudeCode).isMember("glm"))
        XCTAssertNotNil(manager.toolStack(.claudeCode).keys["glm"])
    }

    func test_addMember_skipsRewriteWhenContractUnchanged() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        let writesBefore = claudeWriter.applyCount
        try manager.addMember("kimi")   // 已在名单里 → 无变化
        XCTAssertEqual(claudeWriter.applyCount, writesBefore)
    }

    // MARK: - 部分写入与看门狗

    func test_partialFailureReportsPartialTrueAfterPublish() throws {
        codexWriter.stubApplyError = StubError.writeFailed
        XCTAssertThrowsError(try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek"))
        XCTAssertEqual(manager.lastPartialWrite, true)
        XCTAssertNotNil(pendingStore().load())
        // published 在发布前已置 true（见实现），恢复判定应为 .rolledForward（幂等补完），而非丢弃
        XCTAssertEqual(pendingStore().load()?.published, true)
    }

    func test_proxyUnexpectedStop_restartsThenFallsBackAfterRepeatedFailures() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        proxy.simulateUnexpectedStop()          // 第一次异常退出 → 看门狗自动重启
        XCTAssertTrue(manager.isProxyRunning)
        proxy.stubStartError = AggregationProxyError.allPortsTaken
        proxy.simulateUnexpectedStop()          // 重启失败 → 回落直连并报错
        XCTAssertFalse(manager.isProxyRunning)
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
    }

    private func pendingStore() -> AggregationPendingStore {
        AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending.json"))
    }
}

// MARK: - Stubs

private enum StubError: Error, Equatable {
    case writeFailed
}

private final class StubProxy: AggregationProxying {
    var isRunning = false
    var resolvedPort: UInt16?
    var onUnexpectedStop: (() -> Void)?
    var stubStartError: Error?

    func start() throws {
        if let stubStartError { throw stubStartError }
        isRunning = true
        resolvedPort = 15721
    }

    func stop() {
        isRunning = false
        resolvedPort = nil
    }

    /// 模拟异常退出：清运行态并触发看门狗回调。
    func simulateUnexpectedStop() {
        isRunning = false
        resolvedPort = nil
        onUnexpectedStop?()
    }
}

private final class StubProfileStore: ProviderProfileStoring {
    var stubProfiles: [ProviderProfile] = []
    func list(for tool: ProviderTool) -> [ProviderProfile] {
        stubProfiles.filter { $0.tool == tool }
    }
    func upsert(_ profile: ProviderProfile) throws {}
    func delete(_ profile: ProviderProfile) throws {}
    func adopt(name: String, tool: ProviderTool, baseURL: String, token: String, modelOverride: String?) throws -> ProviderProfile {
        ProviderProfile(id: "", name: name, tool: tool, baseURL: baseURL, token: token, modelOverride: modelOverride)
    }
}

private final class StubBackupStore: ProviderBackupStoring {
    var snapshotCallCount = 0
    var restoreCallCount = 0
    private var backups: [ProviderTool: [ProviderBackup]] = [:]

    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
        snapshotCallCount += 1
        let backup = ProviderBackup(id: "stub-\(snapshotCallCount)", tool: tool, date: Date())
        backups[tool, default: []].insert(backup, at: 0)
        return backup
    }

    func list(tool: ProviderTool) -> [ProviderBackup] {
        backups[tool] ?? []
    }

    func content(of backup: ProviderBackup) throws -> String { "" }

    func restore(_ backup: ProviderBackup, to configURL: URL) throws {
        restoreCallCount += 1
    }
}

private final class StubLoginStashStore: CodexLoginStashStoring {
    var hasNativeLogin = false
    var stashCallCount = 0
    var restoreCallCount = 0

    func stash() throws -> Bool {
        stashCallCount += 1
        return hasNativeLogin
    }

    func restore() throws -> Bool {
        restoreCallCount += 1
        return false
    }

    func discard() throws {}
}

private final class StubStaleDetector: CodexStaleClientDetecting {
    var observeCallCount = 0
    var stubStale: CodexStaleClients?

    func observe(catalogURL: URL, catalogIsOurs: Bool) {
        observeCallCount += 1
    }

    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? {
        stubStale
    }
}

/// Claude 写入桩：digest 以「已应用过的发布模型 id 列表」为磁盘现状口径——
/// 名单不变 → 投影不变 → 跳过重写。
private final class StubClaudeWriter: AggregationClaudeConfigWriting {
    var lastAppliedPort: UInt16?
    var lastDefaultProfile: ProviderProfile?
    var applyCount = 0
    var stubApplyError: Error?
    private var appliedPublished: [AggregationPublishedModel] = []

    func applyAggregation(defaultProfile: ProviderProfile, published: [AggregationPublishedModel], port: UInt16) throws {
        if let stubApplyError { throw stubApplyError }
        lastAppliedPort = port
        lastDefaultProfile = defaultProfile
        appliedPublished = published
        applyCount += 1
    }

    func clearAggregation() throws {}

    func currentContractDigest() -> String {
        Self.digest(of: appliedPublished)
    }

    func projectedContractDigest(defaultProfile: ProviderProfile, published: [AggregationPublishedModel], port: UInt16) -> String {
        Self.digest(of: published)
    }

    private static func digest(of published: [AggregationPublishedModel]) -> String {
        published.map(\.id).joined(separator: "|")
    }
}

/// Codex 写入桩：口径同 Claude 桩。
private final class StubCodexWriter: AggregationCodexConfigWriting {
    var lastAppliedPort: UInt16?
    var lastDefaultProfile: ProviderProfile?
    var lastRequiresOpenAIAuth: Bool?
    var applyCount = 0
    var stubApplyError: Error?
    private var appliedPublished: [AggregationPublishedModel] = []

    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) throws {
        if let stubApplyError { throw stubApplyError }
        lastAppliedPort = port
        lastDefaultProfile = defaultProfile
        lastRequiresOpenAIAuth = requiresOpenAIAuth
        appliedPublished = published
        applyCount += 1
    }

    func clearAggregation() throws {}

    func currentContractDigest() -> String {
        Self.digest(of: appliedPublished)
    }

    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) -> String {
        Self.digest(of: published)
    }

    private static func digest(of published: [AggregationPublishedModel]) -> String {
        published.map(\.id).joined(separator: "|")
    }
}
