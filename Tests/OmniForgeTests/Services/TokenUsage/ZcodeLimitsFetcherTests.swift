import CryptoKit
import Foundation
import XCTest
@testable import OmniForge

/// zcode 限额 fetcher：套餐候选发现（setting/cache/config）、coding-plan quota
/// 取数、credentials.json 读取（明文 + enc:v1 双 base64 字母表解密）。
final class ZcodeLimitsFetcherTests: XCTestCase {
    private var homeDir: URL!
    private var fetcher: ZcodeLimitsFetcher!

    override func setUpWithError() throws {
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcodeLimitsFetcherTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        fetcher = ZcodeLimitsFetcher(session: URLProtocolStub.makeSession())
        fetcher.homeOverride = homeDir
    }

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
        try? FileManager.default.removeItem(at: homeDir)
    }

    // MARK: 本地文件写入

    private func writeJSON(_ json: String, relativePath: String) throws {
        let url = homeDir.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: url)
    }

    private func writeCredentials(_ json: String) throws {
        try writeJSON(json, relativePath: "v2/credentials.json")
    }

    // MARK: 加密 helper

    /// 用同款方案加密测试值（sha256(secret) → AES-256-GCM）；`urlSafe` 输出
    /// base64url 无 padding（与 zcode 写入格式一致）。secret 的 home 段固定为
    /// 用户主目录（与 homeOverride 无关）。
    private func encrypted(_ plaintext: String, urlSafe: Bool = false) throws -> String {
        let secret = "zcode-credential-fallback:darwin:"
            + FileManager.default.homeDirectoryForCurrentUser.path
            + ":\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        func encode(_ data: Data) -> String {
            guard urlSafe else { return data.base64EncodedString() }
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }
        return "enc:v1:\(encode(iv)).\(encode(sealed.tag)).\(encode(sealed.ciphertext))"
    }

    // MARK: 响应样例

    private func balanceJSON() -> Data {
        Data("""
        {"data":{"server_time":1784502000,"balances":[\
        {"show_name":"GLM-5.2","plan_id":"start-plan","total_units":100,"used_units":40,"remaining_units":60,"period_end":1787097600},\
        {"show_name":"GLM-5-Turbo","total_units":50,"used_units":10,"remaining_units":40,"period_end":1787097600}]}}
        """.utf8)
    }

    private func quotaJSON() -> Data {
        Data("""
        {"data":{"level":"Max","limits":[\
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":1,"percentage":2,"nextResetTime":"2026-08-27T11:24:39.878Z"},\
        {"type":"TOKENS_LIMIT","unit":6,"number":7,"usage":1,"percentage":2,"nextResetTime":"2026-09-02T05:53:47.998Z"},\
        {"type":"TIME_LIMIT","unit":5,"number":1,"usage":0,"percentage":1,"nextResetTime":"2026-09-01T05:53:47.997Z"}]}}
        """.utf8)
    }

    /// coding-plan 本地布局：setting 选中 + cache 可用 + config.json 明文 key。
    private func writeCodingPlanLayout(apiKey: String = "sk-config-key") throws {
        try writeJSON(
            #"{"modelProviderFamilySelectedKeys":{"bigmodel":"coding-plan:builtin:bigmodel-coding-plan"}}"#,
            relativePath: "v2/setting.json"
        )
        try writeJSON(
            #"{"entryStatus":{"items":{"builtin:bigmodel-coding-plan":{"status":"available"}}}}"#,
            relativePath: "v2/coding-plan-cache.json"
        )
        try writeJSON(
            #"{"provider":{"builtin:bigmodel-coding-plan":{"enabled":true,"options":{"apiKey":"\#(apiKey)","baseURL":"https://open.bigmodel.cn/api/anthropic"}}}}"#,
            relativePath: "v2/config.json"
        )
    }

    // MARK: - 凭据缺失 / 明文 / 解密

    func test_missingCredentials_returnsNil() async throws {
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty)
    }

    func test_plaintextJWT_buildsCreditsWindows() async throws {
        try writeCredentials(#"{"oauth:active_provider":"zai","zcodejwttoken":"jwt-plain"}"#)
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.windows[.credits]?.limit, 100, "主桶按 total 降序取最大")
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 40)
        XCTAssertEqual(result?.labeledWindows?.count, 1, "次桶 → labeled")
        XCTAssertEqual(result?.planLabel, "Start", "billing 主桶 plan_id → tier")
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-plain")
        XCTAssertEqual(request?.url?.absoluteString, "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")
    }

    func test_encryptedJWT_decryptedAndUsed() async throws {
        let jwt = try encrypted("jwt-secret-1")
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"\#(jwt)"}"#)
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-secret-1", "enc:v1 解密后取数")
    }

    func test_encryptedJWT_base64URLSafe_decryptedAndUsed() async throws {
        // 真实文件为 base64url 无 padding（含 -/_），须与标准 base64 兼容解码。
        let jwt = try encrypted("jwt-secret-2", urlSafe: true)
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"\#(jwt)"}"#)
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-secret-2", "base64url 载荷解密后取数")
    }

    func test_wrongActiveProvider_returnsNil() async throws {
        try writeCredentials(#"{"oauth:active_provider":"other","zcodejwttoken":"jwt"}"#)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
    }

    func test_badCredentials_returnsNil() async throws {
        try writeCredentials(#"{"oauth:active_provider":"zai","zcodejwttoken":"enc:v1:bad"}"#)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "解密失败 fail-soft → 未配置，不崩溃")
    }

    // MARK: - coding-plan quota 主链路

    func test_codingPlanLayout_fetchesQuotaWithConfigKey() async throws {
        try writeCodingPlanLayout()
        URLProtocolStub.stub = .init(statusCode: 200, data: quotaJSON())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.planLabel, "Max", "quota level → tier")
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 2, "5h 命名窗口 → session")
        XCTAssertEqual(result?.windows[.session]?.windowSeconds, 18000)
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent, 2, "周命名窗口 → weekly")
        XCTAssertEqual(result?.labeledWindows?.map(\.label), ["Tools"], "工具窗口 → labeled")
        XCTAssertEqual(result?.windows[.session]?.limit, nil, "percentage 口径不填绝对量")
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.url?.absoluteString, "https://bigmodel.cn/api/monitor/usage/quota/limit")
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "sk-config-key",
            "quota 鉴权头直接放 key，无 Bearer 前缀"
        )
    }

    func test_codingPlanQuota_401_throwsReauthRequired() async throws {
        try writeCodingPlanLayout()
        URLProtocolStub.stub = .init(statusCode: 401, data: Data("{\"code\":401}".utf8))
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("401 应抛 reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        }
    }

    func test_codingPlanUnavailable_skipsCandidate() async throws {
        try writeCodingPlanLayout()
        // 覆盖 cache：coding-plan 不可用且无任何凭据 → 无候选 → 未配置。
        try writeJSON(
            #"{"entryStatus":{"items":{"builtin:bigmodel-coding-plan":{"status":"unavailable"}}}}"#,
            relativePath: "v2/coding-plan-cache.json"
        )
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "不可用候选不发请求")
    }

    func test_codingPlanEmptyFallsBackToCredentialBilling() async throws {
        // coding 候选成功但窗口为空 → 继续 start-plan 凭据兜底候选。
        try writeCodingPlanLayout()
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"jwt-fallback"}"#)
        URLProtocolStub.handler = { request in
            let isQuota = request.url?.host == "bigmodel.cn"
            let data = isQuota ? Data(#"{"data":{"level":"Max","limits":[]}}"#.utf8) : self.balanceJSON()
            return .init(statusCode: 200, data: data)
        }
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.credits]?.limit, 100, "quota 空桶后回落 billing")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2)
        XCTAssertEqual(
            URLProtocolStub.recordedRequests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer jwt-fallback"
        )
    }

    // MARK: - 纯函数

    func test_selectedPlanProviderKeys_extractsFromDomains() {
        let setting: [String: Any] = [
            "providerFamilyDomain": "zai",
            "modelProviderFamilySelectedKeys": [
                "zai": "coding-plan:builtin:zai-coding-plan",
                "bigmodel": "coding-plan:builtin:bigmodel-coding-plan",
                "other": "whatever",
            ],
        ]
        XCTAssertEqual(
            ZcodeLimitsParsing.selectedPlanProviderKeys(fromSetting: setting),
            ["builtin:zai-coding-plan", "builtin:bigmodel-coding-plan"]
        )
        XCTAssertEqual(ZcodeLimitsParsing.selectedPlanProviderKeys(fromSetting: [:]), [])
    }

    func test_authCandidates_prioritizesSelectedAndFiltersAvailability() {
        let config: [String: Any] = [
            "provider": [
                "builtin:bigmodel-coding-plan": [
                    "enabled": true,
                    "options": ["apiKey": " sk-coding ", "baseURL": "https://open.bigmodel.cn/api/anthropic"],
                ] as [String: Any],
                "builtin:bigmodel-start-plan": [
                    "options": ["apiKey": "sk-start"],
                ] as [String: Any],
            ],
        ]
        let availability = ["builtin:bigmodel-coding-plan": "available"]
        let selected = ["builtin:bigmodel-coding-plan"]
        let candidates = ZcodeLimitsParsing.authCandidates(
            config: config,
            availability: availability,
            selectedKeys: selected,
            activeProvider: "bigmodel",
            jwt: "jwt-1"
        )
        XCTAssertEqual(candidates.first?.providerKey, "builtin:bigmodel-coding-plan")
        XCTAssertEqual(candidates.first?.kind, .codingPlan)
        XCTAssertEqual(candidates.first?.apiKey, "sk-coding", "coding-plan 用 config 明文 key（trim）")
        // start-plan 候选：active 匹配 bigmodel → 凭据 JWT 优先
        let start = candidates.first { $0.kind == .startPlan }
        XCTAssertEqual(start?.apiKey, "jwt-1")
    }

    func test_credentialFallbackCandidate_requiresMatchingDomain() {
        XCTAssertNotNil(ZcodeLimitsParsing.credentialFallbackCandidate(activeProvider: "zai", jwt: "j"))
        XCTAssertNil(ZcodeLimitsParsing.credentialFallbackCandidate(activeProvider: "other", jwt: "j"))
        XCTAssertNil(ZcodeLimitsParsing.credentialFallbackCandidate(activeProvider: "zai", jwt: nil))
    }

    func test_quotaResult_namedWindowsAndPlanTier() throws {
        let body = try JSONSerialization.jsonObject(with: quotaJSON()) as? [String: Any]
        let result = try ZcodeLimitsParsing.quotaResult(from: body)
        XCTAssertEqual(result.planLabel, "Max")
        XCTAssertEqual(result.windows[.session]?.usedPercent, 2)
        XCTAssertEqual(result.windows[.session]?.windowSeconds, 18000)
        XCTAssertEqual(result.windows[.weekly]?.windowSeconds, 604800)
        XCTAssertEqual(result.labeledWindows.map(\.label), ["Tools"])
        XCTAssertNotNil(result.windows[.session]?.resetAt, "nextResetTime ISO 字符串可解析")
    }

    func test_quotaResult_genericFallbackWithoutNamedWindows() throws {
        let body: [String: Any] = [
            "data": [
                "limits": [
                    ["type": "MIXED", "unit": 1, "number": 200, "usage": 50],
                    ["type": "MIXED", "unit": 2, "number": 100, "usage": 10],
                ],
            ],
        ]
        let result = try ZcodeLimitsParsing.quotaResult(from: body)
        XCTAssertEqual(result.windows[.credits]?.usedPercent, 25, "主桶按 number 降序")
        XCTAssertEqual(result.labeledWindows.map(\.label), ["secondary"])
    }

    func test_quotaResult_apiCodeError_throws() {
        XCTAssertThrowsError(try ZcodeLimitsParsing.quotaResult(from: ["code": 401, "msg": "expired"]))
        XCTAssertThrowsError(try ZcodeLimitsParsing.quotaResult(from: ["success": false]))
    }

    func test_planTier_extractsKnownTiers() {
        XCTAssertEqual(ZcodeLimitsParsing.planTier(from: "zcode-v3-start-plan-0615"), "Start")
        XCTAssertEqual(ZcodeLimitsParsing.planTier(from: "max"), "Max")
        XCTAssertNil(ZcodeLimitsParsing.planTier(from: "unknown-plan"))
        XCTAssertNil(ZcodeLimitsParsing.planTier(from: nil))
    }
}
