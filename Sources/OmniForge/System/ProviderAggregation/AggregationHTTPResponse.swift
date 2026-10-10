import Foundation

/// 代理侧 HTTP 响应（回写给客户端或上游透传）。
struct AggregationHTTPResponse: Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}
