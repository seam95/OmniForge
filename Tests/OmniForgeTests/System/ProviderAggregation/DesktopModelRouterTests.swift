import XCTest
@testable import OmniForge

/// Desktop 模型名改写：透传（直连卡）、精确映射、opus 别名、角色回落（fable 降 opus）、
/// 未配置明确错误、[1m] 标记剥离。
final class DesktopModelRouterTests: XCTestCase {
    private let mappingCard: [String: DesktopModelRoute] = [
        "claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
        "claude-opus-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
        "claude-haiku-4-5": DesktopModelRoute(model: "glm-5.3-flash", labelOverride: nil, supports1M: false),
        "claude-fable-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
    ]

    func test_noMappingCard_passesThroughClaudeSafeNamesVerbatim() {
        // 直连卡：Claude-safe 名原样透传——绝不能按四档 identity 改写
        // （带日期后缀的名会被错改成档名，上游 404；SPEC 机制事实）。
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-sonnet-4-20250514", routes: nil),
            .passthrough("claude-sonnet-4-20250514")
        )
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-sonnet-5", routes: [:]),
            .passthrough("claude-sonnet-5")
        )
    }

    /// 审查回归锁：无映射卡的直连上游也只对 Claude-safe 名透传；
    /// 非 safe 名必须明确报错（对齐 cc-switch route_unknown），不静默发给上游。
    func test_noMappingCard_rejectsNonClaudeSafeNames() {
        XCTAssertEqual(DesktopModelRouter.route(model: "gpt-5", routes: nil), .unconfigured("gpt-5"))
        XCTAssertEqual(DesktopModelRouter.route(model: "glm-5.3", routes: [:]), .unconfigured("glm-5.3"))
    }

    func test_mappingCard_exactLookupRewritesUpstreamName() {
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-sonnet-5", routes: mappingCard),
            .rewritten("glm-5.3")
        )
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-haiku-4-5", routes: mappingCard),
            .rewritten("glm-5.3-flash")
        )
    }

    func test_mappingCard_opusAliasResolves() {
        // claude-opus-4-8 精确未命中 → 别名 claude-opus-5 → 命中。
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-opus-4-8", routes: mappingCard),
            .rewritten("glm-5.3")
        )
    }

    func test_mappingCard_roleFallbackForDatedNames() {
        // 带日期的 sonnet 名精确未命中 → 按角色回落到 sonnet 档。
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-sonnet-4-20250514", routes: mappingCard),
            .rewritten("glm-5.3")
        )
    }

    func test_mappingCard_fableFallsBackToOpusWhenUnconfigured() {
        var withoutFable = mappingCard
        withoutFable.removeValue(forKey: "claude-fable-5")
        // fable 未配置 → 降级 opus 档。
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-fable-5", routes: withoutFable),
            .rewritten("glm-5.3")
        )
    }

    func test_mappingCard_unconfiguredRoleIsExplicitError() {
        var onlySonnet = [
            "claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
        ]
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-haiku-4-5", routes: onlySonnet),
            .unconfigured("claude-haiku-4-5")
        )
        _ = onlySonnet
    }

    func test_oneMMarkerIsStrippedBeforeRouting() {
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-sonnet-5[1M]", routes: mappingCard),
            .rewritten("glm-5.3")
        )
        XCTAssertEqual(
            DesktopModelRouter.route(model: "claude-sonnet-5[1m]", routes: nil),
            .passthrough("claude-sonnet-5")
        )
    }
}
