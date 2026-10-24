import Foundation

/// 聚合模型 ID 编解码 — 客户端选择器里的 id 与（归属 key、上游模型名、1M 标记）互转。
/// 保留前缀以 `om-` 开头且 Claude 侧含 "claude" 但不以 "claude-" 开头，
/// 保证不会与真实模型名空间相撞（真实 Claude 模型均以 `claude-` 开头）。
enum AggregationModelID {
    /// Claude 侧前缀。
    static let claudePrefix = "om-claude-"
    /// Codex 侧前缀（较短，故无分隔符时按普通模型名放行）。
    static let codexPrefix = "om-"
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
        /// Desktop 聚合模型（`claude-fable-om-<6 位数字>`）— id 只含数字哈希，
        /// 无法自还原 key/model，携带原 id 由快照发布表反查（SPEC 功能 D）。
        case stackCode(String)
    }

    static func encode(tool: ProviderTool, key: String, model: String, oneM: Bool) -> String {
        switch tool {
        case .claudeCode:
            return claudePrefix + key + claudeSeparator + model + (oneM ? oneMMarker : "")
        case .codex:
            return codexPrefix + key + codexSeparator + model
        case .claudeDesktop:
            return desktopEncodedID(key: key, model: model)
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
            // `om-` 很短，可能与真实模型名撞头：不含分隔符即按普通模型名路由到默认供应商。
            guard let (key, rawModel) = remainder.splitOnce(codexSeparator) else { return .plain }
            return assemble(key: key, rawModel: rawModel)
        case .claudeDesktop:
            // Desktop id 是纯数字哈希，key/model 信息已不可逆 — 交由发布表反查。
            // 必须先剥末尾 `[1m]`：profile 写了 `prefer1m` 后 Desktop 发请求用 `<id>[1m]`，
            // 发布表存的 id 不带标记，不剥就查不到 → 1M 模型全部 400
            // （对齐 cc-switch `decode` 的 `strip_one_m_suffix_for_upstream`）。
            guard let remainder = id.remainderAfterPrefix(desktopPrefix) else { return .plain }
            let (code, _) = stripOneMMarker(remainder)
            guard code.count == 6, code.allSatisfy(\.isNumber) else { return .malformed }
            return .stackCode(desktopPrefix + code)
        }
    }

    // MARK: - Desktop 编码（对齐 cc-switch `mode/stack.rs` FNV-1a u64 哈希）

    /// Desktop 侧前缀（`om-` 段区分 cc-switch 的 `ccs-`；`claude-fable-` 段过 Desktop 白名单）。
    static let desktopPrefix = "claude-fable-om-"

    /// Desktop 聚合模型 id：`claude-fable-om-<6 位数字>`。
    /// 哈希 = FNV-1a u64（offset `0xcbf29ce484222325`、prime `0x100000001b3`），
    /// 输入 = key 字节 + `0x00` + model 字节，取模 1_000_000，左补零到 6 位。
    static func desktopEncodedID(key: String, model: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        hash = (hash ^ 0x00) &* prime
        for byte in model.utf8 {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        let digits = Int(hash % 1_000_000)
        return String(format: "%@%06d", desktopPrefix, digits)
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
