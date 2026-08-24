import XCTest
@testable import OmniForge

final class TokenUsagePreferencesTests: XCTestCase {
    func test_defaults() {
        let config = TokenUsageConfiguration()
        XCTAssertEqual(config.menuBarMode, .todayTokens)
        XCTAssertEqual(config.limitRefreshMinutes, 5)
        XCTAssertEqual(config.limitsDisplayMode, .used)
        XCTAssertEqual(config.usagePeriodDefault, .today)
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
            $0.usagePeriodDefault = .week
            $0.sessionLimitAlertEnabled = false
        }

        let reloaded = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.menuBarMode, .sessionPercent)
        XCTAssertEqual(reloaded.configuration.limitRefreshMinutes, 15)
        XCTAssertEqual(reloaded.configuration.limitsDisplayMode, .remaining)
        XCTAssertEqual(reloaded.configuration.usagePeriodDefault, .week)
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

    func test_usagePeriodDefaultRoundTrip_acrossAllPeriods() {
        let suite = "TokenUsagePreferencesTestsPeriod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        preferences.update { $0.usagePeriodDefault = .month }
        let reloaded = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.usagePeriodDefault, .month)
    }

    func test_corruptData_fallsBackToDefaults() {
        let suite = "TokenUsagePreferencesTestsCorrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "OmniForge.tokenUsageConfiguration")

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        XCTAssertEqual(preferences.configuration, TokenUsageConfiguration())
    }
}
