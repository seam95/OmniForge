import Foundation

/// 代理侧 HTTP 请求（已解析的头 + 收齐的体）。
struct AggregationHTTPRequest: Equatable {
    let head: AggregationRequestHead
    let body: Data
}
