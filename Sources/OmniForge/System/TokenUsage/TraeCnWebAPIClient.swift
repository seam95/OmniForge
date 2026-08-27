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
/// 请求参数镜像官方客户端观测值：`usage_type: [7]`（数组）+ 服务端页上限
/// `page_size ≤ 20`（超限会被拒绝或静默截断导致用量少计）。
/// 分页语义：串行翻页（页间 300ms 防限流）直到声明的 total 或空页；
/// 超过页数上限（容量超限）时按 [start,mid] + [mid+1,end] 递归二分。
/// HTTP 200 后仍校验业务 `code` 与 `total` 形状（fail-closed）。JWT 只进
/// 请求头，绝不落盘/入日志。
final class TraeCnWebAPIClient: TraeCnUsageFetching {
    static let endpoint = URL(string: "https://api.trae.cn/trae/api/v1/pay/query_user_usage_group_by_session")!

    var pageSize = 20
    var maxPages = 100
    var maxSplitDepth = 8
    var timeout: TimeInterval = 30
    /// 继续翻页时的页间延迟（纳秒），防止高频翻页被服务端限流。
    var pageDelayNanoseconds: UInt64 = 300_000_000

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
            page += 1
            try? await Task.sleep(nanoseconds: pageDelayNanoseconds)
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
            "usage_type": [7],
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
        // 业务 code：HTTP 200 但业务失败（凭证失效/参数错等）时仍带非 0 code。
        let businessCode = numeric(payload["code"]) ?? numeric(parsed["code"])
        if let businessCode, businessCode != 0 {
            throw LimitError.decoding("Trae CN usage API returned business code \(Int(businessCode))")
        }
        guard let sessionList = payload[apiCodeKey] as? [[String: Any]] else {
            throw LimitError.decoding("Trae CN usage API response is missing the session list")
        }
        let rows = sessionList.compactMap { raw -> TraeCnSessionRow? in
            guard let rowData = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? JSONDecoder().decode(TraeCnSessionRow.self, from: rowData)
        }
        // total 必须是安全非负整数：畸形值会让翻页提前终止造成用量少计（fail-closed）。
        var totalValue: Int?
        if let rawTotal = payload["total"] {
            guard let number = numeric(rawTotal), number >= 0,
                  number.truncatingRemainder(dividingBy: 1) == 0 else {
                throw LimitError.decoding("Trae CN usage API returned an invalid total")
            }
            totalValue = Int(number)
        }
        return (rows, totalValue)
    }

    private func numeric(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}