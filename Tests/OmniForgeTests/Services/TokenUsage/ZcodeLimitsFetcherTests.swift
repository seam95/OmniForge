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

    // MARK: - 设备标识请求头（服务端强制，缺失 → HTTP 400 code=3001）

    func test_balance_sendsDeviceMidFromOnboardingRecord() async throws {
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"jwt"}"#)
        let deviceMid = "E502069E-D9CE-493A-82E8-A584C3A0B13B"
        try writeJSON(#"{"deviceMid":"\#(deviceMid)"}"#, relativePath: "v2/onboarding-record.json")
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        _ = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(
            URLProtocolStub.recordedRequests.first?.value(forHTTPHeaderField: "X-Device-Mid"),
            deviceMid,
            "billing 请求必须带 X-Device-Mid（缺失时服务端返回 400）"
        )
    }

    func test_balance_fallsBackToTelemetryStateDeviceMid() async throws {
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"jwt"}"#)
        let deviceMid = "11111111-2222-3333-4444-555555555555"
        try writeJSON(#"{"deviceMid":"\#(deviceMid)"}"#, relativePath: "v2/telemetry-state.json")
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        _ = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(
            URLProtocolStub.recordedRequests.first?.value(forHTTPHeaderField: "X-Device-Mid"),
            deviceMid
        )
    }

    func test_balance_generatesDeviceMidWhenLocalFilesMissing() async throws {
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"jwt"}"#)
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        _ = try await fetcher.fetchLimits(force: false)
        let header = URLProtocolStub.recordedRequests.first?.value(forHTTPHeaderField: "X-Device-Mid")
        XCTAssertNotNil(header, "本地无 deviceMid 时也要生成合法值，不能空着发请求")
        XCTAssertNotNil(UUID(uuidString: header ?? ""), "生成的设备标识必须是 UUID 形态")
    }

    func test_deviceMid_ignoresMalformedValues() {
        XCTAssertNil(ZcodeLimitsParsing.deviceMid(
            fromOnboardingRecord: ["deviceMid": "not-a-uuid"],
            telemetryState: nil
        ))
        XCTAssertNil(ZcodeLimitsParsing.deviceMid(fromOnboardingRecord: nil, telemetryState: [:]))
        XCTAssertEqual(
            ZcodeLimitsParsing.deviceMid(
                fromOnboardingRecord: ["deviceMid": "invalid"],
                telemetryState: ["deviceMid": "11111111-2222-3333-4444-555555555555"]
            ),
            "11111111-2222-3333-4444-555555555555",
            "首个文件值非法时继续看下一个来源"
        )
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

    // MARK: - 当前布局：providerFamilyConnectionSelections

    func test_connectionSelectedKeys_mapsPlanKinds() {
        let setting: [String: Any] = [
            "providerFamilyConnectionSelections": ["bigmodel": ["kind": "individual-coding-plan"]],
        ]
        XCTAssertEqual(
            ZcodeLimitsParsing.connectionSelectedKeys(fromSetting: setting),
            ["builtin:bigmodel-coding-plan"]
        )

        let startPlan: [String: Any] = [
            "providerFamilyConnectionSelections": ["zai": ["kind": "start-plan"]],
        ]
        XCTAssertEqual(
            ZcodeLimitsParsing.connectionSelectedKeys(fromSetting: startPlan),
            ["builtin:zai-start-plan"]
        )
    }

    func test_connectionSelectedKeys_skipsTeamAndUnknownFamilies() {
        let setting: [String: Any] = [
            "providerFamilyConnectionSelections": [
                "bigmodel": ["kind": "team-coding-plan"],
                "zai": ["kind": "unknown-kind"],
                "other": ["kind": "start-plan"],
            ],
        ]
        XCTAssertEqual(
            ZcodeLimitsParsing.connectionSelectedKeys(fromSetting: setting),
            [],
            "团队套餐与未知域本期不取数"
        )
        XCTAssertEqual(ZcodeLimitsParsing.connectionSelectedKeys(fromSetting: [:]), [])
    }

    // MARK: - project key 解析

    private func projectKeyName(origin: String, family: String, team: Bool) -> String {
        let teamValue = team ? #"{"organizationId":"o","projectId":"p"}"# : "null"
        let json = #"["\#(origin)","\#(family)","36211748339318777",\#(teamValue),1,"non-team"]"#
        let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? json
        return ZcodeLimitsParsing.projectKeyLocationPrefix + encoded
    }

    func test_projectKeyLocation_parsesOriginAndFamily() {
        let key = projectKeyName(origin: "https://bigmodel.cn", family: "bigmodel", team: false)
        let location = ZcodeLimitsParsing.projectKeyLocation(fromKey: key)
        XCTAssertEqual(location?.origin, "https://bigmodel.cn")
        XCTAssertEqual(location?.family, "bigmodel")
        XCTAssertEqual(location?.team, false)
    }

    func test_projectKeyLocation_marksTeamPlan() {
        let key = projectKeyName(origin: "https://api.z.ai", family: "zai", team: true)
        let location = ZcodeLimitsParsing.projectKeyLocation(fromKey: key)
        XCTAssertEqual(location?.family, "zai")
        XCTAssertEqual(location?.team, true, "team 段非 null → 团队套餐")
    }

    func test_projectKeyLocation_rejectsMalformed() {
        XCTAssertNil(ZcodeLimitsParsing.projectKeyLocation(fromKey: "oauth:active_provider"))
        XCTAssertNil(ZcodeLimitsParsing.projectKeyLocation(
            fromKey: ZcodeLimitsParsing.projectKeyLocationPrefix + "not-json"
        ))
        let other = projectKeyName(origin: "https://example.com", family: "other", team: false)
        XCTAssertNil(ZcodeLimitsParsing.projectKeyLocation(fromKey: other), "未知域被拒绝")
    }

    func test_projectKeyMaterial_requiresAllFields() {
        XCTAssertNotNil(ZcodeLimitsParsing.projectKeyMaterial(fromValue: [
            "organizationId": "org-1", "projectId": "proj-1", "apiKeyId": "key-1",
        ]))
        XCTAssertNil(ZcodeLimitsParsing.projectKeyMaterial(fromValue: [
            "organizationId": "org-1", "projectId": "proj-1",
        ]), "缺 apiKeyId → nil")
        XCTAssertNil(ZcodeLimitsParsing.projectKeyMaterial(fromValue: [
            "organizationId": "org-1", "projectId": "proj-1", "apiKeyId": "  ",
        ]), "空白 apiKeyId 视为缺失")
    }

    func test_projectAccessTokenURL_buildsOrgProjectPath() {
        let location = ZcodeProjectKeyLocation(
            origin: "https://bigmodel.cn", family: "bigmodel", team: false
        )
        let material = ZcodeProjectKeyMaterial(
            organizationId: "org-1", projectId: "proj-1", apiKeyId: "key-1"
        )
        XCTAssertEqual(
            ZcodeLimitsParsing.projectAccessTokenURL(
                location: location, material: material
            )?.absoluteString,
            "https://bigmodel.cn/api/biz/v1/organization/org-1/projects/proj-1/api_keys/key-1/access_tokens"
        )
        XCTAssertEqual(
            ZcodeLimitsParsing.projectQuotaURL(origin: "https://bigmodel.cn")?.absoluteString,
            "https://bigmodel.cn/api/monitor/usage/quota/limit"
        )
    }

    func test_projectKeyCandidates_requiresSelectedKeyAndAccessToken() {
        let key = projectKeyName(origin: "https://bigmodel.cn", family: "bigmodel", team: false)
        let value = #"{"organizationId":"org-1","projectId":"proj-1","apiKeyId":"key-1"}"#
        let candidates = ZcodeLimitsParsing.projectKeyCandidates(
            entries: [(key: key, value: value)],
            selectedKeys: ["builtin:bigmodel-coding-plan"],
            accessTokens: ["bigmodel": "access-1"]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .codingPlan)
        XCTAssertEqual(candidates.first?.loginToken, "access-1")
        XCTAssertEqual(
            candidates.first?.quotaURL?.absoluteString,
            "https://bigmodel.cn/api/monitor/usage/quota/limit"
        )
        XCTAssertTrue(
            ZcodeLimitsParsing.projectKeyCandidates(
                entries: [(key: key, value: value)],
                selectedKeys: ["builtin:bigmodel-coding-plan"],
                accessTokens: [:]
            ).isEmpty,
            "缺 OAuth access token → 无候选"
        )
    }

    func test_projectKeyCandidates_skipsTeamPlanEntries() {
        let key = projectKeyName(origin: "https://bigmodel.cn", family: "bigmodel", team: true)
        let value = #"{"organizationId":"org-1","projectId":"proj-1","apiKeyId":"key-1"}"#
        XCTAssertTrue(
            ZcodeLimitsParsing.projectKeyCandidates(
                entries: [(key: key, value: value)],
                selectedKeys: [],
                accessTokens: ["bigmodel": "access-1"]
            ).isEmpty,
            "团队套餐本期不取数"
        )
    }

    // MARK: - project token 链路（当前布局）

    /// 写当前布局：connectionSelections 选中 coding-plan + project key + OAuth token。
    private func writeProjectKeyLayout(
        origin: String = "https://bigmodel.cn",
        family: String = "bigmodel"
    ) throws {
        try writeJSON(
            #"{"providerFamilyConnectionSelections":{"\#(family)":{"kind":"individual-coding-plan"}}}"#,
            relativePath: "v2/setting.json"
        )
        let rawJSON = #"["\#(origin)","\#(family)","36211748339318777",null,1,"non-team"]"#
        let encoded = rawJSON.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rawJSON
        let keyName = ZcodeLimitsParsing.projectKeyLocationPrefix + encoded
        let valueJSON = #"{\"organizationId\":\"org-1\",\"projectId\":\"proj-1\",\"apiKeyId\":\"key-1\"}"#
        try writeCredentials(
            #"{"oauth:active_provider":"\#(family)","oauth:\#(family):access_token":"access-plain","\#(keyName)":"\#(valueJSON)"}"#
        )
    }

    private func projectTokenJSON(_ token: String = "project-token-1") -> Data {
        Data(#"{"code":200,"data":{"accessToken":"\#(token)","expiresIn":2200}}"#.utf8)
    }

    func test_codingPlan_issuesProjectTokenThenFetchesQuota() async throws {
        try writeProjectKeyLayout()
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/access_tokens") {
                return .init(statusCode: 200, data: self.projectTokenJSON())
            }
            return .init(statusCode: 200, data: self.quotaJSON())
        }
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 2, "project token → quota 命名窗口")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "先签发 token 再取 quota")

        let issue = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(issue?.httpMethod, "POST")
        XCTAssertEqual(
            issue?.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-plain",
            "签发用 OAuth access token"
        )
        XCTAssertTrue(issue?.url?.path.hasSuffix("/api_keys/key-1/access_tokens") == true)

        let quota = URLProtocolStub.recordedRequests.last
        XCTAssertEqual(
            quota?.value(forHTTPHeaderField: "Authorization"),
            "project-token-1",
            "quota 头直接放 project token，无 Bearer"
        )
    }

    func test_codingPlan_reusesProjectTokenWithinCache() async throws {
        try writeProjectKeyLayout()
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/access_tokens") {
                return .init(statusCode: 200, data: self.projectTokenJSON())
            }
            return .init(statusCode: 200, data: self.quotaJSON())
        }
        _ = try await fetcher.fetchLimits(force: true)
        _ = try await fetcher.fetchLimits(force: true)
        let issueCount = URLProtocolStub.recordedRequests
            .filter { $0.url?.path.hasSuffix("/access_tokens") == true }
            .count
        XCTAssertEqual(issueCount, 1, "token 有效期内复用，只签发一次")
    }

    func test_codingPlan_tokenIssueFailure_throwsNetwork() async throws {
        try writeProjectKeyLayout()
        URLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/access_tokens") {
                return .init(statusCode: 500, data: Data())
            }
            return .init(statusCode: 200, data: self.quotaJSON())
        }
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("签发失败应抛错")
        } catch let error as LimitError {
            guard case .network = error else {
                return XCTFail("应为 network，实际 \(error)")
            }
        }
    }
}
