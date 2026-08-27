import Foundation
import XCTest
@testable import OmniForge

/// TraeCnWebAPIClient：请求参数（usage_type 数组/页上限）、业务 code 与
/// total 的 fail-closed 校验、翻页终止与 401 语义。
final class TraeCnWebAPIClientTests: XCTestCase {
    private var client: TraeCnWebAPIClient!

    override func setUpWithError() throws {
        client = TraeCnWebAPIClient(session: URLProtocolStub.makeSession())
        client.pageDelayNanoseconds = 0 // 测试不等待页间延迟
    }

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
    }

    private func pageBody(rows: [[String: Any]], total: Any? = nil, code: Any? = nil) -> Data {
        var data: [String: Any] = [
            "user_usage_group_by_sessions": rows,
        ]
        if let total { data["total"] = total }
        if let code { data["code"] = code }
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }

    private func row(id: String, tokens: Double) -> [String: Any] {
        ["session_id": id, "model_name": "doubao", "usage_time": 1_784_500_000, "output_token": tokens]
    }

    private func recordedBody(_ index: Int) throws -> [String: Any] {
        let data = URLProtocolStub.recordedBodies[index]
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func test_requestBody_mirrorsOfficialClient() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: pageBody(rows: [row(id: "s1", tokens: 10)], total: 1))
        _ = try await client.fetchSessions(jwt: "jwt-1", startMs: 1_000_000, endMs: 2_000_000)
        let body = try recordedBody(0)
        XCTAssertEqual(body["usage_type"] as? [Int], [7], "usage_type 为数组 [7]（官方客户端观测值）")
        XCTAssertEqual(body["page_size"] as? Int, 20, "服务端页上限 20")
        XCTAssertEqual(body["page_num"] as? Int, 1)
        XCTAssertEqual(body["start_time"] as? Int, 1_000)
        XCTAssertEqual(body["end_time"] as? Int, 2_000)
        let request = URLProtocolStub.recordedRequests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Cloud-IDE-JWT jwt-1")
    }

    func test_businessCodeNonZero_throwsDecoding() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: pageBody(rows: [], total: 0, code: 401))
        do {
            _ = try await client.fetchSessions(jwt: "jwt-1", startMs: 0, endMs: 1000)
            XCTFail("HTTP 200 + 业务 code 非 0 应报错")
        } catch let error as LimitError {
            guard case .decoding = error else { return XCTFail("应为 decoding，实际 \(error)") }
        }
    }

    func test_invalidTotal_failClosed() async throws {
        for badTotal: Any? in [-1, 1.5, "12"] {
            URLProtocolStub.reset()
            URLProtocolStub.stub = .init(statusCode: 200, data: pageBody(rows: [row(id: "s1", tokens: 1)], total: badTotal))
            do {
                _ = try await client.fetchSessions(jwt: "jwt-1", startMs: 0, endMs: 1000)
                XCTFail("畸形 total \(String(describing: badTotal)) 应 fail-closed")
            } catch let error as LimitError {
                guard case .decoding = error else { return XCTFail("应为 decoding，实际 \(error)") }
            }
        }
    }

    func test_paginationStopsAtDeclaredTotal() async throws {
        URLProtocolStub.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: URLProtocolStub.requestBody(request)) as! [String: Any]
            let page = body["page_num"] as? Int ?? 0
            let rows = page == 1 ? [self.row(id: "s1", tokens: 1), self.row(id: "s2", tokens: 2)]
                : [self.row(id: "s3", tokens: 3)]
            return .init(statusCode: 200, data: self.pageBody(rows: rows, total: 3))
        }
        let rows = try await client.fetchSessions(jwt: "jwt-1", startMs: 0, endMs: 1000)
        XCTAssertEqual(rows.count, 3, "两页收齐 3 行后按 total 终止")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2)
    }

    func test_http401_throwsReauth() async throws {
        URLProtocolStub.stub = .init(statusCode: 401, data: Data())
        do {
            _ = try await client.fetchSessions(jwt: "jwt-1", startMs: 0, endMs: 1000)
            XCTFail("401 应抛 reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        }
    }
}
