import Foundation

/// 聚合状态顶层容器 — 每个工具各一份，独立处于直连/聚合（SPEC 6.1）。
/// 同一 profile 只属一边是正常形态：两侧准入规则不同
/// （Codex 成员要求 `wire_api="responses"`，Claude 侧按 `stackModels`/映射发布）。
struct AggregationStack: Codable, Equatable {
    var claudeCode: ToolStack
    var codex: ToolStack
    var claudeDesktop: ToolStack

    init(
        claudeCode: ToolStack = .init(),
        codex: ToolStack = .init(),
        claudeDesktop: ToolStack = .init()
    ) {
        self.claudeCode = claudeCode
        self.codex = codex
        self.claudeDesktop = claudeDesktop
    }

    /// 顶层自定义解码：`claudeDesktop` 是后加的非可选键，存量 `stack.json` 没有它 —
    /// 合成 Codable 会因缺键整体失败，这里 `decodeIfPresent` 容错（SPEC 功能 D）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCode = try container.decodeIfPresent(ToolStack.self, forKey: .claudeCode) ?? .init()
        codex = try container.decodeIfPresent(ToolStack.self, forKey: .codex) ?? .init()
        claudeDesktop = try container.decodeIfPresent(ToolStack.self, forKey: .claudeDesktop) ?? .init()
    }

    /// 单个工具的聚合状态 — 模式位、成员名单、key 登记簿三层。
    struct ToolStack: Codable, Equatable {
        /// 该工具是否处于聚合模式。管理器的 `mode(tool:)` 以此为唯一数据来源。
        var enabled: Bool
        /// 成员 profile id 列表（有序——加入顺序即客户端选择器里的顺序）。
        var members: [String]
        /// key 登记簿：永久 key → profile id。key 一经分配永不回收
        /// （移除成员只改 `members`，登记簿原样保留——重加入拿回原 key、旧 id 继续有效）。
        var keys: [String: String]

        init(enabled: Bool = false, members: [String] = [], keys: [String: String] = [:]) {
            self.enabled = enabled
            self.members = members
            self.keys = keys
        }

        /// 容忍缺键解码：缺省值与成员初始化器一致（手写而不依赖合成——
        /// 历史/手改文件可能只带部分键，缺键即取缺省而非整体失败）。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            members = try container.decodeIfPresent([String].self, forKey: .members) ?? []
            keys = try container.decodeIfPresent([String: String].self, forKey: .keys) ?? [:]
        }

        func isMember(_ profileID: String) -> Bool {
            members.contains(profileID)
        }

        /// 反查 profile 当前绑定的 key（登记簿中值等于入参的键）。
        func keyOf(profileID: String) -> String? {
            keys.first { $0.value == profileID }?.key
        }
    }

    func toolStack(_ tool: ProviderTool) -> ToolStack {
        switch tool {
        case .claudeCode: return claudeCode
        case .codex: return codex
        case .claudeDesktop: return claudeDesktop
        }
    }

    mutating func setToolStack(_ stack: ToolStack, for tool: ProviderTool) {
        switch tool {
        case .claudeCode: claudeCode = stack
        case .codex: codex = stack
        case .claudeDesktop: claudeDesktop = stack
        }
    }
}
