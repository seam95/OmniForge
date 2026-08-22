import XCTest
@testable import OmniForge

final class CredentialReaderTests: XCTestCase {
    // MARK: - JWT payload 解码

    func test_decodePayload_secondSegment() throws {
        let payload = #"{"sub":"u1","subscriptionType":"pro"}"#
        let token = makeJWT(payload: payload)
        let decoded = try XCTUnwrap(JWTPayloadDecoder.decodePayload(token))
        XCTAssertEqual(decoded["subscriptionType"] as? String, "pro")
        XCTAssertEqual(decoded["sub"] as? String, "u1")
    }

    func test_decodePayload_malformedReturnsNil() {
        XCTAssertNil(JWTPayloadDecoder.decodePayload("not-a-jwt"))
        XCTAssertNil(JWTPayloadDecoder.decodePayload("a.b.c.d"))
        XCTAssertNil(JWTPayloadDecoder.decodePayload(""))
    }

    func test_decodeBase64URL_handlesPaddingAndURLChars() throws {
        // "ab~" 的 base64url 变体（含 URL 安全字符）
        let data = try XCTUnwrap(JWTPayloadDecoder.decodeBase64URL("YWJ-"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "ab~")
    }

    // MARK: - 套餐名清洗

    func test_normalize_knownPlansCapitalized() {
        XCTAssertEqual(PlanLabelNormalizer.normalize("max"), "Max")
        XCTAssertEqual(PlanLabelNormalizer.normalize("PRO"), "Pro")
        XCTAssertEqual(PlanLabelNormalizer.normalize("free"), "Free")
    }

    func test_normalize_sentinelValuesToNil() {
        XCTAssertNil(PlanLabelNormalizer.normalize("none"))
        XCTAssertNil(PlanLabelNormalizer.normalize("unknown"))
        XCTAssertNil(PlanLabelNormalizer.normalize("invalid"))
        XCTAssertNil(PlanLabelNormalizer.normalize(""))
        XCTAssertNil(PlanLabelNormalizer.normalize(nil))
    }

    func test_normalize_unknownRawCapitalized() {
        XCTAssertEqual(PlanLabelNormalizer.normalize("team"), "Team")
        XCTAssertEqual(PlanLabelNormalizer.normalize("business"), "Business")
    }

    // MARK: - 工具

    /// 造一个只有 payload 段有效的 JWT（header/signature 随便）。
    private func makeJWT(payload: String) -> String {
        func base64URL(_ value: String) -> String {
            value
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data(#"{"alg":"none"}"#.utf8).base64EncodedString())
        let body = base64URL(Data(payload.utf8).base64EncodedString())
        return "\(header).\(body).sig"
    }
}
