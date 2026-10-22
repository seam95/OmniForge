import Foundation

/// 代理侧 HTTP 请求头（手写 socket 数据面用）— 只解析到「头 + content-length」，
/// 请求体由连接层按 `contentLength` 续收。
struct AggregationRequestHead: Equatable {
    let method: String
    let path: String
    let query: String
    /// 小写化的请求头。同名头后者覆盖前者（本场景所需头均为单值）。
    let headers: [String: String]
    let contentLength: Int
}

enum AggregationRequestParser {
    /// 头/体分隔符（连接层据此判断头已收全）。
    static let headerTerminator = "\r\n\r\n"

    /// 解析请求头；头未收全（无分隔符）或首行不可解析 → nil。
    static func parseHead(_ data: Data) -> AggregationRequestHead? {
        guard let text = String(data: data, encoding: .utf8),
              let separatorRange = text.range(of: headerTerminator) else {
            return nil
        }
        let headText = String(text[..<separatorRange.lowerBound])
        let lines = headText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil } // 至少要方法与 target
        let (path, query) = splitTarget(String(requestParts[1]))

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                headers[key] = value
            }
        }
        return AggregationRequestHead(
            method: String(requestParts[0]),
            path: path,
            query: query,
            headers: headers,
            contentLength: Int(headers["content-length"] ?? "") ?? 0
        )
    }

    /// 请求体里的模型名；体非 JSON、非对象或缺字段 → nil。
    static func model(from body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        return object["model"] as? String
    }

    /// 删除 Responses `input` 中上游无法解析的 reasoning item。
    ///
    /// Codex 默认 `store = false`，不在服务端持久化 item。跨供应商切换后，历史里
    /// 上一家的 reasoning item 只剩 `id` 和 `summary`；官方 Responses 后端会按 id
    /// 去它持久化的 item 里查找，找不到就回：
    ///
    ///     404 Item with id 'rs_…' not found.
    ///     Items are not persisted when `store` is set to false.
    ///
    /// 只删除 `type == "reasoning"` 且 `encrypted_content` 为空的 item。带密封内容的
    /// reasoning 属于当前供应商可读的上下文，保持原样。
    static func removingBareReasoningItems(from body: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["store"] as? Bool != true,
              let items = object["input"] as? [[String: Any]] else {
            return body
        }
        var changed = false
        let kept = items.filter { item in
            guard item["type"] as? String == "reasoning" else { return true }
            let sealed = item["encrypted_content"] as? String
            let keep = sealed?.isEmpty == false
            if !keep { changed = true }
            return keep
        }
        guard changed else { return body }
        var root = object
        root["input"] = kept
        return (try? JSONSerialization.data(withJSONObject: root)) ?? body
    }

    /// target 在第一个 `?` 处切开（query 可含后续任意字符）。
    private static func splitTarget(_ target: String) -> (path: String, query: String) {
        guard let questionMark = target.firstIndex(of: "?") else {
            return (target, "")
        }
        return (
            String(target[..<questionMark]),
            String(target[target.index(after: questionMark)...])
        )
    }
}
