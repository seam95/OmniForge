import Foundation
import XCTest
@testable import OmniForge

/// DeepSeek 余额卡：状态派生优先级（错误 > 低阈值 > 不可用 > 正常）、
/// 状态文案与金额/脚注格式化。
final class DeepSeekBalanceCardStateTests: XCTestCase {
    private let strings = L10n().s

    // MARK: - 状态派生

    func test_derive_reauthPrecedence() {
        let snapshot = snapshot(issue: .reauthRequired, cny: "0.10")
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .reauth, "密钥失效优先于低余额")
    }

    func test_derive_rateLimitedPrecedence() {
        let snapshot = snapshot(issue: .rateLimited(retryAt: Date(timeIntervalSince1970: 1_800_000_360)), cny: "0.10")
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .rateLimited)
    }

    func test_derive_stalePrecedenceOverBelowThreshold() {
        let snapshot = snapshot(issue: .network("offline"), cny: "0.10", stale: true)
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .stale, "保留旧值的回退优先显示 stale")
    }

    func test_derive_transientWhenNoDataAndIssue() {
        let snapshot = snapshot(issue: .decoding("bad"), cny: nil, stale: false)
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .transient)
    }

    func test_derive_belowThresholdPriorityOverUnavailable() {
        let snapshot = snapshot(isAvailable: false, cny: "0.20")
        XCTAssertEqual(
            DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0),
            .belowThreshold,
            "低于阈值优先于不可用（正是余额耗尽场景）"
        )
    }

    func test_derive_unavailableWhenNotAvailableAndAboveThreshold() {
        let snapshot = snapshot(isAvailable: false, cny: "18.22")
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .unavailable)
    }

    func test_derive_normalFreshAboveThreshold() {
        let snapshot = snapshot(isAvailable: true, cny: "18.22")
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .normal)
    }

    func test_derive_noCnyNeverBelowThreshold() {
        let snapshot = snapshot(isAvailable: true, cny: nil)
        XCTAssertEqual(DeepSeekBalanceCardState.derive(snapshot: snapshot, threshold: 1.0), .normal, "无 CNY → 不做低余额判定")
    }

    // MARK: - 状态文案

    func test_labels_localizedPerState() {
        XCTAssertEqual(DeepSeekBalanceCardState.normal.label(strings), strings.tokenStatusNormal)
        XCTAssertEqual(DeepSeekBalanceCardState.belowThreshold.label(strings), strings.deepSeekStatusBelowThreshold)
        XCTAssertEqual(DeepSeekBalanceCardState.unavailable.label(strings), strings.deepSeekBalanceUnavailable)
        XCTAssertEqual(DeepSeekBalanceCardState.reauth.label(strings), strings.deepSeekStatusReauthKey)
        XCTAssertEqual(DeepSeekBalanceCardState.rateLimited.label(strings), strings.tokenStatusRateLimited)
        XCTAssertEqual(DeepSeekBalanceCardState.stale.label(strings), strings.tokenStatusStale)
        XCTAssertEqual(DeepSeekBalanceCardState.transient.label(strings), strings.tokenErrorTransient)
    }

    // MARK: - 金额格式化

    func test_formatAmount_currencySymbols() {
        XCTAssertEqual(DeepSeekBalanceFormat.currencySymbol("CNY"), "¥")
        XCTAssertEqual(DeepSeekBalanceFormat.currencySymbol("USD"), "$")
        XCTAssertEqual(DeepSeekBalanceFormat.currencySymbol("ZZZ"), "ZZZ ")
    }

    func test_formatAmount_twoDecimalsPadded() {
        XCTAssertEqual(
            DeepSeekBalanceFormat.amount(Decimal(string: "110"), rawText: nil, currency: "CNY"),
            "¥110.00"
        )
        XCTAssertEqual(
            DeepSeekBalanceFormat.amount(Decimal(string: "0.5"), rawText: nil, currency: "USD"),
            "$0.50"
        )
    }

    func test_formatAmount_nilFallsBackToRawText() {
        XCTAssertEqual(
            DeepSeekBalanceFormat.amount(nil, rawText: "garbage", currency: "CNY"),
            "¥garbage"
        )
    }

    func test_formatAmount_nothingRendersSymbolOnly() {
        XCTAssertEqual(DeepSeekBalanceFormat.amount(nil, rawText: nil, currency: "CNY"), "¥")
    }

    // MARK: - 脚注

    func test_footerText_officialSourceAndRelativeUpdate() {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DeepSeekBalanceSnapshot(
            configured: true,
            isAvailable: true,
            infos: [cnyInfo("18.22")],
            capturedAt: capturedAt,
            stale: false,
            issue: nil
        )
        let footer = String(
            format: strings.deepSeekBalanceFooterFormat,
            strings.tokenSourceOfficial,
            TokenUsageFormat.relativeUpdate(capturedAt, now: capturedAt, strings: strings)
        )
        XCTAssertEqual(footer, "官方来源 · 刚刚更新", "取值口径与限额卡脚注一致")
        XCTAssertTrue(footer.contains(strings.tokenSourceOfficial))
    }

    // MARK: - 工具

    private func snapshot(
        issue: LimitError? = nil,
        isAvailable: Bool = true,
        cny: String? = "18.22",
        stale: Bool = false
    ) -> DeepSeekBalanceSnapshot {
        DeepSeekBalanceSnapshot(
            configured: true,
            isAvailable: isAvailable,
            infos: cny.map { [cnyInfo($0)] } ?? [],
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            stale: stale,
            issue: issue
        )
    }

    private func cnyInfo(_ total: String) -> DeepSeekBalanceInfo {
        DeepSeekBalanceInfo(
            currency: "CNY",
            totalBalance: DeepSeekAmountParsing.parse(total),
            grantedBalance: nil,
            toppedUpBalance: nil,
            totalBalanceText: total
        )
    }
}
