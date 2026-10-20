import XCTest
@testable import OmniForge

/// OpenCode Go 网关要求（cc-switch #7773）：稳定会话头与 UA 兜底。
final class OpenCodeGatewayTests: XCTestCase {
    private let openCodeBase = "https://opencode.ai/inference/go/openai/v1"

    // MARK: - fixtures

    private func responsesBody(
        instructions: String = "You are Codex.",
        firstUser: String = "hello",
        extraTurns: Int = 0
    ) -> Data {
        var input: [[String: Any]] = [
            ["type": "message", "role": "user",
             "content": [["type": "input_text", "text": firstUser]]],
        ]
        for index in 0..<extraTurns {
            input.append(["type": "message", "role": "assistant",
                          "content": [["type": "output_text", "text": "turn \(index)"]]])
            input.append(["type": "message", "role": "user",
                          "content": [["type": "input_text", "text": "follow \(index)"]]])
        }
        let object: [String: Any] = ["model": "grok-4.7", "instructions": instructions, "input": input]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func rewritten(
        _ headers: [String: String],
        base: String? = "https://opencode.ai/inference/go/openai/v1",
        body: Data? = nil,
        protocol: AggregationClientProtocol = .openAIResponses
    ) -> [String: String] {
        AggregationUpstream.rewrittenHeaders(
            headers,
            credential: "sk-real",
            protocol: `protocol`,
            upstreamBase: base,
            body: body
        )
    }

    // MARK: - host 判定

    func test_isOpenCodeUpstream_matchesHostAndSubdomains() {
        XCTAssertTrue(AggregationUpstream.isOpenCodeUpstream(openCodeBase))
        XCTAssertTrue(AggregationUpstream.isOpenCodeUpstream("https://api.opencode.ai/v1"))
        XCTAssertTrue(AggregationUpstream.isOpenCodeUpstream("https://opencode.ai:443/inference/go/anthropic"))
        XCTAssertFalse(AggregationUpstream.isOpenCodeUpstream("https://opencode.com/v1"))
        XCTAssertFalse(AggregationUpstream.isOpenCodeUpstream("https://evil-opencode.ai/v1"))
        XCTAssertFalse(AggregationUpstream.isOpenCodeUpstream("https://api.openai.com/v1"))
        XCTAssertFalse(AggregationUpstream.isOpenCodeUpstream(nil))
    }

    // MARK: - 会话头

    func test_rewrittenHeaders_injectsNativeSessionHeaderBeforeStripping() {
        let headers = ["session_id": "session-1", "authorization": "Bearer PROXY_MANAGED"]
        let out = rewritten(headers, body: responsesBody())
        XCTAssertEqual(out["x-opencode-session"], "session-1", "优先复用客户端原生会话头")
        XCTAssertNil(out["session_id"], "身份头仍按第三方目标规则剥除")
    }

    func test_rewrittenHeaders_keepsClientProvidedSessionHeader() {
        let headers = ["x-opencode-session": "client-session", "session_id": "other"]
        let out = rewritten(headers)
        XCTAssertEqual(out["x-opencode-session"], "client-session")
    }

    func test_rewrittenHeaders_usesConversationFingerprintWhenNoSessionHeader() throws {
        let body = responsesBody(firstUser: "你好")
        let first = rewritten(["authorization": "Bearer PROXY_MANAGED"], body: body)
        let session = try XCTUnwrap(first["x-opencode-session"])
        XCTAssertTrue(session.hasPrefix("om-"))

        // 同一会话下一轮（历史变长、首条 user 不变）应保持同一 id。
        let nextTurn = rewritten(["authorization": "Bearer PROXY_MANAGED"], body: responsesBody(firstUser: "你好", extraTurns: 2))
        XCTAssertEqual(nextTurn["x-opencode-session"], session, "同一会话跨轮稳定")

        // 不同会话（首条 user 不同）必须区分。
        let other = rewritten(["authorization": "Bearer PROXY_MANAGED"], body: responsesBody(firstUser: "另一个会话"))
        XCTAssertNotEqual(other["x-opencode-session"], session)
    }

    func test_fingerprintIgnoresCacheControl() {
        let plain: [String: Any] = [
            "model": "qwen3.8-max",
            "system": [["type": "text", "text": "You are helpful."]],
            "messages": [["role": "user", "content": [["type": "text", "text": "hi"]]]],
        ]
        var marked = plain
        marked["system"] = [["type": "text", "text": "You are helpful.",
                             "cache_control": ["type": "ephemeral"]]]
        marked["messages"] = [["role": "user", "content": [[
            "type": "text", "text": "hi", "cache_control": ["type": "ephemeral"],
        ]]]]

        let first = AggregationUpstream.conversationFingerprint(try! JSONSerialization.data(withJSONObject: plain))
        let second = AggregationUpstream.conversationFingerprint(try! JSONSerialization.data(withJSONObject: marked))
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "cache_control 位置变化不得改变指纹")
    }

    func test_anthropicBodyFingerprintUsesSystemAndFirstUser() throws {
        let body: [String: Any] = [
            "system": "You are Claude Code.",
            "messages": [
                ["role": "user", "content": [["type": "text", "text": "fix the bug"]]],
                ["role": "assistant", "content": [["type": "text", "text": "ok"]]],
                ["role": "user", "content": [["type": "text", "text": "more"]]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let out = rewritten(["x-api-key": "PROXY_MANAGED"], body: data, protocol: .anthropicMessages)
        let session = try XCTUnwrap(out["x-opencode-session"])
        XCTAssertTrue(session.hasPrefix("om-"))
    }

    func test_fallsBackToGeneratedIDWhenBodyHasNoConversation() {
        let out = rewritten(["authorization": "Bearer PROXY_MANAGED"], body: Data(#"{"model":"grok-4.7"}"#.utf8))
        let session = out["x-opencode-session"]
        XCTAssertTrue(session?.hasPrefix("om-") ?? false)
        XCTAssertFalse(session?.isEmpty ?? true)

        // 无可用身份时两次请求各自生成（网关只要求存在，不强求跨轮一致）。
        let another = rewritten(["authorization": "Bearer PROXY_MANAGED"], body: nil)
        XCTAssertNotEqual(another["x-opencode-session"], session)
    }

    // MARK: - User-Agent

    func test_userAgentFallbackOnlyWhenMissing() {
        let missing = rewritten(["authorization": "Bearer PROXY_MANAGED"])
        XCTAssertTrue((missing["user-agent"] ?? "").hasPrefix("OmniForge/"))

        let present = rewritten(["user-agent": "codex_cli_rs/0.161.0"])
        XCTAssertEqual(present["user-agent"], "codex_cli_rs/0.161.0")
    }

    // MARK: - 非 OpenCode 上游

    func test_nonOpenCodeUpstreamGetsNoSessionOrUserAgent() {
        let out = rewritten(
            ["authorization": "Bearer PROXY_MANAGED", "session_id": "session-1"],
            base: "https://api.deepseek.com/v1"
        )
        XCTAssertNil(out["x-opencode-session"])
        XCTAssertNil(out["user-agent"], "非 opencode 上游不补 UA")
        XCTAssertNil(out["session_id"])
    }
}
