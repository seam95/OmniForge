import Combine
import Foundation

/// 切换目标 — UI 据此展示结果文案。
enum ProviderSwitchTarget: Equatable {
    case official
    case profile(name: String)
}

/// 一次切换的结果（SPEC 2.7：写完即完成；不主动杀进程，提示用户重启 CLI）。
struct ProviderSwitchOutcome: Equatable {
    let tool: ProviderTool
    let target: ProviderSwitchTarget
    /// 检测到对应 CLI 正在运行时为 true → 额外提示「需重启才生效」。
    let cliRunning: Bool
}

/// 编排层错误。
enum ProviderSwitchManagerError: Error, Equatable {
    /// 未托管配置缺 base URL / 凭证，无法收编。
    case missingUnmanagedValues(tool: ProviderTool)
    /// 写入失败后自动回滚也失败（快照无法恢复）。
    case rollbackFailed(tool: ProviderTool)
    /// 目标工具的切换能力尚未装配（C1 编译占位，Desktop 在 C2 落地）。
    case unsupportedTool(tool: ProviderTool)
}

/// 供应商切换编排管理器 — 串联配置读写 / 备份回滚 / profile 管理 / 进程检测。
@MainActor
final class ProviderSwitchManager: ObservableObject, ProviderActivationRefreshing {
    @Published private(set) var profiles: [ProviderProfile] = []
    /// 每工具的激活态（未读取到时默认 official）。
    @Published private(set) var activeByTool: [ProviderTool: ActiveProvider] = [:]
    /// 全部工具的历史快照（最新在前）。
    @Published private(set) var backups: [ProviderBackup] = []

    private let claudeStore: ClaudeSettingsStoring
    private let codexStore: CodexConfigStoring
    private let desktopStore: ClaudeDesktopSettingsStoring?
    private let desktopBackupStore: ClaudeDesktopBackupStoring?
    private let backupStore: ProviderBackupStoring
    private let profileStore: ProviderProfileStoring
    private let claudeConfigURL: URL
    private let codexConfigURL: URL
    private let processDetector: RunningProcessDetecting
    private let fileManager: FileManager
    /// 配置文件原文编辑器（进阶出口，SPEC 2.10）；测试可省略。
    private(set) var configFileEditor: ConfigFileEditing?

    init(
        claudeStore: ClaudeSettingsStoring,
        codexStore: CodexConfigStoring,
        backupStore: ProviderBackupStoring,
        profileStore: ProviderProfileStoring,
        claudeConfigURL: URL,
        codexConfigURL: URL,
        desktopStore: ClaudeDesktopSettingsStoring? = nil,
        desktopBackupStore: ClaudeDesktopBackupStoring? = nil,
        processDetector: RunningProcessDetecting = RunningProcessDetector(),
        fileManager: FileManager = .default,
        configFileEditor: ConfigFileEditing? = nil
    ) {
        self.claudeStore = claudeStore
        self.codexStore = codexStore
        self.desktopStore = desktopStore
        self.desktopBackupStore = desktopBackupStore
        self.backupStore = backupStore
        self.profileStore = profileStore
        self.claudeConfigURL = claudeConfigURL
        self.codexConfigURL = codexConfigURL
        self.processDetector = processDetector
        self.fileManager = fileManager
        self.configFileEditor = configFileEditor
        refresh()
    }

