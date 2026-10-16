import Foundation

/// 聚合 key 登记簿 — profile id → 永久 key 的分配与反查（key → profileID 存储）。
/// **没有 release**：key 一经分配永不回收。从名单移除成员只改 `AggregationStack.members`，
/// 登记簿原样保留——这正是「移除后重新加入拿回原 key、旧会话里的 id 继续有效」的实现基础。
/// 纯值逻辑，不持 profile 列表（`resolve` 由调用方传入 candidates），非 `@MainActor`。
final class AggregationKeyRegistry {
    /// key 最大长度（含去重后缀）。客户端配置里的模型 id 由 key 拼成，过长不友好。
    static let maxKeyLength = 24

    private(set) var keys: [String: String]

    init(keys: [String: String] = [:]) {
        self.keys = keys
    }

    /// 分配（或取回）该 profile 的 key。已分配过 → 原样返回；否则取名称 slug 为基名，
    /// 与**历史全部**已占用 key 冲突时按 `-2`、`-3` 递增（追加前先把基名截短，
    /// 保证含后缀的最终 key 仍 ≤ maxKeyLength，同一基名的多个去重结果不因长度差互撞）。
    func allocate(profile: ProviderProfile) -> String {
        if let existing = keyOf(profileID: profile.id) {
            return existing
        }
        let base = Self.baseKey(for: profile)
        var candidate = base
        var suffix = 2
        while keys[candidate] != nil {
            let suffixText = "-\(suffix)"
            let allowed = Self.maxKeyLength - suffixText.count
            candidate = String(base.prefix(allowed)).trimmingTrailingDashes() + suffixText
            suffix += 1
        }
        keys[candidate] = profile.id
        return candidate
    }

    /// 反查 profile 当前绑定的 key（登记簿中值等于入参的键）。
    func keyOf(profileID: String) -> String? {
        keys.first { $0.value == profileID }?.key
    }

    /// 解析 key 当前指向的 profile id：先按登记的 id 找；找不到按名称找
    /// （`profile.id` 是名称的 slug，改名即换 id——名称仍 slug 成该 key 的视为同一家，
    /// 命中时把 key 重新绑定到新 id）；都找不到返回 nil。
    func resolve(key: String, candidates: [ProviderProfile]) -> String? {
        guard let profileID = keys[key] else { return nil }
        if candidates.contains(where: { $0.id == profileID }) {
            return profileID
        }
        if let match = candidates.first(where: { Self.baseKey(for: $0) == key }) {
            keys[key] = match.id
            return match.id
        }
        return nil
    }

    // MARK: - private

    /// 基名：名称 slug 化；结果为空回退 `"p" + id 去横线前 6 位`（确定性，不依赖名称）。
    private static func baseKey(for profile: ProviderProfile) -> String {
        let slug = slug(profile.name)
        if !slug.isEmpty {
            return slug
        }
        return "p" + profile.id.filter { $0 != "-" }.prefix(6)
    }

    /// key 命名空间的 slug 规则（与 `ProviderProfile.slugify` 是两套目的不同的规则：
    /// 这里要求确定性、无分隔符、定长上限；拼音转换对 key 稳定性没有好处）。
    /// 小写、只留 `[a-z0-9-]`、其余折单个 `-`、连续 `-` 合并、去首尾 `-`、截断到 24 后再去尾 `-`。
    private static func slug(_ name: String) -> String {
        var result = ""
        for scalar in name.lowercased().unicodeScalars {
            let isASCIIAlnum = (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
            if isASCIIAlnum {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                // 非保留字符（空白、斜杠、汉字等）折叠为单个 "-"；连续折叠只留一个
                result.append("-")
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        if result.count > maxKeyLength {
            result = String(result.prefix(maxKeyLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result
    }
}

private extension String {
    func trimmingTrailingDashes() -> String {
        var result = self
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
