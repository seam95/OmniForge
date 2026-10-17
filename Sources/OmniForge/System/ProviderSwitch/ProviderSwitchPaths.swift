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

    /// Codex 桌面端自定义模型目录文件名。
    static let codexModelCatalogFileName = "omniforge-model-catalog.json"

    /// Codex 桌面端自定义模型目录路径：`~/.codex/omniforge-model-catalog.json`。
    static func codexModelCatalogURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        codexHome(homePath: homePath, environment: environment)
            .appendingPathComponent(codexModelCatalogFileName, isDirectory: false)
    }

    /// Codex 聚合模式模型目录文件名（`config.toml` 的 `model_catalog_json` 键按此名引用；
    /// Codex 只认路径不认文件名）。
    static let codexAggregationCatalogFileName = "omniforge-stack-catalog.json"

    /// Codex 聚合模式模型目录路径：`~/.codex/omniforge-stack-catalog.json`。
    /// 与直连模式的 `omniforge-model-catalog.json` 是两份文件，互不覆盖。
    static func codexAggregationCatalogURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        codexHome(homePath: homePath, environment: environment)
            .appendingPathComponent(codexAggregationCatalogFileName, isDirectory: false)
    }

    /// 旧版聚合目录文件名（对齐 cc-switch 时期）——投影时顺带删除自愈，勿再写入。
    static let legacyCodexAggregationCatalogFileName = "cc-switch-model-catalog.json"

    /// Codex 官方模型目录缓存文件名（Codex 自己维护，聚合官方行唯一来源）。
    static let codexModelsCacheFileName = "models_cache.json"

    /// Codex 官方模型目录缓存路径：`~/.codex/models_cache.json`。
    static func codexModelsCacheURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        codexHome(homePath: homePath, environment: environment)
            .appendingPathComponent(codexModelsCacheFileName, isDirectory: false)
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
