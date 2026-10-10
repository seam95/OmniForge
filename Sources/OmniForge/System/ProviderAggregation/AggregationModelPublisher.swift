import Foundation

/// 聚合发布源推导 — 把 profile 的聚合模型列表变成客户端选择器条目。
enum AggregationModelPublisher {
    /// 默认上下文窗口（200K）— profile 未在 extraEnv 显式指定时沿用，
    /// 也是 Claude 投影「不额外约束客户端」的阈值（见 `AggregationClaudeConfigWriter`）。
    static let defaultWindow: UInt64 = 200_000

    /// 推导该 profile 在给定 key 下的发布条目（顺序即 `profile.aggregationModels` 顺序，
    /// 也就是客户端选择器里的顺序）。
    /// 1M 判定：`ClaudeStackModel.oneM` 或模型名字面带标记（大小写不敏感）；
    /// 按剥标记后的模型名去重，任一处带 1M 即按 1M 合并。
    static func published(profile: ProviderProfile, key: String) -> [AggregationPublishedModel] {
        let window = Self.window(of: profile)
        var result: [AggregationPublishedModel] = []
        var indexByModel: [String: Int] = [:]
        for entry in profile.aggregationModels {
            let stripped = AggregationModelID.stripOneMMarker(entry.model)
            let oneM = entry.oneM || stripped.oneM
            // 上游模型名：原值带标记 → 原样保留（上游可能对大小写敏感，如 `k3[1m]`）；
            // oneM 但原值不带标记 → 补规范标记（Stack id 带了 [1M]，上游必须收到对应名字）。
            let upstream = stripped.oneM
                ? entry.model
                : (oneM ? stripped.model + AggregationModelID.oneMMarker : stripped.model)
            if let existingIndex = indexByModel[stripped.model] {
                // 同模型去重：仅 1M 标记需要升级（upstream 换成带上标记的值）
                let existing = result[existingIndex]
                guard oneM, !existing.oneM else { continue }
                result[existingIndex] = AggregationPublishedModel(
                    key: existing.key,
                    profileName: existing.profileName,
                    model: existing.model,
                    upstream: upstream,
                    displayName: existing.displayName,
                    oneM: true,
                    window: existing.window
                )
                continue
            }
            indexByModel[stripped.model] = result.count
            result.append(AggregationPublishedModel(
                key: key,
                profileName: profile.name,
                model: stripped.model,
                upstream: upstream,
                displayName: entry.displayName ?? stripped.model,
                oneM: oneM,
                window: window
            ))
        }
        return result
    }

    /// 窗口缩写：0 → nil；整除 1M → `<n>M`；≥1000 → 四舍五入 `<n>K`；其余原样字符串化。
    static func windowLabel(_ window: UInt64) -> String? {
        if window == 0 { return nil }
        if window % 1_000_000 == 0 { return "\(window / 1_000_000)M" }
        if window >= 1_000 { return "\((window + 500) / 1_000)K" }
        return String(window)
    }

    // MARK: - private

    /// profile 的上下文窗口：extraEnv 的 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 解析值，缺省 200K。
    private static func window(of profile: ProviderProfile) -> UInt64 {
        guard let raw = profile.extraEnv["CLAUDE_CODE_MAX_CONTEXT_TOKENS"],
              let parsed = UInt64(raw) else {
            return defaultWindow
        }
        return parsed
    }
}
