import XCTest
@testable import OmniForge

/// 契约摘要：Claude 侧只对拥有键取值（键序/无关键不参与、拥有键变化即变）；
/// Codex 侧顶层拥有键 + custom 表（剥 requires_openai_auth）+ 目录字节三部分，
/// 注释空行不参与、目录指针/内容变化即变、登录态抖动不变。
final class AggregationContractDigestTests: XCTestCase {
    func test_claudeDigest_isStableForEquivalentProjections() {
        let a: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15721", "ANTHROPIC_AUTH_TOKEN": "PROXY_MANAGED"],
                                "modelPicker": ["replaceBuiltInOptions": true]]
        let b: [String: Any] = ["modelPicker": ["replaceBuiltInOptions": true],
                                "env": ["ANTHROPIC_AUTH_TOKEN": "PROXY_MANAGED", "ANTHROPIC_BASE_URL": "http://127.0.0.1:15721"]]
        XCTAssertEqual(AggregationContractDigest.claude(projectedRoot: a), AggregationContractDigest.claude(projectedRoot: b))
    }

    func test_claudeDigest_ignoresUnrelatedKeys() {
        let base: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15721"]]
        let withNoise: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15721", "SOME_USER_KEY": "x"],
                                        "permissions": ["allow": ["Bash"]]]
        XCTAssertEqual(AggregationContractDigest.claude(projectedRoot: base),
                       AggregationContractDigest.claude(projectedRoot: withNoise))
    }

    func test_claudeDigest_changesWhenOwnedKeyChanges() {
        let a: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15721"]]
        let b: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15722"]]
        XCTAssertNotEqual(AggregationContractDigest.claude(projectedRoot: a), AggregationContractDigest.claude(projectedRoot: b))
    }

    func test_codexDigest_changesWhenCatalogPointerChanges() {
        XCTAssertNotEqual(AggregationContractDigest.codex(configText: "model_catalog_json = \"a.json\"\n", catalogData: nil),
                          AggregationContractDigest.codex(configText: "model_catalog_json = \"b.json\"\n", catalogData: nil))
    }

    func test_codexDigest_ignoresCommentAndBlankLineNoise() {
        XCTAssertEqual(AggregationContractDigest.codex(configText: "# note\nmodel = \"m\"\n", catalogData: nil),
                       AggregationContractDigest.codex(configText: "model = \"m\"\n", catalogData: nil))
    }

    func test_codexDigest_changesWhenCatalogContentChanges() {
        let config = "model_catalog_json = \"omniforge-stack-catalog.json\"\n"
        XCTAssertNotEqual(AggregationContractDigest.codex(configText: config, catalogData: Data("v1".utf8)),
                          AggregationContractDigest.codex(configText: config, catalogData: Data("v2".utf8)))
    }

    func test_codexDigest_ignoresRequiresOpenAIAuthFlapping() {
        let withTrue = "requires_openai_auth = true\n"
        let withFalse = "requires_openai_auth = false\n"
        XCTAssertEqual(AggregationContractDigest.codex(configText: withTrue, catalogData: nil),
                       AggregationContractDigest.codex(configText: withFalse, catalogData: nil))
    }
}
