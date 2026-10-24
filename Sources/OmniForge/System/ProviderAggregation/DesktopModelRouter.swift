import Foundation

/// Claude Desktop 的请求模型名改写（对齐 cc-switch `map_proxy_request_model` 核心子集，
/// SPEC 功能 C）。作用于 Desktop 代理的 plain 路径（聚合 id 由 resolver 反查，不经此处）：
/// 1. 剥末尾 `[1m]`/`[1M]` 标记；
/// 2. 无映射卡（routes 空/nil）→ Claude-safe 名**原样透传**（绝不按四档 identity 改写——
///    带日期后缀的名会被错改成档名，上游 404）；
/// 3. 有映射卡 → 精确查表 → opus 别名 → 角色回落（fable 无配置降 opus）；
/// 4. 全部落空 → `unconfigured`（明确报错，不透传）。
enum DesktopModelRouter {
    enum Outcome: Equatable {
        /// 原样放行（剥标记后的名字）。
        case passthrough(String)
        /// 改写为上游真实模型名。
        case rewritten(String)
        /// 映射卡上没有可用档（错误：`模型路由未配置: <name>`）。
        case unconfigured(String)
    }

    /// opus 互认别名：Desktop 侧 opus 档名与常见旧名（cc-switch 同款）。
    static let opusAliases: Set<String> = ["claude-opus-5", "claude-opus-4-8"]

    /// 角色关键词 → 默认档名（角色回落的查表键，对齐 `ClaudeDesktopSettingsStore.defaultRoutes`）。
    static let roleSlots: [String: String] = [
        "sonnet": "claude-sonnet-5",
        "opus": "claude-opus-5",
        "haiku": "claude-haiku-4-5",
        "fable": "claude-fable-5",
    ]

    static func route(model: String, routes: [String: DesktopModelRoute]?) -> Outcome {
        // 1. 剥 [1m] 标记（大小写不敏感）。
        let (stripped, _) = AggregationModelID.stripOneMMarker(model)
        guard let routes, !routes.isEmpty else {
            // 2. 无映射卡（直连卡）：只有 Claude-safe 名原样透传——绝不按四档 identity 改写
            //    （带日期后缀的名会被错改成档名，上游 404）。非 Claude-safe 名报错，
            //    不静默发给上游（对齐 cc-switch `map_proxy_request_model` 的 route_unknown）。
            return ClaudeDesktopSettingsStore.isClaudeSafeModelID(stripped)
                ? .passthrough(stripped)
                : .unconfigured(stripped)
        }
        // 3a. 精确查表。
        if let exact = routes[stripped] {
            return .rewritten(exact.model)
        }
        // 3b. opus 别名（双向互认）。
        if opusAliases.contains(stripped) {
            for alias in opusAliases where alias != stripped {
                if let route = routes[alias] {
                    return .rewritten(route.model)
                }
            }
        }
        // 3c. 角色回落：请求名含角色段 → 查该角色档；fable 无配置降 opus。
        if let role = roleOf(stripped) {
            let tryRoles = role == "fable" ? ["fable", "opus"] : [role]
            for candidate in tryRoles {
                if let slot = roleSlots[candidate], let route = routes[slot] {
                    return .rewritten(route.model)
                }
            }
        }
        // 4. 明确错误（不透传到上游）。
        return .unconfigured(stripped)
    }

    /// 名字中的角色关键词（`-sonnet-` / `-opus-` / `-haiku-` / `-fable-`）。
    private static func roleOf(_ model: String) -> String? {
        roleSlots.keys.first { model.contains("-\($0)-") }
    }
}

/// Claude Desktop 的模型发现响应 — `{data:[{type,id,display_name,description,created_at,supports1m}],
/// has_more, first_id, last_id}`。不复用 `AggregationModelDiscovery.responseBody`：
/// 后者缺 `supports1m` 与 `created_at`（SPEC 功能 C）。
enum DesktopModelDiscovery {
    /// `created_at` 固定常量（RFC3339 字符串，对齐 cc-switch `DEFAULT_CREATED_AT`；
    /// Anthropic 官方 `/v1/models` 同字段即字符串形态，整型可能导致整列表解析失败）。
    static let createdAtConstant = "2024-01-01T00:00:00Z"

    static func responseBody(published: [AggregationPublishedModel]) -> Data {
        let rows: [[String: Any]] = published.map { model in
            [
                "type": "model",
                "id": model.id,
                "display_name": model.label,
                "description": model.description,
                "created_at": createdAtConstant,
                "supports1m": model.oneM,
            ]
        }
        let root: [String: Any] = [
            "data": rows,
            "has_more": false,
            "first_id": published.first?.id ?? NSNull(),
            "last_id": published.last?.id ?? NSNull(),
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}
