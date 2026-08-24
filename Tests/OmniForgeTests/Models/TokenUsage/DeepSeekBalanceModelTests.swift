import Foundation
import XCTest
@testable import OmniForge

/// DeepSeek 余额模型：/user/balance 解码（防御式：字符串金额、多币种、缺失字段）、
/// 金额解析、CNY 口径低余额判定与设置解码兼容。
final class DeepSeekBalanceModelTests: XCTestCase {
    // MARK: - 解码

    func test_decode_fullPayloadParsesAllFields() {
        let response = decode([
            "is_available": true,
            "balance_infos": [
                ["currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"],
            ],
        ])
        XCTAssertEqual(response.isAvailable, true)
        XCTAssertEqual(response.infos.count, 1)
        XCTAssertEqual(response.infos[0].currency, "CNY")
        XCTAssertEqual(response.infos[0].totalBalance, Decimal(string: "110.00"))
        XCTAssertEqual(response.infos[0].grantedBalance, Decimal(string: "10.00"))
        XCTAssertEqual(response.infos[0].toppedUpBalance, Decimal(string: "100.00"))
        XCTAssertEqual(response.infos[0].totalBalanceText, "110.00")
    }

    func test_decode_isAvailableFalse() {
        let response = decode(["is_available": false, "balance_infos": []])
        XCTAssertEqual(response.isAvailable, false)
        XCTAssertEqual(response.infos.count, 0)
    }

    func test_decode_missingBalanceInfosReturnsNil() {
        XCTAssertNil(DeepSeekBalanceResponseDecoder.decode(["is_available": true]), "缺 balance_infos → 解码失败")
        XCTAssertNil(DeepSeekBalanceResponseDecoder.decode(["is_available": true, "balance_infos": "x"]), "非数组 → 解码失败")
    }

    func test_decode_invalidAmountKeepsRawTextAndNilDecimal() {
        let response = decode([
            "is_available": true,
            "balance_infos": [["currency": "CNY", "total_balance": "garbage"]],
        ])
        XCTAssertNil(response.infos[0].totalBalance)
        XCTAssertEqual(response.infos[0].totalBalanceText, "garbage", "解析失败保留原始字符串兜底")
        XCTAssertNil(response.infos[0].grantedBalance, "缺失字段 → nil 不兜底")
    }

    func test_decode_multipleCurrenciesPreservesOrder() {
        let response = decode([
            "is_available": true,
            "balance_infos": [
                ["currency": "CNY", "total_balance": "1.00"],
                ["currency": "USD", "total_balance": "2.00"],
            ],
        ])
        XCTAssertEqual(response.infos.map(\.currency), ["CNY", "USD"], "原序保留")
    }

    // MARK: - 金额解析

    func test_parseAmount_parsesPlainDecimal() {
        XCTAssertEqual(DeepSeekAmountParsing.parse("110.00"), Decimal(string: "110"))
        XCTAssertEqual(DeepSeekAmountParsing.parse("0.5"), Decimal(string: "0.5"))
    }

    func test_parseAmount_trimsWhitespace() {
        XCTAssertEqual(DeepSeekAmountParsing.parse(" 12.30 "), Decimal(string: "12.3"))
    }

    func test_parseAmount_negativeValue() {
        XCTAssertEqual(DeepSeekAmountParsing.parse("-3.00"), Decimal(string: "-3"))
    }

    func test_parseAmount_garbageReturnsNil() {
        XCTAssertNil(DeepSeekAmountParsing.parse("abc"))
    }

    func test_parseAmount_emptyReturnsNil() {
        XCTAssertNil(DeepSeekAmountParsing.parse(""))
        XCTAssertNil(DeepSeekAmountParsing.parse("   "))
    }

    // MARK: - 低余额判定

    private func response(cny: String?, usd: String? = nil, isAvailable: Bool = true) -> DeepSeekBalanceResponse {
        var infos: [DeepSeekBalanceInfo] = []
        if let cny {
            infos.append(DeepSeekBalanceInfo(currency: "CNY", totalBalance: DeepSeekAmountParsing.parse(cny), grantedBalance: nil, toppedUpBalance: nil, totalBalanceText: cny))
        }
        if let usd {
            infos.append(DeepSeekBalanceInfo(currency: "USD", totalBalance: DeepSeekAmountParsing.parse(usd), grantedBalance: nil, toppedUpBalance: nil, totalBalanceText: usd))
        }
        return DeepSeekBalanceResponse(isAvailable: isAvailable, infos: infos)
    }

