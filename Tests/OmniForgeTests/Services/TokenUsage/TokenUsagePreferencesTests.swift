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
