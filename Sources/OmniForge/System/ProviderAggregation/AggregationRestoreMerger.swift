import Foundation

/// 退出聚合时的“拥有键”恢复 — 对齐 cc-switch 的键级回滚，而不是整份文件覆盖。
///
/// 聚合只拥有少数顶层键、`[model_providers.custom]` 表和 Claude 的若干 env 键。
/// 用户可能在聚合期间改了 MCP、项目配置或其他段落；整份快照恢复会把这些改动一起
/// 吞掉。这里只把聚合拥有的键恢复成进入前的值（缺失则删除），其余保持当前文件。
enum AggregationRestoreMerger {
    /// Codex `config.toml`：恢复聚合写过的顶层键与 custom 表，保留当前其他表和键。
    /// 备份 TOML 解析失败 → nil（调用方回退整份快照）。
    static func codex(currentText: String, backupText: String) -> String? {
        guard let backup = TOMLFile.parse(backupText) else { return nil }
        var merged = TOMLFile.parse(currentText) ?? TOMLFile()

        for key in AggregationCodexConfigWriter.writtenTopLevelKeys {
            if let literal = backup.rawValue(key: key, table: nil) {
                merged.setRawValue(literal, key: key, table: nil)
            } else {
                merged.remove(key: key, table: nil)
            }
        }

        let custom = ["model_providers", "custom"]
        if backup.hasEntries(in: custom) {
            // 进入聚合前用户自己有同名的 custom 表：整表恢复。
            merged.removeTable(path: custom)
            merged.ensureTable(path: custom)
            for entry in backup.entries where entry.tablePath == custom {
                if let literal = backup.rawValue(key: entry.key, table: custom) {
                    merged.setRawValue(literal, key: entry.key, table: custom)
                }
            }
        } else if AggregationCodexConfigWriter.customTablePointsAtProxy(merged) {
            // 进入前没有 custom 表：只摘掉聚合指向本机代理的那张，用户自建的同名表保留。
            merged.removeTable(path: custom)
        }

        merged.normalizeBlankLines()
        return merged.serialize()
    }

    /// Claude `settings.json`：恢复聚合拥有的 env 键与顶层 `modelPicker`，
    /// 保留用户在聚合期间新增的其他键和环境变量。
    static func claude(current: [String: Any], backup: [String: Any]) -> [String: Any] {
        var merged = current
        let backupEnv = backup["env"] as? [String: Any] ?? [:]
        var env = merged["env"] as? [String: Any] ?? [:]

        for key in ProviderTool.claudeOwnedEnvKeys {
            if let value = backupEnv[key] {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }
        if env.isEmpty {
            merged.removeValue(forKey: "env")
        } else {
            merged["env"] = env
        }

        for key in ProviderTool.claudeOwnedTopLevelKeys {
            if let value = backup[key] {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        return merged
    }
}
