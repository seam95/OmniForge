import XCTest
@testable import OmniForge

/// Desktop 聚合投影写入器：代理 origin + gateway token 落盘、inferenceModels 形态
/// （映射卡对象条目含 prefer1m / 直连卡 identity 纯字符串 / 成员发布 labelOverride）、
/// 200 截断、有成员写 modelDiscoveryEnabled: false、摘要一致性。
final class AggregationClaudeDesktopConfigWriterTests: XCTestCase {
    private var tmpDir: URL!
    private var store: ClaudeDesktopSettingsStore!
    private var writer: AggregationClaudeDesktopConfigWriter!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationClaudeDesktopConfigWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let profileURL = tmpDir.appendingPathComponent("profile.json")
        store = ClaudeDesktopSettingsStore(
            configURL: tmpDir.appendingPathComponent("config.json"),
            config3PURL: tmpDir.appendingPathComponent("config3p.json"),
            profileURL: profileURL,
            metaURL: tmpDir.appendingPathComponent("_meta.json"),
            pendingURL: tmpDir.appendingPathComponent("pending.json")
        )
        writer = AggregationClaudeDesktopConfigWriter(
            store: store,
            profileReader: {
                guard let data = try? Data(contentsOf: profileURL),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return [:]
                }
                return object
            }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func readProfile() throws -> [String: Any] {
        let url = tmpDir.appendingPathComponent("profile.json")
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any])
    }

    private func readInferenceModels(_ profile: [String: Any]) throws -> [Any] {
        try XCTUnwrap(profile["inferenceModels"] as? [Any])
    }

    private let mappingCard = ProviderProfile(
        id: "glm", name: "智谱", tool: .claudeDesktop,
        baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm",
        desktopModelRoutes: [
            "claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: true),
            "claude-opus-5": DesktopModelRoute(model: "glm-5.3", labelOverride: "GLM 旗舰", supports1M: false),
        ]
    )

    private let directCard = ProviderProfile(
        id: "relay", name: "中转站", tool: .claudeDesktop,
        baseURL: "https://relay.example/api/anthropic", token: "sk-relay"
    )

    private func memberPublished(key: String, model: String, oneM: Bool = false) -> AggregationPublishedModel {
        AggregationPublishedModel(
            tool: .claudeDesktop, key: key, profileName: "Kimi",
            model: model, upstream: model, displayName: model,
            oneM: oneM, window: 0
        )
    }

    func test_applyAggregation_writesProxyOriginAndGatewayToken() throws {
        try writer.applyAggregation(
            defaultProfile: mappingCard, memberPublished: [], port: 15721, gatewayToken: "ccs-token"
        )
        let profile = try readProfile()
        XCTAssertEqual(profile["inferenceGatewayBaseUrl"] as? String, "http://127.0.0.1:15721/claude-desktop")
        XCTAssertEqual(profile["inferenceGatewayApiKey"] as? String, "ccs-token")
        XCTAssertEqual(profile["inferenceGatewayAuthScheme"] as? String, "bearer")
    }

    func test_mappingCardSlots_prefer1mWrittenWithSupports1m() throws {
        try writer.applyAggregation(
            defaultProfile: mappingCard, memberPublished: [], port: 15721, gatewayToken: "ccs-t"
        )
        let models = try readInferenceModels(try readProfile())
        XCTAssertEqual(models.count, 2, "只写已配置的档")
        let sonnet = try XCTUnwrap(models[0] as? [String: Any])
        XCTAssertEqual(sonnet["name"] as? String, "claude-sonnet-5")
        XCTAssertEqual(sonnet["supports1m"] as? Bool, true)
        XCTAssertEqual(sonnet["prefer1m"] as? Bool, true, "prefer1m 必须随 supports1m 一起写")
        let opus = try XCTUnwrap(models[1] as? [String: Any])
        XCTAssertEqual(opus["labelOverride"] as? String, "GLM 旗舰")
        XCTAssertNil(opus["supports1m"], "未配 1M 的档不写该键 → 用对象形态只因 labelOverride")
    }

    func test_directDefaultCard_writesFourIdentitySlotsAsPlainStrings() throws {
        try writer.applyAggregation(
            defaultProfile: directCard, memberPublished: [], port: 15721, gatewayToken: "ccs-t"
        )
        let models = try readInferenceModels(try readProfile())
        XCTAssertEqual(models.count, 4)
        for (index, expected) in ClaudeDesktopSettingsStore.defaultRoutes.enumerated() {
            XCTAssertEqual(models[index] as? String, expected, "直连卡默认写四档 identity 纯字符串")
        }
        let profile = try readProfile()
        XCTAssertNil(profile["modelDiscoveryEnabled"], "无成员时不写该键")
    }

    func test_memberPublishedEntries_getLabelOverrideAnd1M() throws {
        let published = [
            memberPublished(key: "kimi", model: "k3", oneM: true),
            memberPublished(key: "kimi", model: "k3-flash"),
        ]
        try writer.applyAggregation(
            defaultProfile: directCard, memberPublished: published, port: 15721, gatewayToken: "ccs-t"
        )
        let profile = try readProfile()
        XCTAssertEqual(profile["modelDiscoveryEnabled"] as? Bool, false, "有成员时模型列表完全由 profile 决定")
        let models = try readInferenceModels(profile)
        XCTAssertEqual(models.count, 6, "四档 identity + 2 条成员发布")
        let member1 = try XCTUnwrap(models[4] as? [String: Any])
        XCTAssertEqual(member1["name"] as? String, published[0].id)
        XCTAssertEqual(member1["labelOverride"] as? String, published[0].label, "labelOverride = 供应商 / 模型名")
        XCTAssertEqual(member1["supports1m"] as? Bool, true)
        XCTAssertEqual(member1["prefer1m"] as? Bool, true)
        let member2 = try XCTUnwrap(models[5] as? [String: Any])
        XCTAssertNil(member2["supports1m"])
    }

    func test_inferenceModelsTruncatedAt200() throws {
        let many = (0..<250).map { memberPublished(key: "k\($0)", model: "m\($0)") }
        let models = AggregationClaudeDesktopConfigWriter.inferenceModels(
            defaultProfile: directCard, memberPublished: many
        )
        XCTAssertEqual(models.count, AggregationClaudeDesktopConfigWriter.inferenceModelsLimit)
    }

    func test_digestMatchesAfterApply() throws {
        let args = (defaultProfile: mappingCard, memberPublished: [memberPublished(key: "kimi", model: "k3")], port: UInt16(15721), gatewayToken: "ccs-t")
        let projected = writer.projectedContractDigest(
            defaultProfile: args.defaultProfile,
            memberPublished: args.memberPublished,
            port: args.port,
            gatewayToken: args.gatewayToken
        )
        try writer.applyAggregation(
            defaultProfile: args.defaultProfile,
            memberPublished: args.memberPublished,
            port: args.port,
            gatewayToken: args.gatewayToken
        )
        XCTAssertEqual(writer.currentContractDigest(), projected, "写入后磁盘摘要与投影摘要一致（未变更不重写闸门）")
    }
}
