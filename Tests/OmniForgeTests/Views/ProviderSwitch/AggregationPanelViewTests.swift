import XCTest
@testable import OmniForge

/// 聚合面板可测成员：模式分段字符串、默认卡片无移除钮、官方账号不入可选名单、
/// 直连互斥判定、双语言非空。
@MainActor
final class AggregationPanelViewTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationPanelViewTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - fixtures

    private var kimiProfile: ProviderProfile {
        ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
        )
    }

    private var glmProfile: ProviderProfile {
        ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
        )
    }

    private var officialProfile: ProviderProfile {
        ProviderProfile(
            id: "anthropic-official", name: "Anthropic", tool: .claudeCode,
            baseURL: "https://api.anthropic.com", token: "sk-official"
        )
    }

    /// 注入式管理器：按需预置「已在聚合 + 名单」的栈（真实 stack store 走临时文件）。
    /// 每个管理器独立子目录——同一测试里的多个管理器不得共享 stack.json。
    private func makeManager(inAggregation: Bool, defaultID: String, members: [String]) -> ProviderAggregationManager {
        let root = tmpDir.appendingPathComponent("m-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stackURL = root.appendingPathComponent("stack.json")
        if inAggregation {
            let keys = Dictionary(uniqueKeysWithValues: members.map { ($0, $0) })
            try? AggregationStackStore(stackURL: stackURL).save(
                AggregationStack(claudeCode: .init(enabled: true, members: members, keys: keys))
            )
        }
        return ProviderAggregationManager(
            profileStore: StubProfileStore(),
            backupStore: StubBackupStore(),
            stackStore: AggregationStackStore(stackURL: stackURL),
            pendingStore: AggregationPendingStore(pendingURL: root.appendingPathComponent("pending.json")),
            loginStashStore: StubLoginStashStore(),
            staleDetector: StubStaleDetector(),
            proxy: StubProxy(),
            claudeWriter: StubClaudeWriter(),
            codexWriter: StubCodexWriter(),
            profiles: [kimiProfile, glmProfile, officialProfile]
        )
    }

    /// 切换管理器：真实 store 全走临时 home（空目录 → 空名单，面板只用它解析名字）。
    private func makeSwitchManager() -> ProviderSwitchManager {
        ProviderSwitchManager.production(
            homePath: tmpDir.path,
            environment: [:],
            applicationSupportRoot: tmpDir
        )
    }

    private func makeView() throws -> AggregationPanelView {
        AggregationPanelView(
            manager: makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi"]),
            switchManager: makeSwitchManager(),
            tool: .claudeCode,
            strings: .zhHans
        )
    }

    // MARK: - tests

    func test_modeSegmentRow_existsAndOffersBothModes() throws {
        let view = try makeView()
        XCTAssertEqual(view.strings.providerModeDirect, "直连")
        XCTAssertEqual(view.strings.providerModeAggregation, "聚合")
    }

    func test_defaultMemberCardHasNoRemoveButton() throws {
        let manager = makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi", "glm"])
        let view = AggregationPanelView(manager: manager, switchManager: makeSwitchManager(), tool: .claudeCode, strings: .zhHans)
        XCTAssertFalse(view.showsRemoveButton(for: "kimi"))
        XCTAssertTrue(view.showsRemoveButton(for: "glm"))
    }

    func test_officialProfileIsNotOfferedForJoining() throws {
        let manager = makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi"])
        let offered = AggregationPanelView(manager: manager, switchManager: makeSwitchManager(), tool: .claudeCode,
                                           strings: .zhHans).joinableProfileIDs(manager: manager)
        XCTAssertFalse(offered.contains("anthropic-official"))
        XCTAssertTrue(offered.contains("glm"))
    }

    // MARK: 直连互斥（SPEC 6.10）：聚合生效时直连「连接」必须禁用，防两个写者互相覆盖
    func test_directActionsAreDisabledWhileToolAggregates() throws {
        let aggregating = makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi"])
        XCTAssertTrue(AggregationPanelView(manager: aggregating, switchManager: makeSwitchManager(),
                                           tool: .claudeCode, strings: .zhHans).directActionsDisabled)
        let exited = makeManager(inAggregation: false, defaultID: "kimi", members: ["kimi"])
        XCTAssertFalse(AggregationPanelView(manager: exited, switchManager: makeSwitchManager(),
                                            tool: .claudeCode, strings: .zhHans).directActionsDisabled)
    }

    func test_localization_presentInBothLanguages() {
        for strings in [Strings.en, Strings.zhHans] {
            XCTAssertFalse(strings.providerModeDirect.isEmpty)
            XCTAssertFalse(strings.providerModeAggregation.isEmpty)
            XCTAssertFalse(strings.providerAggregationStatusLead.isEmpty)
            XCTAssertFalse(strings.providerAggregationEnter.isEmpty)
            XCTAssertFalse(strings.providerAggregationExit.isEmpty)
            XCTAssertFalse(strings.providerAggregationOfficialReason.isEmpty)
            XCTAssertFalse(strings.providerAggregationCacheHint.isEmpty)
            XCTAssertFalse(strings.providerMissStackOff.isEmpty)
            XCTAssertFalse(strings.providerMissUnknown.isEmpty)
            XCTAssertFalse(strings.providerMissRemoved.isEmpty)
            XCTAssertFalse(strings.providerMissDeleted.isEmpty)
        }
    }
}

// MARK: - Stubs（各测试文件自建）

private final class StubProxy: AggregationProxying {
    var isRunning = false
    var resolvedPort: UInt16?
    var onUnexpectedStop: (() -> Void)?
    func start() throws {
        isRunning = true
        resolvedPort = 15721
    }
    func stop() {
        isRunning = false
        resolvedPort = nil
    }
}

private final class StubProfileStore: ProviderProfileStoring {
    func list(for tool: ProviderTool) -> [ProviderProfile] { [] }
    func upsert(_ profile: ProviderProfile) throws {}
    func delete(_ profile: ProviderProfile) throws {}
    func adopt(name: String, tool: ProviderTool, baseURL: String, token: String, modelOverride: String?) throws -> ProviderProfile {
        ProviderProfile(id: "", name: name, tool: tool, baseURL: baseURL, token: token, modelOverride: modelOverride)
    }
}

private final class StubBackupStore: ProviderBackupStoring {
    private var backups: [ProviderTool: [ProviderBackup]] = [:]
    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
        let backup = ProviderBackup(id: "stub-\(UUID().uuidString)", tool: tool, date: Date())
        backups[tool, default: []].insert(backup, at: 0)
        return backup
    }
    func list(tool: ProviderTool) -> [ProviderBackup] { backups[tool] ?? [] }
    func content(of backup: ProviderBackup) throws -> String { "" }
    func restore(_ backup: ProviderBackup, to configURL: URL) throws {}
}

private final class StubLoginStashStore: CodexLoginStashStoring {
    var hasNativeLogin = false
    func stash() throws -> Bool { false }
    func restore() throws -> Bool { false }
    func discard() throws {}
}

private final class StubStaleDetector: CodexStaleClientDetecting {
    func observe(catalogURL: URL, catalogIsOurs: Bool) {}
    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? { nil }
}

private final class StubClaudeWriter: AggregationClaudeConfigWriting {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) -> String { "" }
}

private final class StubCodexWriter: AggregationCodexConfigWriting {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) -> String { "" }
}
