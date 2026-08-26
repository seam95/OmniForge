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
    /// 默认兜底模型（`ANTHROPIC_MODEL`）；Codex 侧即单模型覆盖。
    var modelOverride: String?
    /// Claude Code 角色模型映射（对齐 ccswitch）；Codex 为 nil。
    var modelMapping: ProviderModelMapping?
    /// 额外 env（如 `CLAUDE_CODE_EFFORT_LEVEL=max`），随 profile 原样写入。
    var extraEnv: [String: String]
    /// 来源标记：本 App 写入为 "omniforge"；CCQ 等外部文件为 nil（只读展示，可收编/编辑）。
    var managedBy: String?

    /// 本 App 创建的文件标记（SPEC 2.4）。
    static let managedByMarker = "omniforge"

    var isManagedByOmniForge: Bool { managedBy == Self.managedByMarker }

    /// profileKey：slug 化的名称，作为 profile 文件名（如 `glm.json`）。
    var profileKey: String { Self.slugify(name) }

    /// slug 规则：仅 ASCII 字母数字，其余字符折叠为单个 `-`，去首尾 `-`；全空时回退 "profile"。
    static func slugify(_ name: String) -> String {
        var result = ""
        for scalar in name.lowercased().unicodeScalars {
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
        return result.isEmpty ? "profile" : result
    }

    /// 缺失连接参数（外部文件无法解析出 base URL / 凭证时）— 不可直接激活。
    var hasCompleteConnection: Bool {
        !baseURL.isEmpty && !token.isEmpty
    }
}
