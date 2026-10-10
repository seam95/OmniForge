import Foundation

/// 聚合模型 ID 编解码 — 客户端选择器里的 id 与（归属 key、上游模型名、1M 标记）互转。
/// 保留前缀以 `ccs-` 开头且 Claude 侧含 "claude" 但不以 "claude-" 开头，
/// 保证不会与真实模型名空间相撞（真实 Claude 模型均以 `claude-` 开头）。
enum AggregationModelID {
    /// Claude 侧前缀。
    static let claudePrefix = "ccs-claude-"
    /// Codex 侧前缀（较短，故无分隔符时按普通模型名放行）。
    static let codexPrefix = "ccs-"
    /// Claude 侧 key 与模型名的分隔符——模型名可含 `--`，只在**第一个**处切。
    static let claudeSeparator = "--"
    /// Codex 侧分隔符——模型名可含 `/`（如 `openai/gpt-5`），只在**第一个**处切。
    static let codexSeparator = "/"
    /// 1M 上下文标记：编码恒写大写，解码大小写不敏感。
    static let oneMMarker = "[1M]"

    enum Decoded: Equatable {
        /// 普通模型名（无保留前缀）— 原样路由到默认供应商。
        case plain
        /// 前缀匹配但结构破损（key 或上游模型名为空）。
        case malformed
        /// 聚合模型 — 归属 key、上游模型名、是否 1M。
        case stack(key: String, model: String, oneM: Bool)
    }

    static func encode(tool: ProviderTool, key: String, model: String, oneM: Bool) -> String {
        switch tool {
        case .claudeCode:
            return claudePrefix + key + claudeSeparator + model + (oneM ? oneMMarker : "")
        case .codex:
            return codexPrefix + key + codexSeparator + model
        }
    }

    static func decode(tool: ProviderTool, id: String) -> Decoded {
        switch tool {
        case .claudeCode:
            guard let remainder = id.remainderAfterPrefix(claudePrefix) else { return .plain }
            // 前缀匹配但找不到分隔符 → 结构破损（前缀本身已足够独特，不放行）。
            guard let (key, rawModel) = remainder.splitOnce(claudeSeparator) else { return .malformed }
            return assemble(key: key, rawModel: rawModel)
        case .codex:
            guard let remainder = id.remainderAfterPrefix(codexPrefix) else { return .plain }
            // `ccs-` 很短，可能与真实模型名撞头：不含分隔符即按普通模型名路由到默认供应商。
            guard let (key, rawModel) = remainder.splitOnce(codexSeparator) else { return .plain }
            return assemble(key: key, rawModel: rawModel)
        }
    }

    /// 切分结果组装：key 或上游模型名为空 → malformed；末尾 1M 标记（大小写不敏感）剥出。
    private static func assemble(key: String, rawModel: String) -> Decoded {
        let stripped = stripOneMMarker(rawModel)
        guard !key.isEmpty, !stripped.model.isEmpty else { return .malformed }
        return .stack(key: key, model: stripped.model, oneM: stripped.oneM)
    }

    /// 剥掉末尾 1M 标记（大小写不敏感）——发布源推导与解码共用同一口径。
    static func stripOneMMarker(_ model: String) -> (model: String, oneM: Bool) {
        if model.lowercased().hasSuffix(oneMMarker.lowercased()) {
            return (String(model.dropLast(oneMMarker.count)), true)
        }
        return (model, false)
    }
}

private extension String {
    /// 去掉指定前缀；不匹配返回 nil。
    func remainderAfterPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    /// 在第一个分隔符处切开（分隔符允许出现在后半段）；找不到返回 nil。
    func splitOnce(_ separator: String) -> (left: String, right: String)? {
        guard let range = range(of: separator) else { return nil }
        return (String(self[..<range.lowerBound]), String(self[range.upperBound...]))
    }
}
