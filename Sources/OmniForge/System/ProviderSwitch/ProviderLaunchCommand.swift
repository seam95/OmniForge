import Foundation

/// 为指定供应商档案生成可直接粘贴到终端的 CLI 启动命令。
///
/// 该类型只负责命令文本格式化，不启动进程，也不修改任何 CLI 配置。
enum ProviderLaunchCommand {
    /// 生成 CCQ 兼容的 Claude Code / Codex 启动命令。
    ///
    /// `id` 是 profile 文件的实际 key；只有构造临时 profile 且 id 为空时才回退到名称 slug。
    static func make(
        for profile: ProviderProfile,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let profileKey = profile.id.isEmpty ? profile.profileKey : profile.id

        switch profile.tool {
        case .claudeCode:
            let directory = ProviderSwitchPaths.claudeProfileDirectory(
                homePath: homePath,
                environment: environment
            )
            let fileName = ProviderProfileStore.fileName(for: .claudeCode, key: profileKey)
            let path = directory.appendingPathComponent(fileName).path
            return "claude --settings \(shellArgument(path, homePath: homePath))"

        case .codex:
            return "codex --profile \(shellArgument(profileKey))"
        }
    }

    // MARK: - Shell 格式化

    /// 将用户目录缩写为 `~`，同时保留自定义配置目录的实际路径。
    private static func displayPath(_ path: String, homePath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedHome = URL(fileURLWithPath: homePath).standardizedFileURL.path

        if standardizedPath == standardizedHome {
            return "~"
        }

        let homePrefix = standardizedHome == "/" ? "/" : "\(standardizedHome)/"
        guard standardizedPath.hasPrefix(homePrefix) else {
            return standardizedPath
        }
        return "~" + String(standardizedPath.dropFirst(standardizedHome.count))
    }

    /// 对命令参数做最小必要的 shell 转义，避免档案 key / 路径中的特殊字符改变命令语义。
    private static func shellArgument(_ value: String, homePath: String? = nil) -> String {
        let displayValue = if let homePath {
            displayPath(value, homePath: homePath)
        } else {
            value
        }

        // 保持 `~` 位于未加引号的单词起始处，否则 shell 不会展开用户目录。
        if displayValue.hasPrefix("~/") {
            return "~/\(quoteIfNeeded(String(displayValue.dropFirst(2))))"
        }
        return quoteIfNeeded(displayValue)
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let safeCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-~"
        )
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) else {
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return value
    }
}
