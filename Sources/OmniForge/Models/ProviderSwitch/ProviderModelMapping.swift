import Foundation

/// Claude Code 角色 → 上游模型映射（对齐 ccswitch 的 env 形态）。
/// 默认兜底模型不在此结构内，单独存于 `ProviderProfile.modelOverride`（对应 `ANTHROPIC_MODEL`）。
struct ProviderModelMapping: Equatable, Codable {
    var sonnet: String?
    var sonnetName: String?
    var opus: String?
    var opusName: String?
    var fable: String?
    var fableName: String?
    var haiku: String?
    var haikuName: String?
    var subagent: String?

    /// 全部映射字段是否为空（空映射不写入 profile / env）。
    var isEmpty: Bool { nonEmptyEntries.isEmpty }

    /// 角色 → env 键（含空值占位，便于逐键写/清）。
    var envEntries: [(key: String, value: String?)] {
        [
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", sonnet),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", sonnetName),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", opus),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME", opusName),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL", fable),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL_NAME", fableName),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", haiku),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME", haikuName),
            ("CLAUDE_CODE_SUBAGENT_MODEL", subagent),
        ]
    }

    /// 全部非空字段。
    var nonEmptyEntries: [(key: String, value: String)] {
        envEntries.compactMap { entry in
            guard let value = entry.value, !value.isEmpty else { return nil }
            return (entry.key, value)
        }
    }

    // MARK: - 聚合发布推导（有序）

    /// 聚合发布用的有序角色项：顺序固定 opus → sonnet → haiku → fable，跳过空值，各自带显示名。
    /// **不含 subagent**（子代理模型不面向用户选择）。
    /// 与 `envEntries` 相互独立——直连路径的 env 写入顺序与内容不变。
    var orderedPublishEntries: [(model: String, displayName: String?)] {
        [
            (opus, opusName),
            (sonnet, sonnetName),
            (haiku, haikuName),
            (fable, fableName),
        ].compactMap { entry in
            guard let model = entry.0, !model.isEmpty else { return nil }
            return (model, entry.1)
        }
    }

    /// 本结构占用的全部 env 键。
    static let allEnvKeys: Set<String> = [
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    ]

    /// 从 env 重建（空值置 nil）。
    static func fromEnv(_ env: [String: String]) -> ProviderModelMapping {
        ProviderModelMapping(
            sonnet: emptyToNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL"]),
            sonnetName: emptyToNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"]),
            opus: emptyToNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"]),
            opusName: emptyToNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"]),
            fable: emptyToNil(env["ANTHROPIC_DEFAULT_FABLE_MODEL"]),
            fableName: emptyToNil(env["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"]),
            haiku: emptyToNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]),
            haikuName: emptyToNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"]),
            subagent: emptyToNil(env["CLAUDE_CODE_SUBAGENT_MODEL"])
        )
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

extension ProviderModelMapping {
    /// 简写构造：只给四个角色与 subagent 的模型值，显示名缺省 nil（聚合发布推导常用）。
    /// 放扩展中以保留合成的成员构造器。
    init(
        sonnet: String? = nil,
        opus: String? = nil,
        fable: String? = nil,
        haiku: String? = nil,
        subagent: String? = nil
    ) {
        self.init(
            sonnet: sonnet,
            sonnetName: nil,
            opus: opus,
            opusName: nil,
            fable: fable,
            fableName: nil,
            haiku: haiku,
            haikuName: nil,
            subagent: subagent
        )
    }
}
