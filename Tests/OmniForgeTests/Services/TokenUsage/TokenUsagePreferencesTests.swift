import XCTest
@testable import OmniForge

final class TokenUsagePreferencesTests: XCTestCase {
    func test_defaults() {
        let config = TokenUsageConfiguration()
        XCTAssertEqual(config.menuBarMode, .todayTokens)
        XCTAssertEqual(config.limitRefreshMinutes, 5)
        XCTAssertEqual(config.limitsDisplayMode, .used)
        XCTAssertEqual(config.trendPeriodDefault, .month)
        XCTAssertTrue(config.sessionLimitAlertEnabled)
        XCTAssertTrue(config.paceOverrunAlertEnabled)
    }

    func test_persistence_roundTrip() {
        let suite = "TokenUsagePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        preferences.update {
            $0.menuBarMode = .sessionPercent
            $0.limitRefreshMinutes = 15
            $0.limitsDisplayMode = .remaining
            $0.trendPeriodDefault = .total
            $0.sessionLimitAlertEnabled = false
        }

        let reloaded = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.menuBarMode, .sessionPercent)
        XCTAssertEqual(reloaded.configuration.limitRefreshMinutes, 15)
        XCTAssertEqual(reloaded.configuration.limitsDisplayMode, .remaining)
        XCTAssertEqual(reloaded.configuration.trendPeriodDefault, .total)
        XCTAssertFalse(reloaded.configuration.sessionLimitAlertEnabled)
        XCTAssertTrue(reloaded.configuration.paceOverrunAlertEnabled)
    }

    func test_invalidRefreshInterval_rejected() {
        let suite = "TokenUsagePreferencesTestsInvalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertThrowsError(try preferences.setLimitRefreshMinutes(3))
        XCTAssertEqual(preferences.configuration.limitRefreshMinutes, 5)
        XCTAssertNoThrow(try preferences.setLimitRefreshMinutes(1))
        XCTAssertNoThrow(try preferences.setLimitRefreshMinutes(5))
        XCTAssertNoThrow(try preferences.setLimitRefreshMinutes(15))
    }

    func test_paceAlertDisabled_roundTrip() {
        let suite = "TokenUsagePreferencesTestsPace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        preferences.update { $0.paceOverrunAlertEnabled = false }

        let reloaded = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertFalse(reloaded.configuration.paceOverrunAlertEnabled)
        XCTAssertTrue(reloaded.configuration.sessionLimitAlertEnabled)
    }

    func test_deepSeekSettings_defaultsAndRoundTrip() {
        let suite = "TokenUsagePreferencesTestsDeepSeek.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        // 未显式配置 → 计算属性兜底默认值
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.lowBalanceAlertEnabled, true)
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold, 1.0)
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.refreshMinutes, 5)

        preferences.setDeepSeekLowBalanceAlertEnabled(false)
        preferences.setDeepSeekThreshold(10)
        try? preferences.setDeepSeekRefreshMinutes(15)

        let reloaded = TokenUsagePreferences(userDefaults: defaults)
        let settings = reloaded.configuration.deepSeekBalanceSettings
        XCTAssertFalse(settings.lowBalanceAlertEnabled)
        XCTAssertEqual(settings.lowBalanceThreshold, 10)
        XCTAssertEqual(settings.refreshMinutes, 15)
    }

    func test_deepSeekConfig_legacyDataWithoutKeyKeepsExistingSettings() {
        // 旧配置没有 deepSeekBalance 键 → 解码仍成功，既有设置不丢，余额设置走默认。
        let suite = "TokenUsagePreferencesTestsDeepSeekLegacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = """
        {"menuBarMode":"todayTokens","limitRefreshMinutes":15,"limitsDisplayMode":"remaining",
         "usagePeriodDefault":"today","sessionLimitAlertEnabled":false,"paceOverrunAlertEnabled":false}
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "OmniForge.tokenUsageConfiguration")

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.configuration.limitRefreshMinutes, 15)
        XCTAssertFalse(preferences.configuration.sessionLimitAlertEnabled)
        XCTAssertEqual(preferences.configuration.deepSeekBalance, nil, "旧数据无余额键 → nil")
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold, 1.0)
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.refreshMinutes, 5)
    }

    func test_deepSeekConfig_partialSettingsFallbackToDefaults() {
        // deepSeekBalance 键存在但缺部分字段 → 不拖垮整包解码，缺失字段回默认。
        let suite = "TokenUsagePreferencesTestsDeepSeekPartial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let partial = """
        {"menuBarMode":"todayTokens","limitRefreshMinutes":5,"limitsDisplayMode":"used",
         "usagePeriodDefault":"today","sessionLimitAlertEnabled":true,"paceOverrunAlertEnabled":true,
         "deepSeekBalance":{"lowBalanceAlertEnabled":false}}
        """.data(using: .utf8)!
        defaults.set(partial, forKey: "OmniForge.tokenUsageConfiguration")

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.lowBalanceAlertEnabled, false)
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold, 1.0, "缺阈值 → 默认")
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.refreshMinutes, 5, "缺间隔 → 默认")
    }

    func test_deepSeekRefreshInterval_rejected() {
        let suite = "TokenUsagePreferencesTestsDeepSeekInterval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertThrowsError(try preferences.setDeepSeekRefreshMinutes(3))
        XCTAssertEqual(preferences.configuration.deepSeekBalanceSettings.refreshMinutes, 5)
        XCTAssertNoThrow(try preferences.setDeepSeekRefreshMinutes(1))
        XCTAssertNoThrow(try preferences.setDeepSeekRefreshMinutes(15))
    }

    func test_trendPeriodDefaultRoundTrip_acrossAllPeriods() {
        let suite = "TokenUsagePreferencesTestsPeriod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        for period in TokenTrendPeriod.allCases {
            preferences.update { $0.trendPeriodDefault = period }
            let reloaded = TokenUsagePreferences(userDefaults: defaults)
            XCTAssertEqual(reloaded.configuration.trendPeriodDefault, period)
        }
    }

    func test_corruptData_fallsBackToDefaults() {
        let suite = "TokenUsagePreferencesTestsCorrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "OmniForge.tokenUsageConfiguration")

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.configuration, TokenUsageConfiguration())
    }

    func test_providerOrder_defaultsToAllCases() {
        let config = TokenUsageConfiguration()
        XCTAssertEqual(config.providerOrder, TokenUsageProvider.allCases)
        XCTAssertNil(config.providerOrderStored)
    }

    func test_providerOrder_moveAndPersistenceRoundTrip() {
        let suite = "TokenUsagePreferencesTestsOrder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        let initialFirst = preferences.configuration.providerOrder.first!
        let initialSecond = preferences.configuration.providerOrder[1]

        // 将第一项下移
        preferences.moveProvider(initialFirst, delta: 1)
        XCTAssertEqual(preferences.configuration.providerOrder[0], initialSecond)
        XCTAssertEqual(preferences.configuration.providerOrder[1], initialFirst)

        // 重新加载验证持久化
        let reloaded = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.providerOrder[0], initialSecond)
        XCTAssertEqual(reloaded.configuration.providerOrder[1], initialFirst)

        // 越界移动保护（首项上移、末项下移不崩溃且不变）
        let firstItem = reloaded.configuration.providerOrder.first!
        let lastItem = reloaded.configuration.providerOrder.last!
        reloaded.moveProvider(firstItem, delta: -1)
        reloaded.moveProvider(lastItem, delta: 1)
        XCTAssertEqual(reloaded.configuration.providerOrder.first, firstItem)
        XCTAssertEqual(reloaded.configuration.providerOrder.last, lastItem)
    }

    func test_providerOrder_legacyConfigWithoutKey_returnsAllCases() {
        let suite = "TokenUsagePreferencesTestsOrderLegacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = """
        {"menuBarMode":"todayTokens","limitRefreshMinutes":5,"limitsDisplayMode":"used"}
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "OmniForge.tokenUsageConfiguration")

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.configuration.providerOrder, TokenUsageProvider.allCases)
    }

    func test_providerOrder_partialList_appendsMissingProviders() {
        var config = TokenUsageConfiguration()
        // 用户自定义了前三个
        config.providerOrder = [.kimi, .antigravity, .codex]
        let order = config.providerOrder

        XCTAssertEqual(order[0], .kimi)
        XCTAssertEqual(order[1], .antigravity)
        XCTAssertEqual(order[2], .codex)
        // 包含所有 15 家，且无重复
        XCTAssertEqual(order.count, TokenUsageProvider.allCases.count)
        XCTAssertEqual(Set(order), Set(TokenUsageProvider.allCases))
    }
}

