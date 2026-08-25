import XCTest
@testable import OmniForge

final class VolcengineSigV4SignerTests: XCTestCase {
    func test_sign_generatesExpectedHeaders() {
        let signer = VolcengineSigV4Signer(region: "cn-beijing", service: "ark")
        let credentials = ArkCredentials(accessKeyId: "AKTEST123", secretAccessKey: "SKTEST456")
        let url = URL(string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")!
        let request = URLRequest(url: url)
        let date = Date(timeIntervalSince1970: 1700000000) // 2023-11-14T22:13:20Z

        let signed = signer.sign(request: request, credentials: credentials, date: date)

        XCTAssertEqual(signed.value(forHTTPHeaderField: "Host"), "open.volcengineapi.com")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-Date"), "20231114T221320Z")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-Content-Sha256"), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let authHeader = signed.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authHeader.hasPrefix("HMAC-SHA256 Credential=AKTEST123/20231114/cn-beijing/ark/request"))
        XCTAssertTrue(authHeader.contains("SignedHeaders=host;x-content-sha256;x-date"))
        XCTAssertTrue(authHeader.contains("Signature="))
    }

    func test_emptyCredentials_returnsOriginalRequest() {
        let signer = VolcengineSigV4Signer()
        let request = URLRequest(url: URL(string: "https://open.volcengineapi.com")!)
        let signed = signer.sign(request: request, credentials: ArkCredentials(accessKeyId: "", secretAccessKey: ""))
        XCTAssertNil(signed.value(forHTTPHeaderField: "Authorization"))
    }
}
