import Foundation

/// Claude Code 聚合配置写入边界。
///
/// `memberSwitches`：成员兼容开关合并结果（`AggregationSwitchMerger`，ANY/ALL 两组语义）。
/// 投影先清掉全部拥有 env 键再写聚合键——少了这一步，每个成员自己配的兼容开关
/// （`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`、`ENABLE_TOOL_SEARCH`…）会被静默丢弃。
/// 该键参与协议对称（Codex 侧无对应开关），并同时进 `projectedContractDigest`——
/// 否则只改开关的投影变化对「未变更不重写」闸门不可见，重写会被悄悄跳过。
protocol AggregationClaudeConfigWriting: AnyObject {
    func applyAggregation(defaultProfile: ProviderProfile, published: [AggregationPublishedModel], port: UInt16, memberSwitches: [String: String]) throws
    func clearAggregation() throws
    /// 磁盘现状的契约摘要（供「未变更不重写」比对）。
    func currentContractDigest() -> String
    /// 给定投影的契约摘要（不落盘）。
    func projectedContractDigest(defaultProfile: ProviderProfile, published: [AggregationPublishedModel], port: UInt16, memberSwitches: [String: String]) -> String
}

/// `~/.claude/settings.json` 聚合投影：裸 origin 指向本机代理、占位凭证、
/// 四档别名共享首个 Stack id（1M 模型四档都带 `[1M]` 标记）、顶层 `modelPicker`、MAX 窗口取非 1M 最小值、
/// 拥有键清理后写入成员兼容开关合并结果（`memberSwitches`）。
/// **空发布**（用户主动清空 `stackModels`）时不写 `modelPicker`，四档别名回落默认那家直连口径。
/// 只动拥有键，用户其余设置原样保留。
/// `defaultProfile` 参与协议对称（Codex 侧需要）——非空发布的 Claude 投影完全由 `published` 计算；
/// 空发布时默认供应商的 `modelMapping`/`modelOverride`/`extraEnv` 才进配置文件（直连口径回落）。
final class AggregationClaudeConfigWriter: AggregationClaudeConfigWriting {
    let settingsURL: URL
    let fileManager: FileManager

    /// 占位凭证 — 代理按目标替换为真实凭证；客户端侧只见此值。
    /// 字面量与识别端（`ProviderSwitchManager.detectActive` 的聚合态判定）共用
    /// `AggregationProjectionSignature.placeholderToken`，两侧不得各写一份。

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String] = [:]
    ) throws {
        let root = projectedRoot(
            defaultProfile: defaultProfile, published: published, port: port, memberSwitches: memberSwitches
        )
        try SettingsJSONFile.writeRoot(root, to: settingsURL, fileManager: fileManager)
    }

    func currentContractDigest() -> String {
        let root = (try? SettingsJSONFile.readRoot(from: settingsURL, fileManager: fileManager)) ?? [:]
        return AggregationContractDigest.claude(projectedRoot: root)
    }

    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String] = [:]
    ) -> String {
        AggregationContractDigest.claude(
            projectedRoot: projectedRoot(
                defaultProfile: defaultProfile, published: published, port: port, memberSwitches: memberSwitches
            )
        )
    }

    /// 聚合投影（纯合并，不落盘）：当前 root 上合并拥有键与顶层 `modelPicker`。
    func projectedRoot(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String] = [:]
    ) -> [String: Any] {
        var root = (try? SettingsJSONFile.readRoot(from: settingsURL, fileManager: fileManager)) ?? [:]
        var env = (root["env"] as? [String: Any]) ?? [:]

        // 只动拥有键：先清掉全部拥有 env 键（直连模式残留的模型/窗口键），再写聚合投影。
        for key in ProviderTool.claudeOwnedEnvKeys {
            env.removeValue(forKey: key)
        }

        // 成员兼容开关合并结果在清理后写入（见 `AggregationSwitchMerger`）。
        // 空/非空发布两条路径都写：开关与发布内容正交（SPEC §2 无空发布豁免）。
        for (key, value) in memberSwitches {
            env[key] = value
        }

        // 代理裸 origin（无路径后缀）+ 占位凭证。
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        env["ANTHROPIC_AUTH_TOKEN"] = AggregationProjectionSignature.placeholderToken

        // 有发布 → 四档别名共享同一个 Stack id（1M 模型四档都带标记）+ 顶层 modelPicker；
        // 空发布 → 不写 modelPicker，四档别名回落默认那家直连口径（见 else 分支）。
        if !published.isEmpty {
            if let first = published.first {
                env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = first.id
                env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = first.id
                env["ANTHROPIC_DEFAULT_FABLE_MODEL"] = first.id
                // Haiku 档也带 [1M]：Stack id 非 claude- 前缀，缺标记 Claude Code 会按
                // 200K 算这一档；2.1.296 起对 Haiku 档同样认标记（cc-switch 3d46e06c 实测口径）。
                env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = AggregationModelID.encode(
                    tool: .claudeCode, key: first.key, model: first.model, oneM: first.oneM
                )
                env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] = first.displayName
                env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] = first.displayName
                env["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"] = first.displayName
                env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"] = first.displayName
            }

            // MAX 窗口 = 默认发布模型（四档别名共同指向的第一个）的窗口；恰为默认 200K 时不写。
            if let maxWindow = Self.maxContextTokens(published: published) {
                env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(maxWindow)
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
        } else {
            // 空发布（用户主动清空 stackModels）：不写 modelPicker，四档别名回落默认那家直连口径。
            // 对齐 cc-switch `controller.rs:222-252` 空列表整体 return（`CLAUDE_CODE_MAX_CONTEXT_TOKENS`
            // 保持默认那家原值）与 `claude.rs:257-260` 路由默认为 None 时回落 `proxy_model_fields`。
            // modelPicker 是拥有键——用户手写的值一并清掉（否则空 options 会清空内置选择器）。
            root.removeValue(forKey: "modelPicker")
            if let model = defaultProfile.modelOverride, !model.isEmpty {
                env["ANTHROPIC_MODEL"] = model
            }
            for (key, value) in defaultProfile.modelMapping?.nonEmptyEntries ?? [] {
                env[key] = value
            }
            // 窗口取默认那家 extraEnv 原值（非 Stack 窗口，200K 判断不适用）；无则上面已清干净。
            if let window = defaultProfile.extraEnv["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], !window.isEmpty {
                env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = window
            }
        }

        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }

        return root
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

    /// MAX 窗口规则：**默认发布模型**（四档别名共同指向的第一个）的窗口。
    ///
    /// 原先取“非 1M 模型窗口的最小值”，只要组里有一个 128K 成员，默认的 1M 模型也会被
    /// 压到 128K（magpie #2224 明确规避的行为）。改为跟随默认模型后，小成员不再拖累
    /// 默认模型；其他成员仍靠 `[1M]` 标记或 Claude Code 自身的 200K 回落约束。
    /// 1M 模型由 `[1M]` 标记声明，不写全局窗口；无有效值或恰为默认 200K → nil（不写）。
    ///
    /// 限制：`modelPicker` 切到窗口更小的成员时，全局值不会跟着降；逐模型
    /// `modelSettings.<id>.autoCompactWindow` 留待后续。
    private static func maxContextTokens(published: [AggregationPublishedModel]) -> UInt64? {
        guard let first = published.first, !first.oneM else { return nil }
        guard first.window > 0, first.window != AggregationModelPublisher.defaultWindow else { return nil }
        return first.window
    }
}
