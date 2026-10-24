import Foundation

/// Codex 思考档位的规范顺序（强度升序）— 解析、摘要与目录写入共用同一口径，
/// 与 `CodexModelCatalogStore.standardReasoningLevels` 的 effort 值一致。
/// 含 `ultra`（对齐 cc-switch `CODEX_REASONING_LEVEL_DESCRIPTIONS`：八档，ultra 最高）。
enum CodexReasoningLevel {
    static let ordered: [String] = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    static func isValid(_ level: String) -> Bool {
        ordered.contains(level)
    }

    /// 逗号分隔的档位串 → 规范化列表：拆分、去空白、过滤非法档、按标准序排序去重。
    /// 全部无效或为空 → nil（未配置）。
    static func parse(_ text: String) -> [String]? {
        let picked = text
            .split(separator: ",")
            .compactMap { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return trimmed.isEmpty ? nil : trimmed
            }
            .filter(isValid)
        var seen = Set<String>()
        let unique = ordered.filter { picked.contains($0) && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    /// 档位列表 → 摘要区间（标准序连续时）：`(first, last)`；单档 → `(level, level)`。
    /// 不连续或含未知档 → nil（UI 侧退回「N 档」计数文案）。
    static func summaryRange(for levels: [String]?) -> (first: String, last: String)? {
        guard let levels, !levels.isEmpty else { return nil }
        let indices = levels.compactMap { ordered.firstIndex(of: $0) }.sorted()
        guard indices.count == levels.count,
              indices.last! - indices.first! == indices.count - 1 else { return nil }
        return (ordered[indices.first!], ordered[indices.last!])
    }
}

/// Codex 成员模型条目 — 模型名 + 可配显示名 + 可配上下文窗口（SPEC 7 / P1-8）
/// + 可配思考档位与默认档位（对齐 cc-switch `CodexCatalogModel`）。
/// 显示名、窗口与档位均可缺省（nil = 未配置），由发布侧回退旧口径。
struct CodexModelEntry: Equatable {
    var model: String
    var displayName: String?
    var contextWindow: UInt64?
    /// 该模型接受的思考档位（`supported_reasoning_levels` 覆盖；nil = 用默认八档）。
    var reasoningLevels: [String]?
    /// 默认思考档位（`default_reasoning_level` 覆盖；仅与 `reasoningLevels` 同用时有效，
    /// 最终裁决在目录写入侧：不在列表内会被忽略并回落）。
    var defaultReasoningLevel: String?
}

/// Claude Desktop 模型映射条目 — key 为 Claude-safe 路由名（四档固定），
/// value 为上游真实模型名 + 可选显示名与 1M 标记（SPEC 功能 C）。
struct DesktopModelRoute: Codable, Equatable {
    var model: String
    var labelOverride: String?
    var supports1M: Bool
}

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
    /// Codex 模型显示名（与 `codexModels` 按位平行的持久化载体；空串 = 未配置）。Codex 侧专用，Claude 恒 nil。
    var modelDisplayNames: [String]?
    /// Codex 模型上下文窗口（与 `codexModels` 按位平行的十进制字符串；空串/不可解析 = 未配置）。
    /// Codex 侧专用，Claude 恒 nil。
    var modelContextWindows: [String]?
    /// Codex 模型思考档位（与 `codexModels` 按位平行的逗号分隔串，如 "none,low,high"；
    /// 空串/全无效 = 未配置）。Codex 侧专用，Claude 恒 nil。
    var modelReasoningLevels: [String]?
    /// Codex 模型默认思考档位（与 `codexModels` 按位平行；空串 = 未配置）。
    /// Codex 侧专用，Claude 恒 nil。
    var modelDefaultReasoningLevels: [String]?
    /// 额外 env（如 `CLAUDE_CODE_EFFORT_LEVEL=max`），随 profile 原样写入。
    var extraEnv: [String: String]
    /// Claude Desktop 模型映射（key = Claude-safe 路由名）。nil/空 = 直连卡；
    /// 非空 = 映射卡（必须聚合，直连切换前校验拒绝）。其余工具恒 nil。
    var desktopModelRoutes: [String: DesktopModelRoute]?
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
        modelDisplayNames: [String]? = nil,
        modelContextWindows: [String]? = nil,
        modelReasoningLevels: [String]? = nil,
        modelDefaultReasoningLevels: [String]? = nil,
        extraEnv: [String: String] = [:],
        desktopModelRoutes: [String: DesktopModelRoute]? = nil,
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
        self.modelDisplayNames = modelDisplayNames
        self.modelContextWindows = modelContextWindows
        self.modelReasoningLevels = modelReasoningLevels
        self.modelDefaultReasoningLevels = modelDefaultReasoningLevels
        self.extraEnv = extraEnv
        self.desktopModelRoutes = desktopModelRoutes
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

    /// 官方账号判定：指向厂商官方端点（或无 override 的空 baseURL）的 profile。
    /// 官方账号只能作为默认供应商，不能加入聚合（SPEC 6.9）；按宿主识别比任何
    /// 分类标记更宽——未标 category 的官方托管账号同样命中。
    ///
    /// 置于 Models 层（纯谓词、无 I/O）：聚合的目标解析（System 层）要按命中那家的
    /// 官方性决定凭证是否透传，编排层（Services）要按默认那家的官方性决定投影形状与
    /// 登录收纳，而 System 不得反向依赖 `ProviderAggregationManager`
    /// （层序见 `AggregationSwitchMerger` 的说明）。
    var isOfficial: Bool {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        switch tool {
        case .claudeCode:
            return host.isEmpty || host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
        case .codex:
            return host.isEmpty
                || host == "api.openai.com" || host.hasSuffix(".openai.com")
                || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
        case .claudeDesktop:
            // Desktop 官方是纯 UI 概念（restoreOfficial 恢复 1P），不合成 profile 记录；
            // 聚合准入、路由目标与 host 判定均不走该谓词，故恒 false（SPEC 功能 A）。
            return false
        }
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

    /// Codex 成员模型条目：`codexModelList` 与四个平行数组按位 zip（SPEC 7 / P1-8）。
    /// - 对齐基准取 `codexModelList`（而非裸 `codexModels`）：落盘 `models` 键写的正是它，
    ///   平行数组与它同序；旧档案的 `modelOverride` 回退模型同样能取到平行值。
    /// - 长度不齐按缺省处理：越界部分视为未配置，**不丢模型、不抛错**。
    /// - 显示名去首尾空白后为空 → nil；窗口去空白后不可解析或为 0 → nil（对齐 cc-switch `filter(|v| *v > 0)`）；
    ///   档位逗号串解析（过滤非法、按标准序）后为空 → nil；默认档位非法 → nil。
    var codexModelEntries: [CodexModelEntry] {
        let models = codexModelList
        let displayNames = modelDisplayNames ?? []
        let windows = modelContextWindows ?? []
        let levels = modelReasoningLevels ?? []
        let defaults = modelDefaultReasoningLevels ?? []
        return models.indices.map { index in
            CodexModelEntry(
                model: models[index],
                displayName: index < displayNames.count ? Self.nonBlank(displayNames[index]) : nil,
                contextWindow: index < windows.count ? Self.parsedWindow(windows[index]) : nil,
                reasoningLevels: index < levels.count ? CodexReasoningLevel.parse(levels[index]) : nil,
                defaultReasoningLevel: index < defaults.count
                    ? Self.parsedReasoningLevel(defaults[index])
                    : nil
            )
        }
    }

    /// 去首尾空白；空串 → nil（「空串 = 未配置」）。
    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 单个档位合法性：空白/非法 → nil（列表归属裁决在写入侧）。
    private static func parsedReasoningLevel(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CodexReasoningLevel.isValid(trimmed) ? trimmed : nil
    }

    /// 十进制窗口字符串 → UInt64；空白/不可解析/0 → nil（「未配置」，0 不是有效窗口）。
    private static func parsedWindow(_ text: String) -> UInt64? {
        guard let value = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
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