    func test_cnyTotal_picksCNYEntry() {
        XCTAssertEqual(DeepSeekLowBalanceEvaluator.cnyTotal(in: response(cny: "18.22", usd: "3.00")), Decimal(string: "18.22"))
    }

    func test_cnyTotal_missingCNYReturnsNil() {
        XCTAssertNil(DeepSeekLowBalanceEvaluator.cnyTotal(in: response(cny: nil, usd: "3.00")))
        XCTAssertNil(DeepSeekLowBalanceEvaluator.cnyTotal(in: response(cny: nil, usd: nil)))
    }

    func test_crossedThreshold_equalToThresholdFires() {
        XCTAssertTrue(
            DeepSeekLowBalanceEvaluator.crossedThreshold(in: response(cny: "1.00"), threshold: 1.0),
            "等于阈值即触发（≤）"
        )
    }

    func test_crossedThreshold_aboveDoesNotFire() {
        XCTAssertFalse(DeepSeekLowBalanceEvaluator.crossedThreshold(in: response(cny: "1.01"), threshold: 1.0))
    }

    func test_crossedThreshold_usesCNYOnly_ignoresUSD() {
        XCTAssertTrue(
            DeepSeekLowBalanceEvaluator.crossedThreshold(in: response(cny: "0.50", usd: "999.00"), threshold: 1.0),
            "USD 再高也不影响 CNY 判定"
        )
    }

    func test_crossedThreshold_firesWhenUnavailable() {
        XCTAssertTrue(
            DeepSeekLowBalanceEvaluator.crossedThreshold(in: response(cny: "0.20", isAvailable: false), threshold: 1.0),
            "is_available=false 不拦截（正是余额耗尽场景）"
        )
    }

    func test_crossedThreshold_unparseableCnyDoesNotFire() {
        XCTAssertFalse(
            DeepSeekLowBalanceEvaluator.crossedThreshold(in: response(cny: nil), threshold: 1.0),
            "CNY 金额解析失败 → 不做判定"
        )
    }

    // MARK: - 设置解码

    func test_settingsDecoding_legacyAbsentFieldDefaults() {
        let data = try! JSONEncoder().encode(["lowBalanceAlertEnabled": false])
        let settings = try! JSONDecoder().decode(DeepSeekBalanceSettings.self, from: data)
        XCTAssertEqual(settings.lowBalanceAlertEnabled, false)
        XCTAssertEqual(settings.lowBalanceThreshold, 1.0, "缺阈值 → 默认")
        XCTAssertEqual(settings.refreshMinutes, 5, "缺间隔 → 默认")
    }

    func test_settingsDecoding_presentFieldRoundTrips() {
        var settings = DeepSeekBalanceSettings()
        settings.lowBalanceAlertEnabled = false
        settings.lowBalanceThreshold = 10
        settings.refreshMinutes = 15
        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(DeepSeekBalanceSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func test_settings_defaults() {
        let settings = DeepSeekBalanceSettings()
        XCTAssertEqual(settings.lowBalanceAlertEnabled, true, "默认告警开")
        XCTAssertEqual(settings.lowBalanceThreshold, 1.0, "默认阈值 ¥1")
        XCTAssertEqual(settings.refreshMinutes, 5, "默认 5 分钟")
    }

    func test_allowedRefreshIntervals_matchTokenUsageConfiguration() {
        XCTAssertEqual(
            DeepSeekBalanceSettings.allowedRefreshIntervals,
            TokenUsageConfiguration.allowedRefreshIntervals,
            "余额与限额刷新间隔合法值应保持一致，防漂移"
        )
    }

    // MARK: - 工具

    private func decode(_ dict: [String: Any]) -> DeepSeekBalanceResponse {
        DeepSeekBalanceResponseDecoder.decode(dict)!
    }
}
