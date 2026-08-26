import Foundation

/// 目标配置文件读写错误（SPEC 2.8.2：损坏时不硬写）。
enum ProviderConfigFileError: Error, Equatable {
    /// 目标文件存在但 JSON/TOML 损坏 → 中止，提示「备份并重建」。
    case corrupted(path: String)
    /// 原子写失败。
    case writeFailed(path: String)
}

/// Claude Code `settings.json` 的 `env` 读写边界 — 字段所有权合并（SPEC 2.3）。
protocol ClaudeSettingsStoring: AnyObject {
    /// 当前 `env` 对象（文件缺失 → 空；损坏 → 抛 corrupted）。
    func readEnv() throws -> [String: String]
    /// 字段所有权合并：只更新/删除 `env` 内拥有键（`ANTHROPIC_*`），其余键一律不动。
    /// 模型覆盖键仅在 profile 指定时写；profile 无覆盖时删除旧模型覆盖键。
    func applyProfile(_ profile: ProviderProfile) throws
    /// 切 Official：删除全部拥有键；`env` 清空后整体移除。
    func clearOverrides() throws
}

/// `~/.claude/settings.json` 读写实现。
final class ClaudeSettingsStore: ClaudeSettingsStoring {
    let settingsURL: URL
    let fileManager: FileManager

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    func readEnv() throws -> [String: String] {
        guard let root = try readRoot() else { return [:] }
        let env = root["env"] as? [String: Any] ?? [:]
        return env.compactMapValues { $0 as? String }
    }

    func applyProfile(_ profile: ProviderProfile) throws {
        var root = (try readRoot()) ?? [:]
        var env = (root["env"] as? [String: Any]) ?? [:]

        env["ANTHROPIC_AUTH_TOKEN"] = profile.token
        env["ANTHROPIC_BASE_URL"] = profile.baseURL
        if let model = profile.modelOverride, !model.isEmpty {
            env["ANTHROPIC_MODEL"] = model
            if let small = profile.smallFastModelOverride, !small.isEmpty {
                env["ANTHROPIC_SMALL_FAST_MODEL"] = small
            } else {
                env.removeValue(forKey: "ANTHROPIC_SMALL_FAST_MODEL")
            }
        } else {
            env.removeValue(forKey: "ANTHROPIC_MODEL")
            env.removeValue(forKey: "ANTHROPIC_SMALL_FAST_MODEL")
        }

        root["env"] = env
        try writeRoot(root)
    }

    func clearOverrides() throws {
        guard var root = try readRoot() else { return } // 缺失 → 无事可做
        guard var env = root["env"] as? [String: Any] else { return } // 无 env → 无 override
        for key in ProviderTool.claudeOwnedEnvKeys {
            env.removeValue(forKey: key)
        }
        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }
        try writeRoot(root)
    }

    // MARK: - private

    /// 读取根对象；文件缺失 → nil；存在但非 JSON 对象 → 抛 corrupted。
    private func readRoot() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return nil }
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderConfigFileError.corrupted(path: settingsURL.path)
        }
        return root
    }

    private func writeRoot(_ root: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw ProviderConfigFileError.writeFailed(path: settingsURL.path)
        }
        do {
            try AtomicFileWriter.write(data, to: settingsURL, fileManager: fileManager)
        } catch {
            throw ProviderConfigFileError.writeFailed(path: settingsURL.path)
        }
    }
}
