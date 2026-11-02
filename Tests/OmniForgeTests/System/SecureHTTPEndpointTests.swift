import XCTest
@testable import OmniForge

/// 共享端点安全校验：HTTPS 强制（回环放行 http）、组件拒绝、path 拼接。
/// 规则自 AITranslationService 原样迁移，供 PromptOptimizer 与 Translation 共用。
final class SecureHTTPEndpointTests: XCTestCase {
    /// 两个服务共用的 chat/completions 端点 path。
    private let chatCompletionsPath = "/chat/completions"

    // MARK: - 拒绝（表驱动）

    func test_endpointURL_rejectsInsecureOrMalformedBaseURLs() {
        let rejected: [(baseURL: String, reason: String)] = [
            // 远程明文 HTTP 必须拒绝：Bearer key 不得明文发出。
            ("http://api.example.com", "远程明文 HTTP 必须拒绝"),
            ("http://api.example.com/v1", "远程明文 HTTP 带 path 同样拒绝"),
            // query / fragment / 内嵌凭据可能把密钥与参数带进日志，直接拒绝。
            ("https://api.example.com/v1?q=1", "带 query 必须拒绝"),
            ("https://api.example.com/v1#section", "带 fragment 必须拒绝"),
            ("https://user:pass@api.example.com/v1", "内嵌凭据必须拒绝"),
            // scheme 与 host 校验。
            ("ftp://api.example.com/v1", "非 http/https scheme 必须拒绝"),
            ("api.example.com/v1", "缺 scheme 必须拒绝"),
            ("https:///v1", "空 host 必须拒绝"),
            // 空值与非法字符串。
            ("", "空字符串必须拒绝"),
            ("   ", "纯空白必须拒绝"),
            ("not a url", "非 URL 字符串必须拒绝"),
        ]
        for entry in rejected {
            XCTAssertThrowsError(
                try SecureHTTPEndpoint.endpointURL(baseURL: entry.baseURL, path: chatCompletionsPath),
                "\(entry.reason)：\(entry.baseURL)"
            ) { error in
                XCTAssertEqual(
                    error as? SecureHTTPEndpointError,
                    .invalidConfiguration,
                    "错误类型应为 SecureHTTPEndpointError.invalidConfiguration"
                )
            }
        }
    }

    // MARK: - 放行与拼接（表驱动）

    func test_endpointURL_allowsLoopbackHTTPAndAppendsPath() throws {
        let accepted: [(baseURL: String, expected: String, reason: String)] = [
            // 本机回环地址允许明文 HTTP，便于本机无鉴权服务。
            ("http://127.0.0.1:8080", "http://127.0.0.1:8080/chat/completions", "IPv4 回环 + 端口放行并拼接 path"),
            ("http://localhost", "http://localhost/chat/completions", "localhost 回环放行并拼接 path"),
            ("http://localhost:8080/v1", "http://localhost:8080/v1/chat/completions", "localhost 带 path 放行并拼接"),
            ("http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/chat/completions", "IPv4 回环带 path 放行并拼接"),
            ("http://[::1]:8080/v1", "http://[::1]:8080/v1/chat/completions", "IPv6 回环放行并拼接 path"),
            // 远程地址必须 HTTPS。
            ("https://x.y/v1", "https://x.y/v1/chat/completions", "HTTPS 基础拼接"),
        ]
        for entry in accepted {
            let url = try SecureHTTPEndpoint.endpointURL(baseURL: entry.baseURL, path: chatCompletionsPath)
            XCTAssertEqual(url.absoluteString, entry.expected, entry.reason)
        }
    }

    func test_endpointURL_keepsCompletePathVerbatimAndTrimsInput() throws {
        // 已含完整端点时不重复追加。
        let verbatim = try SecureHTTPEndpoint.endpointURL(
            baseURL: "https://x.y/v1/chat/completions",
            path: chatCompletionsPath
        )
        XCTAssertEqual(verbatim.absoluteString, "https://x.y/v1/chat/completions")

        // 首尾空白与尾斜杠被清理后再拼接。
        let trimmed = try SecureHTTPEndpoint.endpointURL(
            baseURL: "  https://x.y/v1//  ",
            path: chatCompletionsPath
        )
        XCTAssertEqual(trimmed.absoluteString, "https://x.y/v1/chat/completions")
    }
}
