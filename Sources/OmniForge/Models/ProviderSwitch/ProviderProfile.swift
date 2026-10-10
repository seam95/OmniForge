import Foundation

/// 供应商档案 — 一个可用供应商 = 名称 + 目标工具 + base URL + 明文凭证 + 可选模型覆盖。
/// 一个 Profile 只服务一个工具（Claude Code 或 Codex 之一）；Preset : Profile = 1 : N。
struct ProviderProfile: Identifiable, Codable, Equatable {
    /// 身份即 profile 文件名的基名（slug）。store 以文件名为准覆盖此值。
    var id: String
    var name: String
    var tool: ProviderTool
    var baseURL: String
    var token: String
    /// 默认兜底模型（`ANTHROPIC_MODEL`，Claude Code 侧）。
    /// Codex 侧请用 `codexModels`；此字段仅为旧档案兼容而保留（读取时回退为单元素列表）。
    var modelOverride: String?
    /// 思考强度（Reasoning Effort，Codex 专属，如 "none", "low", "medium", "high", "xhigh", "max"）。
    var reasoningEffort: String?
    /// Codex 模型列表：第一项为默认模型（`config.toml` 顶层 `model`），全部项写入模型目录。
    /// Claude Code 侧为 nil（默认模型在 `modelOverride`，角色映射在 `modelMapping`）。
    var codexModels: [String]?
    /// Claude Code 角色模型映射（对齐 ccswitch）；Codex 为 nil。
    var modelMapping: ProviderModelMapping?
    /// Claude Code 聚合发布源（有序）。nil = 未配置（按模型映射推导发布）；
    /// 空数组 = 用户主动清空（什么都不发布）——两者语义相反，不可混淆。
    /// Codex 侧恒为 nil（Codex 聚合发布走 `codexModels`）。本期无 UI 编辑入口。
    var stackModels: [ClaudeStackModel]?
    /// 额外 env（如 `CLAUDE_CODE_EFFORT_LEVEL=max`），随 profile 原样写入。
    var extraEnv: [String: String]
    /// 来源标记：本 App 写入为 "omniforge"；CCQ 等外部文件为 nil（只读展示，可收编/编辑）。
    var managedBy: String?

    init(
        id: String,
        name: String,
        tool: ProviderTool,
        baseURL: String,
        token: String,
        modelOverride: String? = nil,
        reasoningEffort: String? = nil,
        codexModels: [String]? = nil,
        modelMapping: ProviderModelMapping? = nil,
        stackModels: [ClaudeStackModel]? = nil,
        extraEnv: [String: String] = [:],
        managedBy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tool = tool
        self.baseURL = baseURL
        self.token = token
        self.modelOverride = modelOverride
        self.reasoningEffort = reasoningEffort
        self.codexModels = codexModels
        self.modelMapping = modelMapping
        self.stackModels = stackModels
        self.extraEnv = extraEnv
        self.managedBy = managedBy
    }

    /// 本 App 创建的文件标记（SPEC 2.4）。
    static let managedByMarker = "omniforge"

    var isManagedByOmniForge: Bool { managedBy == Self.managedByMarker }

    /// profileKey：slug 化的名称，作为 profile 文件名（如 `glm.json`）。
    var profileKey: String { Self.slugify(name) }

    /// slug 规则：优先将汉字转化为拼音与 ASCII 字母数字，其余字符折叠为单个 `-`，去首尾 `-`；全空时基于原词确定性短哈希防撞。
    static func slugify(_ name: String) -> String {
        let mutable = NSMutableString(string: name)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let transformed = mutable as String

        var result = ""
        for scalar in transformed.lowercased().unicodeScalars {
            let isASCIIAlnum = (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
            if isASCIIAlnum {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty {
            let hash = abs(name.hashValue) % 1_000_000
            return name.isEmpty ? "profile" : String(format: "profile-%06d", hash)
        }
        return result
    }

    /// 缺失连接参数（外部文件无法解析出 base URL / 凭证时）— 不可直接激活。
    var hasCompleteConnection: Bool {
        !baseURL.isEmpty && !token.isEmpty
    }

    // MARK: - Codex 模型列表

    /// 规范化的 Codex 模型列表：去首尾空白、丢空项、按序去重。
    /// 旧档案（及旧构造路径）只设了 `modelOverride` 时回退为单元素列表；
    /// `codexModels` 为空数组（用户删空）不回退，表示「不指定模型」。
    var codexModelList: [String] {
        let fallback = modelOverride.map { [$0] } ?? []
        var seen = Set<String>()
        return (codexModels ?? fallback).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }
    }

    // MARK: - Claude 聚合发布源

    /// 聚合模式下的 Claude 有序发布源（顺序即客户端选择器里的顺序）。
    /// - `stackModels != nil`（含空数组）→ 原样返回：空数组是用户主动清空，语义为「什么都不发布」。
    /// - 否则按 `modelOverride` → 映射 opus → sonnet → haiku → fable 顺序推导，跳过空值，**不含 subagent**；
    ///   全空时返回 `[]`。推导条目的 `oneM` 恒 false——1M 由发布方按模型名字面标记识别。
    var aggregationModels: [ClaudeStackModel] {
        if let stackModels { return stackModels }
        var models: [ClaudeStackModel] = []
        if let model = modelOverride, !model.isEmpty {
            models.append(ClaudeStackModel(model: model, displayName: nil, oneM: false))
        }
        if let modelMapping {
            for entry in modelMapping.orderedPublishEntries {
                models.append(ClaudeStackModel(model: entry.model, displayName: entry.displayName, oneM: false))
            }
        }
        return models
    }
}
