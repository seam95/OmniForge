import Foundation

/// 代理目标 — 请求最终发往的那家供应商。
struct AggregationProxyTarget: Equatable {
    let key: String
    let profileID: String
    let baseURL: String
    let token: String
}

/// 模型 id 解析结果。
enum AggregationResolution: Equatable {
    /// 普通模型名 → 默认供应商（请求体原样转发）。
    case plain(target: AggregationProxyTarget)
    /// 聚合模型命中 → 目标成员 + 还原后的上游模型名（体里 model 换成它再转发）。
    case hit(target: AggregationProxyTarget, upstreamModel: String)
    /// 解不出来 → 四种原因之一（不回落到默认）。
    case miss(AggregationMiss)
}

/// 目标解析边界。
protocol AggregationResolving {
    func resolve(tool: ProviderTool, model: String) -> AggregationResolution
}

/// 目标解析实现（对齐 cc-switch `mode::stack::resolve`）——纯值逻辑，无 I/O。
/// `stack` / `registry` 都是**该工具**的那份，由调用方按 `toolStack(tool)` 提供；
/// `profiles` 由 `ProviderProfileStore` 列举后注入（登记簿本身不持列表）。
final class AggregationTargetResolver: AggregationResolving {
    private let stack: AggregationStack.ToolStack
    private let registry: AggregationKeyRegistry
    private let profiles: [ProviderProfile]
    private let defaultTarget: AggregationProxyTarget?

    init(
        stack: AggregationStack.ToolStack,
        registry: AggregationKeyRegistry,
        profiles: [ProviderProfile],
        defaultTarget: AggregationProxyTarget?
    ) {
        self.stack = stack
        self.registry = registry
        self.profiles = profiles
        self.defaultTarget = defaultTarget
    }

    func resolve(tool: ProviderTool, model: String) -> AggregationResolution {
        switch AggregationModelID.decode(tool: tool, id: model) {
        case .plain:
            guard let defaultTarget else { return .miss(.stackOff) }
            return .plain(target: defaultTarget)
        case .malformed:
            return .miss(.unknown)
        case .stack(let key, let stackModel, let oneM):
            guard stack.enabled else { return .miss(.stackOff) }
            guard let profileID = registry.keys[key] else { return .miss(.unknown) }
            guard let profile = profiles.first(where: { $0.id == profileID }) else { return .miss(.deleted) }
            guard stack.isMember(profileID) else { return .miss(.removed) }
            let target = AggregationProxyTarget(
                key: key,
                profileID: profileID,
                baseURL: profile.baseURL,
                token: profile.token
            )
            return .hit(target: target, upstreamModel: upstreamModel(tool: tool, profile: profile, key: key, model: stackModel, oneM: oneM))
        }
    }

    /// 上游模型名：Codex 侧用裸模型名；Claude 侧在发布源里找**剥标记后**匹配的条目，
    /// 取其 `upstream`（可能带 `[1M]`）；找不到（成员发布源已变）则按 oneM 重建。
    private func upstreamModel(tool: ProviderTool, profile: ProviderProfile, key: String, model: String, oneM: Bool) -> String {
        switch tool {
        case .codex:
            return model
        case .claudeCode:
            if let published = AggregationModelPublisher.published(profile: profile, key: key)
                .first(where: { AggregationModelID.stripOneMMarker($0.upstream).model == model }) {
                return published.upstream
            }
            return oneM ? model + AggregationModelID.oneMMarker : model
        }
    }
}
