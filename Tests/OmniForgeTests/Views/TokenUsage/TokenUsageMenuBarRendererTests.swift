import XCTest
import AppKit
@testable import OmniForge

/// 菜单栏「今日 tokens」贡献（#06）：纯逻辑 — 数值缩写 / 块映射 / 宽度预留。
final class TokenUsageMenuBarRendererTests: XCTestCase {

    // MARK: - 数值格式化（菜单栏口径，SPEC 4.4「如 128k」）

    func test_menubarTokens_truncatesDecimalsToIntegerScaledValue() {
        XCTAssertEqual(TokenUsageFormat.menubarTokens(128_400), "128k")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(0), "0")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(849), "849")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(1_024), "1k")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(999_999), "999k")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(1_000_000), "1m")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(12_500_000), "12m")
        XCTAssertEqual(TokenUsageFormat.menubarTokens(-128_400), "-128k")
    }

    func test_menubarTokens_keepsPanelFormatterUnchangedForDecimals() {
        XCTAssertEqual(TokenUsageFormat.tokens(128_400), "128.4k")
    }

    // MARK: - 块映射（标题合成：隐藏 / 今日 tokens / 会话窗 % 预留）

    func test_render_hiddenMode_showsNothingEvenWithUsageData() {
        let render = TokenUsageMenuBarRenderer.render(
            isFeatureAvailable: true,
            overview: makeOverview(total: 128_400),
            mode: .hidden,
            label: "今日"
        )
        XCTAssertNil(render.block)
        XCTAssertFalse(render.isVisible)
    }

    func test_render_featureUnavailable_showsNothing() {
        let render = TokenUsageMenuBarRenderer.render(
            isFeatureAvailable: false,
            overview: makeOverview(total: 128_400),
            mode: .todayTokens,
            label: "今日"
        )
        XCTAssertNil(render.block)
        XCTAssertFalse(render.isVisible)
    }

    func test_render_noUsageData_showsNothingInsteadOfZeroPlaceholder() {
        let render = TokenUsageMenuBarRenderer.render(
            isFeatureAvailable: true,
            overview: nil,
            mode: .todayTokens,
            label: "今日"
        )
        XCTAssertNil(render.block, "无数据时整体隐藏，不渲染 0k 占位")
        XCTAssertFalse(render.isVisible)
    }

    func test_render_todayTokens_buildsMetricBlockWithLabelAndReservedWidth() {
        let render = TokenUsageMenuBarRenderer.render(
            isFeatureAvailable: true,
            overview: makeOverview(total: 128_400),
            mode: .todayTokens,
            label: "今日"
        )
        XCTAssertEqual(render.block?.label, "今日")
        XCTAssertEqual(render.block?.value, "128k")
        XCTAssertEqual(render.block?.minimumValue, "999k")
        XCTAssertTrue(render.isVisible)
    }

    func test_render_sessionPercent_reservedForLaterTicket() {
        // 会话窗用量 % 依赖限额数据（#10 落地）；本票渲染结构预留开关分支，不产出块。
        let render = TokenUsageMenuBarRenderer.render(
            isFeatureAvailable: true,
            overview: makeOverview(total: 128_400),
            mode: .sessionPercent,
            label: "会话窗"
        )
        XCTAssertNil(render.block)
        XCTAssertFalse(render.isVisible)
    }

    // MARK: - attributed title 与 minimumValue 宽度预留

    func test_attributedTitle_forTodayBlock_hasAttachmentContent() {
        let block = MenuBarMetricRenderer.MetricBlock(
            label: "今日",
            value: "128k",
            minimumValue: "999k"
        )
        let title = MenuBarMetricRenderer.attributedTitle(for: block)
        XCTAssertGreaterThan(title.length, 0)
        XCTAssertGreaterThan(title.size().width, 0)
    }

    func test_todayBlockWidth_isStableAcrossMenubarTokenValues() {
        // minimumValue "999k" 预留整数 k/m 口径最宽 4 字符，数值变化不抖动。
        let small = MenuBarMetricRenderer.metricBlockImage(
            label: "今日",
            value: "1k",
            minimumValue: "999k",
            spacing: .standard
        )
        let large = MenuBarMetricRenderer.metricBlockImage(
            label: "今日",
            value: "999k",
            minimumValue: "999k",
            spacing: .standard
        )
        XCTAssertEqual(small.size.width, large.size.width, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(small.size.width, MenuBarMetricLayout.minItemWidth)
    }

    // MARK: - Helpers

    private func makeOverview(total: Int) -> TokenUsageOverview {
        TokenUsageOverview(totalTokens: total, conversations: 0, daily: [], peak: nil)
    }
}
