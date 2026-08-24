import Foundation

// MARK: - 协议边界

/// trae-cn 用量 API 取数边界（C 类云端；测试注入替身）。
protocol TraeCnUsageFetching: AnyObject {
    /// 拉取窗口内会话行（内部串行分页；容量超限自动二分）。
    /// - Parameters:
    ///   - jwt: Cloud-IDE-JWT 凭证。
    ///   - startMs / endMs: 半开窗口 [start, end) epoch 毫秒。
    func fetchSessions(jwt: String, startMs: Double, endMs: Double) async throws -> [TraeCnSessionRow]
}

/// 容量超限信号（窗口二分触发）。
enum TraeCnFetchError: Error {
    case capacityExceeded
}

// MARK: - URLSession 实现

/// 官方用量 API 客户端：POST `query_user_usage_group_by_session`，`Cloud-IDE-JWT` 头。
///
/// 分页语义（参考 TokenTracker fetchTraeCnUsage）：串行翻页直到声明的 total 或空页；
/// 超过页数上限（容量超限）时按 [start,mid] + [mid+1,end] 递归二分。JWT 只进
/// 请求头，绝不落盘/入日志。
final class TraeCnWebAPIClient: TraeCnUsageFetching {
    static let endpoint = URL(string: "https://api.trae.cn/trae/api/v1/pay/query_user_usage_group_by_session")!

    var pageSize = 100
    var maxPages = 20
    var maxSplitDepth = 3
    var timeout: TimeInterval = 20

    private let session: URLSession
    private let apiCodeKey = "user_usage_group_by_sessions"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSessions(jwt: String, startMs: Double, endMs: Double) async throws -> [TraeCnSessionRow] {
        try await fetchWindowed(jwt: jwt, startMs: startMs, endMs: endMs, depth: 0)
    }

    // MARK: - 窗口二分

    private func fetchWindowed(jwt: String, startMs: Double, endMs: Double, depth: Int) async throws -> [TraeCnSessionRow] {
        do {
            return try await fetchWindow(jwt: jwt, startMs: startMs, endMs: endMs)
        } catch TraeCnFetchError.capacityExceeded {
            guard endMs - startMs >= 1000, depth < maxSplitDepth else { throw TraeCnFetchError.capacityExceeded }
            let mid = startMs + (endMs - startMs) / 2
            let left = try await fetchWindowed(jwt: jwt, startMs: startMs, endMs: mid, depth: depth + 1)
            let right = try await fetchWindowed(jwt: jwt, startMs: mid + 1000, endMs: endMs, depth: depth + 1)
            return left + right
        }
    }

    private func fetchWindow(jwt: String, startMs: Double, endMs: Double) async throws -> [TraeCnSessionRow] {
        var all: [TraeCnSessionRow] = []
        var total: Int?
        var page = 1
        var pagesFetched = 0
        while true {
            guard pagesFetched < maxPages else { throw TraeCnFetchError.capacityExceeded }
            let result = try await fetchPage(jwt: jwt, startMs: startMs, endMs: endMs, page: page)
            pagesFetched += 1
            if pagesFetched == 1, let declared = result.total, declared > pageSize * maxPages {
                throw TraeCnFetchError.capacityExceeded
            }
            all.append(contentsOf: result.rows)
            if result.rows.isEmpty { break }
            if let declared = result.total, all.count >= declared { break }
            if total == nil { total = result.total }
            page += 1
        }
        return all
    }

    private func fetchPage(jwt: String, startMs: Double, endMs: Double, page: Int) async throws -> (rows: [TraeCnSessionRow], total: Int?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Cloud-IDE-JWT \(jwt.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "usage_type": "token",
            "start_time": Int(startMs / 1000),
            "end_time": Int(endMs / 1000),
            "page_num": page,
            "page_size": pageSize,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Trae CN usage request failed")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LimitError.reauthRequired
        }
        guard http.statusCode == 200 else {
            throw LimitError.network("Trae CN usage API returned HTTP \(http.statusCode)")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("Trae CN usage API returned a non-JSON response")
        }
        let payload = parsed["data"] as? [String: Any] ?? parsed
        guard let sessionList = payload[apiCodeKey] as? [[String: Any]] else {
            throw LimitError.decoding("Trae CN usage API response is missing the session list")
        }
        let rows = sessionList.compactMap { raw -> TraeCnSessionRow? in
            guard let rowData = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? JSONDecoder().decode(TraeCnSessionRow.self, from: rowData)
        }
        let totalValue = (payload["total"] as? NSNumber)?.intValue
        return (rows, totalValue)
    }
}