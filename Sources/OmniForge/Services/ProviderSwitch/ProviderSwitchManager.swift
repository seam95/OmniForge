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
}

/// 供应商切换编排管理器 — 串联配置读写 / 备份回滚 / profile 管理 / 进程检测。
@MainActor
final class ProviderSwitchManager: ObservableObject {
    @Published private(set) var profiles: [ProviderProfile] = []
    /// 每工具的激活态（未读取到时默认 official）。
    @Published private(set) var activeByTool: [ProviderTool: ActiveProvider] = [:]
    /// 全部工具的历史快照（最新在前）。
    @Published private(set) var backups: [ProviderBackup] = []

    private let claudeStore: ClaudeSettingsStoring
    private let codexStore: CodexConfigStoring
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
        processDetector: RunningProcessDetecting = RunningProcessDetector(),
        fileManager: FileManager = .default,
        configFileEditor: ConfigFileEditing? = nil
    ) {
        self.claudeStore = claudeStore
        self.codexStore = codexStore
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
        return ProviderSwitchManager(
            claudeStore: ClaudeSettingsStore(settingsURL: settingsURL),
            codexStore: CodexConfigStore(configURL: configURL),
            backupStore: backupStore,
            profileStore: ProviderProfileStore(
                claudeProfileDirectory: claudeProfiles,
                codexProfileDirectory: codexProfiles
            ),
            claudeConfigURL: settingsURL,
            codexConfigURL: configURL,
            processDetector: processDetector,
            configFileEditor: ConfigFileEditorStore(
                claudeConfigURL: settingsURL,
                codexConfigURL: configURL,
                backupStore: backupStore
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
        }
    }

    // MARK: - 刷新

    /// 重读 profile 目录、配置文件激活态与备份列表。
    func refresh() {
        profiles = ProviderTool.allCases.flatMap { profileStore.list(for: $0) }
        for tool in ProviderTool.allCases {
            activeByTool[tool] = detectActive(tool: tool)
        }
        backups = ProviderTool.allCases
            .flatMap { backupStore.list(tool: $0) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    // MARK: - 切换（字段所有权合并 + 快照 + 失败回滚）

    /// 设为激活：快照 → 合并写入 → 失败自动回滚 → 刷新。
    @discardableResult
    func switchTo(profile: ProviderProfile) throws -> ProviderSwitchOutcome {
        let tool = profile.tool
        let backup = try snapshot(tool: tool)
        do {
            switch tool {
            case .claudeCode: try claudeStore.applyProfile(profile)
            case .codex: try codexStore.applyProfile(profile)
            }
        } catch {
            try rollbackOrThrow(backup, tool: tool)
            throw error
        }
        refresh()
        return ProviderSwitchOutcome(tool: tool, target: .profile(name: profile.name), cliRunning: processDetector.isRunning(tool: tool))
    }

    /// 切到官方：快照 → 删除 override → 失败自动回滚 → 刷新。
    @discardableResult
    func switchToOfficial(tool: ProviderTool) throws -> ProviderSwitchOutcome {
        let backup = try snapshot(tool: tool)
        do {
            switch tool {
            case .claudeCode: try claudeStore.clearOverrides()
            case .codex: try codexStore.clearOverrides()
            }
        } catch {
            try rollbackOrThrow(backup, tool: tool)
            throw error
        }
        refresh()
        return ProviderSwitchOutcome(tool: tool, target: .official, cliRunning: processDetector.isRunning(tool: tool))
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
            let (_, base, tokenValue) = try codexStore.readActiveProvider()
            baseURL = base ?? ""
            token = tokenValue ?? ""
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
    func restoreBackup(_ backup: ProviderBackup) throws {
        try backupStore.restore(backup, to: configURL(for: backup.tool))
        refresh()
    }

    // MARK: - 损坏配置重建（SPEC 2.8.2）

    /// 损坏配置「备份并重建」：坏文件复制到备份目录后移除，回到无 override 状态
    /// （下次切换会创建最小配置文件）。不硬写损坏文件。
    func rebuildCorruptedConfig(tool: ProviderTool) throws {
        let url = configURL(for: tool)
        guard fileManager.fileExists(atPath: url.path) else { return }
        _ = try backupStore.snapshot(tool: tool, of: url)
        try fileManager.removeItem(at: url)
        refresh()
    }

    // MARK: - private

    /// 快照失败直接抛（不进入写入）。
    private func snapshot(tool: ProviderTool) throws -> ProviderBackup {
        try backupStore.snapshot(tool: tool, of: configURL(for: tool))
    }

    /// 写入失败 → 自动从快照回滚；回滚也失败则抛 rollbackFailed。
    private func rollbackOrThrow(_ backup: ProviderBackup, tool: ProviderTool) throws {
        do {
            try backupStore.restore(backup, to: configURL(for: tool))
        } catch {
            throw ProviderSwitchManagerError.rollbackFailed(tool: tool)
        }
    }

    /// 激活态识别：按 base URL（Claude）/ provider 键（Codex）匹配 profile（SPEC 2.6）。
    private func detectActive(tool: ProviderTool) -> ActiveProvider {
        switch tool {
        case .claudeCode:
            guard let env = try? claudeStore.readEnv() else {
                return .unreadable // JSON 损坏 → 备份并重建提示（SPEC 2.8.2）
            }
            guard let baseURL = env["ANTHROPIC_BASE_URL"], !baseURL.isEmpty else {
                return .official
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
            if let profile = profiles.first(where: { $0.tool == .codex && $0.profileKey == key }) {
                return .profile(profileID: profile.id)
            }
            if ProviderTool.codexBuiltInProviderKeys.contains(key) {
                return .official // codex login 自带配置
            }
            return .unmanaged(summary: active.baseURL ?? key)
        }
    }
}
