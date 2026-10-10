import Foundation

/// `/v1/models` 的 Anthropic 形状模型发现 — 与 Task 9 路由表把 `/v1/models`
/// 判为 `.modelDiscovery` 是两件事：cc-switch 的该端点同时服务 Codex 的可达性检查
/// （OpenAI 形状）与 Claude 的模型发现（Anthropic 形状），故需要此内容协商判定。
/// **纯内存序列化，不做任何 I/O**（客户端只等 3 秒）。
enum AggregationModelDiscovery {
    /// Anthropic 形状的模型列表响应体（顺序即 `published` 顺序 = 选择器顺序）。
    static func responseBody(published: [AggregationPublishedModel]) -> Data {
        let root: [String: Any] = [
            "data": published.map { model in
                [
                    "type": "model",
                    "id": model.id,
                    "display_name": model.label,
                    "description": model.description,
                ]
            },
            "has_more": false,
        ]
        // 输入全部为受控 JSON 标量，序列化不会失败；失败时退回空列表体（形状仍合法）。
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
            ?? Data("{\"data\":[],\"has_more\":false}".utf8)
    }

    /// 内容协商判定：带 `anthropic-version` 头即为 Anthropic 形状发现请求；
    /// 否则 query 含 `limit` 且不含 `client_version` 时亦为真。非 GET 恒假。
    static func isModelDiscoveryRequest(
        method: String,
        path: String,
        headers: [String: String],
        query: String
    ) -> Bool {
        guard method.uppercased() == "GET" else { return false }
        if headers["anthropic-version"] != nil { return true }
        return query.contains("limit") && !query.contains("client_version")
    }
}
