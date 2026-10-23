import XCTest
@testable import OmniForge

/// 请求级追踪只记元数据：模型、目标、状态、耗时、字节数、重试次数；不落 body/token。
final class AggregationRequestTraceTests: XCTestCase {
    private func makeRequest(_ body: String) -> AggregationHTTPRequest {
        AggregationHTTPRequest(
            head: AggregationRequestHead(
                method: "POST",
                path: "/v1/responses",
                query: "",
                headers: ["x-client-request-id": "req-1"],
                contentLength: body.utf8.count
            ),
            body: Data(body.utf8)
        )
    }

    func test_spanRecordsMetadataOnly() {
        let trace = AggregationRequestTrace()
        trace.reset()
        let request = makeRequest(#"{"model":"om-kimi/k3","input":"secret prompt"}"#)
        let target = AggregationProxyTarget(
            key: "kimi", profileID: "kimi",
            baseURL: "https://api.kimi.com/v1", token: "sk-secret"
        )

        let span = trace.begin(request: request, target: target, protocol: .openAIResponses)
        span.setStatus(200)
        span.addResponseBytes(42)
        span.noteRetry()
        trace.finish(span)

        let entry = trace.recent().last
        XCTAssertEqual(entry?.id, "req-1")
        XCTAssertEqual(entry?.requestedModel, "om-kimi/k3")
        XCTAssertEqual(entry?.upstreamKey, "kimi")
        XCTAssertEqual(entry?.upstreamHost, "api.kimi.com")
        XCTAssertEqual(entry?.statusCode, 200)
        XCTAssertEqual(entry?.responseBytes, 42)
        XCTAssertEqual(entry?.retries, 1)
        XCTAssertEqual(entry?.requestBytes, request.body.count)

        let dumped = String(describing: entry)
        XCTAssertFalse(dumped.contains("secret prompt"), "不得记录请求体")
        XCTAssertFalse(dumped.contains("sk-secret"), "不得记录凭证")
    }

    func test_finishIsIdempotentAndCapacityKeepsRecent() {
        let trace = AggregationRequestTrace()
        trace.reset()
        let request = makeRequest(#"{"model":"m"}"#)
        let target = AggregationProxyTarget(
            key: "k", profileID: "p", baseURL: "https://relay.example.com", token: ""
        )

        let span = trace.begin(request: request, target: target, protocol: .openAIResponses)
        trace.finish(span)
        trace.finish(span)
        XCTAssertEqual(trace.recent().count, 1, "重复 finish 不重复入队")

        for _ in 0..<205 {
            let s = trace.begin(request: request, target: target, protocol: .openAIResponses)
            trace.finish(s)
        }
        XCTAssertLessThanOrEqual(trace.recent().count, 200)
    }

    func test_localMissIsRecordedWithZeroTiming() {
        let trace = AggregationRequestTrace()
        trace.reset()
        trace.recordLocal(
            request: makeRequest(#"{"model":"om-gone/x"}"#),
            protocol: .openAIResponses,
            statusCode: 400
        )
        let entry = trace.recent().last
        XCTAssertEqual(entry?.statusCode, 400)
        XCTAssertEqual(entry?.upstreamKey, "-")
        XCTAssertEqual(entry?.durationMs, 0)
    }
}
