import Foundation

/// 供应商切换相关路径解析 — 纯函数，可单测。
/// 尊重 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 环境覆盖（对齐 resolveKimiHome / resolveCodexHome）。
enum ProviderSwitchPaths {
    // MARK: - Claude Code

    /// Claude 配置目录：`CLAUDE_CONFIG_DIR` 显式优先，否则 `~/.claude`。
    static func claudeConfigDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: homePath).appendingPathComponent(".claude", isDirectory: true)
    }

    /// Claude Code 配置文件：`settings.json`。
    static func claudeSettingsURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        claudeConfigDirectory(homePath: homePath, environment: environment)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Claude profile 目录：`providers/`（CCQ 兼容路径，SPEC 2.4）。
    static func claudeProfileDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        claudeConfigDirectory(homePath: homePath, environment: environment)
            .appendingPathComponent("providers", isDirectory: true)
    }

    // MARK: - Codex

    /// Codex home：`CODEX_HOME` 显式优先，否则 `~/.codex`（对齐 CodexAuthFileCredentialReader）。
    static func codexHome(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: homePath).appendingPathComponent(".codex", isDirectory: true)
    }

    /// Codex 配置文件：`config.toml`。
    static func codexConfigURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        codexHome(homePath: homePath, environment: environment)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Codex profile 目录 = home 根（profile 文件直接落在 `~/.codex/<key>.config.toml`）。
    static func codexProfileDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        codexHome(homePath: homePath, environment: environment)
    }

    // MARK: - 统一入口

    /// 目标工具配置文件 URL。
    static func configURL(
        for tool: ProviderTool,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch tool {
        case .claudeCode:
            return claudeSettingsURL(homePath: homePath, environment: environment)
        case .codex:
            return codexConfigURL(homePath: homePath, environment: environment)
        }
    }

    /// 目标工具的 profile 目录。
    static func profileDirectory(
        for tool: ProviderTool,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch tool {
        case .claudeCode:
            return claudeProfileDirectory(homePath: homePath, environment: environment)
        case .codex:
            return codexProfileDirectory(homePath: homePath, environment: environment)
        }
    }

    // MARK: - 备份

    /// 切换前快照目录：`<App Support>/ProviderSwitchBackups`（SPEC 2.5）。
    static func backupDirectory(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot.appendingPathComponent("ProviderSwitchBackups", isDirectory: true)
    }
}
