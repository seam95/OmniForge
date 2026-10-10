import Foundation

/// Claude Code 聚合配置写入边界。
protocol AggregationClaudeConfigWriting: AnyObject {
    func applyAggregation(defaultProfile: ProviderProfile, published: [AggregationPublishedModel], port: UInt16) throws
    func clearAggregation() throws
}

/// `~/.claude/settings.json` 聚合投影：裸 origin 指向本机代理、占位凭证、
/// 四档别名共享首个 Stack id（haiku 剥 1M）、顶层 `modelPicker`、MAX 窗口取非 1M 最小值。
/// 只动拥有键，用户其余设置原样保留。
/// `defaultProfile` 参与协议对称（Codex 侧需要）——Claude 投影完全由 `published` 计算，
/// 默认供应商的职责在代理解析层（Task 11），配置文件里不出现。
final class AggregationClaudeConfigWriter: AggregationClaudeConfigWriting {
    let settingsURL: URL
    let fileManager: FileManager

    /// 占位凭证 — 代理按目标替换为真实凭证；客户端侧只见此值（对齐 cc-switch `PROXY_MANAGED`）。
    private static let placeholderToken = "PROXY_MANAGED"

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    func applyAggregation(defaultProfile: ProviderProfile, published: [AggregationPublishedModel], port: UInt16) throws {
        var root = (try SettingsJSONFile.readRoot(from: settingsURL, fileManager: fileManager)) ?? [:]
        var env = (root["env"] as? [String: Any]) ?? [:]

        // 只动拥有键：先清掉全部拥有 env 键（直连模式残留的模型/窗口键），再写聚合投影。
        for key in ProviderTool.claudeOwnedEnvKeys {
            env.removeValue(forKey: key)
        }

        // 代理裸 origin（无路径后缀）+ 占位凭证。
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        env["ANTHROPIC_AUTH_TOKEN"] = Self.placeholderToken

        // 四档别名共享同一个 Stack id；haiku 剥 1M（小模型档不吃 1M 窗口）。
        if let first = published.first {
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = first.id
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = first.id
            env["ANTHROPIC_DEFAULT_FABLE_MODEL"] = first.id
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = AggregationModelID.encode(
                tool: .claudeCode, key: first.key, model: first.model, oneM: false
            )
            env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] = first.displayName
            env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] = first.displayName
            env["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"] = first.displayName
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"] = first.displayName
        }

        // MAX 窗口 = 已发布非 1M 模型窗口最小值；恰为默认 200K 时不写（不额外约束客户端）。
        if let maxWindow = Self.maxContextTokens(published: published) {
            env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(maxWindow)
        }

        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }

        // modelPicker 是 settings.json **顶层**键（不是 env 内）——写错层级 Claude Code 完全看不到。
        root["modelPicker"] = [
            "replaceBuiltInOptions": true,
            "options": published.map { [
                "model": $0.id,
                "label": $0.label,
                "description": $0.description,
            ] },
        ]
        try SettingsJSONFile.writeRoot(root, to: settingsURL, fileManager: fileManager)
    }

    func clearAggregation() throws {
        guard var root = try SettingsJSONFile.readRoot(from: settingsURL, fileManager: fileManager) else { return }
        for key in ProviderTool.claudeOwnedTopLevelKeys {
            root.removeValue(forKey: key)
        }
        if var env = root["env"] as? [String: Any] {
            for key in ProviderTool.claudeOwnedEnvKeys {
                env.removeValue(forKey: key)
            }
            if env.isEmpty {
                root.removeValue(forKey: "env")
            } else {
                root["env"] = env
            }
        }
        try SettingsJSONFile.writeRoot(root, to: settingsURL, fileManager: fileManager)
    }

    // MARK: - private

    /// MAX 窗口规则：已发布**非 1M** 模型窗口最小值；无有效值或恰为默认 200K → nil（不写）。
    private static func maxContextTokens(published: [AggregationPublishedModel]) -> UInt64? {
        let windows = published
            .filter { !$0.oneM }
            .map(\.window)
            .filter { $0 > 0 }
        guard let minimum = windows.min() else { return nil }
        return minimum == AggregationModelPublisher.defaultWindow ? nil : minimum
    }
}