    /// 生产装配：默认 home / 环境 / App Support（`app.omniforge/ProviderSwitchBackups`）。
    static func production(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportRoot: URL? = nil,
        processDetector: RunningProcessDetecting = RunningProcessDetector()
    ) -> ProviderSwitchManager {
        let settingsURL = ProviderSwitchPaths.claudeSettingsURL(homePath: homePath, environment: environment)
        let configURL = ProviderSwitchPaths.codexConfigURL(homePath: homePath, environment: environment)
        let claudeProfiles = ProviderSwitchPaths.claudeProfileDirectory(homePath: homePath, environment: environment)
        let codexProfiles = ProviderSwitchPaths.codexProfileDirectory(homePath: homePath, environment: environment)
        let root = applicationSupportRoot
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("app.omniforge", isDirectory: true))
            ?? FileManager.default.temporaryDirectory
        let backupStore = ProviderBackupStore(
            backupDirectory: ProviderSwitchPaths.backupDirectory(applicationSupportRoot: root)
        )
        let desktopStore = ClaudeDesktopSettingsStore.production(
            homePath: homePath,
            applicationSupportRoot: root
        )
        let desktopBackupStore = ClaudeDesktopBackupStore.production(
            homePath: homePath,
            applicationSupportRoot: root
        )
        return ProviderSwitchManager(
            claudeStore: ClaudeSettingsStore(settingsURL: settingsURL),
            codexStore: CodexConfigStore(configURL: configURL),
            backupStore: backupStore,
            profileStore: ProviderProfileStore(
                profileDirectories: [
                    .claudeCode: claudeProfiles,
                    .codex: codexProfiles,
                    .claudeDesktop: ProviderSwitchPaths.desktopProfileDirectory(applicationSupportRoot: root),
                ]
            ),
            claudeConfigURL: settingsURL,
            codexConfigURL: configURL,
            desktopStore: desktopStore,
            desktopBackupStore: desktopBackupStore,
            processDetector: processDetector,
            configFileEditor: ConfigFileEditorStore(
                claudeConfigURL: settingsURL,
                codexConfigURL: configURL,
                backupStore: backupStore,
                desktopBackupStore: desktopBackupStore
            )
        )
    }

    // MARK: - 查询

    func active(tool: ProviderTool) -> ActiveProvider {
        activeByTool[tool] ?? .official
    }

    func profiles(for tool: ProviderTool) -> [ProviderProfile] {
        profiles.filter { $0.tool == tool }
    }

    private func configURL(for tool: ProviderTool) -> URL {
        switch tool {
        case .claudeCode: return claudeConfigURL
        case .codex: return codexConfigURL
        case .claudeDesktop: return ProviderSwitchPaths.claudeDesktopConfigURL()
        }
    }

    // MARK: - 刷新

    /// 重读 profile 目录、配置文件激活态与备份列表。
    /// Desktop 先按 pending 前滚（4 文件事务自愈，SPEC 关键设计决策 2）。
    func refresh() {
        if let desktopStore {
            try? desktopStore.replayPendingIfPresent()
        }
        profiles = ProviderTool.allCases.flatMap { profileStore.list(for: $0) }
        for tool in ProviderTool.allCases {
            activeByTool[tool] = detectActive(tool: tool)
        }
        backups = ProviderTool.allCases
            .flatMap { tool in
                // 备份分派：Desktop 走 bundle 快照，其余走单文件快照。
                tool == .claudeDesktop ? (desktopBackupStore?.list(tool: tool) ?? []) : backupStore.list(tool: tool)
            }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// 聚合模式切换成功后由聚合管理器驱动：激活态是纯内存缓存，不重算就会停留在
    /// 切换前的值（退出聚合恢复文件后界面显示旧态的根因）。
    func refreshActivationState() {
        refresh()
    }

    // MARK: - 切换（字段所有权合并 + 快照 + 失败回滚）

    /// 设为激活：快照 → 合并写入 → 失败自动回滚 → 刷新。
    /// CLI 运行检测经有界进程边界异步执行，不再阻塞主线程。
    @discardableResult
    func switchTo(profile: ProviderProfile) async throws -> ProviderSwitchOutcome {
        let tool = profile.tool
        let backup = try snapshot(tool: tool)
        do {
            switch tool {
            case .claudeCode: try claudeStore.applyProfile(profile)
            case .codex: try codexStore.applyProfile(profile)
            case .claudeDesktop:
                guard let desktopStore else {
                    throw ProviderSwitchManagerError.unsupportedTool(tool: tool)
                }
                // 直连形态：不带 inferenceModels（Desktop 自动发现）。
                try desktopStore.applyProfile(profile, inferenceModels: nil, modelDiscoveryEnabled: nil)
            }
        } catch {
            try rollbackOrThrow(backup, tool: tool)
            throw error
        }
        refresh()
        return ProviderSwitchOutcome(tool: tool, target: .profile(name: profile.name), cliRunning: await processDetector.isRunning(tool: tool))
    }

    /// 切到官方：快照 → 删除 override → 失败自动回滚 → 刷新。
    @discardableResult
    func switchToOfficial(tool: ProviderTool) async throws -> ProviderSwitchOutcome {
        let backup = try snapshot(tool: tool)
        do {
            switch tool {
            case .claudeCode: try claudeStore.clearOverrides()
            case .codex: try codexStore.clearOverrides()
            case .claudeDesktop:
                guard let desktopStore else {
                    throw ProviderSwitchManagerError.unsupportedTool(tool: tool)
                }
                try desktopStore.restoreOfficial()
            }
        } catch {
            try rollbackOrThrow(backup, tool: tool)
            throw error
        }
        refresh()
        return ProviderSwitchOutcome(tool: tool, target: .official, cliRunning: await processDetector.isRunning(tool: tool))
    }

    // MARK: - profile 管理

    func upsertProfile(_ profile: ProviderProfile) throws {
        try profileStore.upsert(profile)
        refresh()
    }

    func deleteProfile(_ profile: ProviderProfile) throws {
        try profileStore.delete(profile)
        refresh()
    }

    /// 收编未托管配置为 profile（SPEC 2.6）：从目标配置文件读取 base URL + 凭证 → 落盘。
    func adoptUnmanaged(tool: ProviderTool, name: String) throws -> ProviderProfile {
        let (baseURL, token): (String, String)
        switch tool {
        case .claudeCode:
            let env = try claudeStore.readEnv()
            baseURL = env["ANTHROPIC_BASE_URL"] ?? ""
            token = env["ANTHROPIC_AUTH_TOKEN"] ?? ""
        case .codex:
            let (_, base, tokenValue, _) = try codexStore.readActiveProvider()
            baseURL = base ?? ""
            token = tokenValue ?? ""
        case .claudeDesktop:
            // 收编未托管网关：读当前 applied profile 的网关地址与密钥。
            guard let desktopStore, let state = try? desktopStore.readState() else {
                throw ProviderSwitchManagerError.unsupportedTool(tool: tool)
            }
            baseURL = state.inferenceGatewayBaseUrl ?? ""
            token = state.inferenceGatewayApiKey ?? ""
        }
        guard !baseURL.isEmpty, !token.isEmpty else {
            throw ProviderSwitchManagerError.missingUnmanagedValues(tool: tool)
        }
        let profile = try profileStore.adopt(
            name: name,
            tool: tool,
            baseURL: baseURL,
            token: token,
            modelOverride: nil
        )
        refresh()
        return profile
    }

    // MARK: - 备份恢复

    /// 手动恢复备份：快照内容原子写回目标配置文件（SPEC 2.5）。
    /// Desktop 走 bundle 恢复（absent 文件删除，其余写回 4 个固定路径）。
    func restoreBackup(_ backup: ProviderBackup) throws {
        if backup.tool == .claudeDesktop {
            guard let desktopBackupStore else {
                throw ProviderSwitchManagerError.unsupportedTool(tool: .claudeDesktop)
            }
            try desktopBackupStore.restore(backup)
        } else {
            try backupStore.restore(backup, to: configURL(for: backup.tool))
        }
        refresh()
    }

    /// 读取某份备份的内容，供用户在恢复前核对（只读，不改动任何状态）。
    func backupContent(_ backup: ProviderBackup) throws -> String {
        if backup.tool == .claudeDesktop, let desktopBackupStore {
            return try desktopBackupStore.content(of: backup)
        }
        return try backupStore.content(of: backup)
    }

    // MARK: - 损坏配置重建（SPEC 2.8.2）

    /// 损坏配置「备份并重建」：坏文件复制到备份目录后移除，回到无 override 状态
    /// （下次切换会创建最小配置文件）。不硬写损坏文件。
    /// Desktop 的备份走 bundle（4 文件一并快照，恢复入口同源）。
    func rebuildCorruptedConfig(tool: ProviderTool) throws {
        let url = configURL(for: tool)
        guard fileManager.fileExists(atPath: url.path) else { return }
        if tool == .claudeDesktop, let desktopBackupStore {
            _ = try desktopBackupStore.snapshot4Files()
        } else {
            _ = try backupStore.snapshot(tool: tool, of: url)
        }
        try fileManager.removeItem(at: url)
        refresh()
    }

    // MARK: - private

    /// 快照失败直接抛（不进入写入）。
    /// Desktop 走 bundle 快照（源文件缺失记 absent，首次切换不失败）。
    private func snapshot(tool: ProviderTool) throws -> ProviderBackup {
        if tool == .claudeDesktop {
            guard let desktopBackupStore else {
                throw ProviderSwitchManagerError.unsupportedTool(tool: tool)
            }
            return try desktopBackupStore.snapshot4Files()
        }
        return try backupStore.snapshot(tool: tool, of: configURL(for: tool))
    }

    /// 写入失败 → 自动从快照回滚；回滚也失败则抛 rollbackFailed。
    /// Desktop 回滚成功后必须丢弃 pending：残留的 pending 会在下一次 refresh 被
    /// 重放落盘，把刚回滚掉的失败事务静默完成（回滚结果必须胜利）。
    private func rollbackOrThrow(_ backup: ProviderBackup, tool: ProviderTool) throws {
        do {
            if tool == .claudeDesktop {
                guard let desktopBackupStore else {
                    throw ProviderSwitchManagerError.unsupportedTool(tool: tool)
                }
                try desktopBackupStore.restore(backup)
                try? desktopStore?.discardPending()
            } else {
                try backupStore.restore(backup, to: configURL(for: tool))
            }
        } catch {
            throw ProviderSwitchManagerError.rollbackFailed(tool: tool)
        }
    }

    /// 激活态识别：按 base URL（Claude）/ provider 键（Codex）匹配 profile（SPEC 2.6）。
    /// 聚合投影（回环地址 + 占位凭证）优先判为「聚合接管中」——它是聚合功能的自有投影，
    /// 按未托管处理会把代理地址锁进缓存，退出聚合恢复文件后横幅仍残留。
    private func detectActive(tool: ProviderTool) -> ActiveProvider {
        switch tool {
        case .claudeCode:
            guard let env = try? claudeStore.readEnv() else {
                return .unreadable // JSON 损坏 → 备份并重建提示（SPEC 2.8.2）
            }
            guard let baseURL = env["ANTHROPIC_BASE_URL"], !baseURL.isEmpty else {
                return .official
            }
            if AggregationProjectionSignature.isProjectedBaseURL(baseURL),
               env["ANTHROPIC_AUTH_TOKEN"] == AggregationProjectionSignature.placeholderToken {
                return .aggregating
            }
            if let profile = profiles.first(where: { $0.tool == .claudeCode && $0.baseURL == baseURL }) {
                return .profile(profileID: profile.id)
            }
            return .unmanaged(summary: baseURL)

        case .codex:
            guard let active = try? codexStore.readActiveProvider() else {
                return .unreadable // TOML 损坏 → 备份并重建提示
            }
            guard let key = active.key, !key.isEmpty else {
                return .official
            }
            // 聚合投影识别（2026-10-19 401 修复后）：凭证形态随默认那家而变
            // （第三方写占位 token、官方只写 requires_openai_auth），不能拿凭证当判据；
            // 认「指向本机代理 + 指向聚合目录」这两条写入端独有的身份标记。
            // 漏认会把代理地址锁进激活态缓存，退出聚合恢复文件后仍显示「未托管配置」横幅。
            if let baseURL = active.baseURL,
               AggregationProjectionSignature.isProjectedBaseURL(baseURL),
               active.catalogFileName == ProviderSwitchPaths.codexAggregationCatalogFileName {
                return .aggregating
            }
            if let profile = profiles.first(where: { $0.tool == .codex && $0.profileKey == key }) {
                return .profile(profileID: profile.id)
            }
            if ProviderTool.codexBuiltInProviderKeys.contains(key) {
                return .official // codex login 自带配置
            }
            return .unmanaged(summary: active.baseURL ?? key)

        case .claudeDesktop:
            return detectDesktopActive()
        }
    }

    /// Desktop 激活态识别（SPEC 功能 B）：
    /// 1. `_meta.json` 缺失或 `appliedId` 非我们 → 存在其它 `appliedId` 或 `deploymentMode == "3p"`
    ///    → 未托管；否则官方。
    /// 2. `appliedId` 是我们 → 读 profile 的网关地址：命中某卡 → 该卡；命中本机代理投影 → 聚合接管；
    ///    其它 → 未托管。
    /// 3. 任一文件 JSON 损坏 → unreadable。
    private func detectDesktopActive() -> ActiveProvider {
        guard let desktopStore else { return .official }
        guard let state = try? desktopStore.readState() else {
            return .unreadable
        }
        if state.isOurProfileApplied {
            guard let baseURL = state.inferenceGatewayBaseUrl, !baseURL.isEmpty else {
                return .unmanaged(summary: "gateway (无网关地址)")
            }
            if AggregationProjectionSignature.isDesktopProjectedBaseURL(baseURL) {
                return .aggregating
            }
            if let profile = profiles.first(where: { $0.tool == .claudeDesktop && $0.baseURL == baseURL }) {
                return .profile(profileID: profile.id)
            }
            return .unmanaged(summary: baseURL)
        }
        if state.appliedId != nil {
            return .unmanaged(summary: state.appliedId ?? "")
        }
        if state.deploymentMode == "3p" {
            return .unmanaged(summary: "3p")
        }
        return .official
    }
}
