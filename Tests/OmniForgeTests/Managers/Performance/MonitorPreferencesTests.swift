import XCTest
import Combine
@testable import OmniForge

final class MonitorPreferencesTests: XCTestCase {
    func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    func test_invalidRefreshIntervalThrowsInsteadOfFallingBack() {
        let defaults = makeDefaults()
        let preferences = MonitorPreferences(userDefaults: defaults)
        XCTAssertThrowsError(try preferences.setRefreshInterval(3))
    }

    func test_validRefreshIntervalSucceeds() throws {
        let defaults = makeDefaults()
        let preferences = MonitorPreferences(userDefaults: defaults)
        XCTAssertNoThrow(try preferences.setRefreshInterval(1))
        XCTAssertNoThrow(try preferences.setRefreshInterval(2))
        XCTAssertNoThrow(try preferences.setRefreshInterval(5))
    }

    func test_monitorConfigurationDefaults() {
        let config = MonitorConfiguration()
        XCTAssertEqual(config.refreshInterval, 2)
        XCTAssertEqual(config.temperatureUnit, .celsius)
        XCTAssertEqual(config.menuBarPreset, .dense)
        XCTAssertTrue(config.isEnabled)
    }

    func test_monitorAlertConfigurationDefaults() {
        let alert = MonitorAlertConfiguration()
        XCTAssertEqual(alert.cpuThreshold, 90)
        XCTAssertEqual(alert.cpuTemperatureThreshold, 90)
        XCTAssertEqual(alert.diskFreeThreshold, 10)
        XCTAssertEqual(alert.batteryThreshold, 15)
        XCTAssertEqual(alert.cooldownMinutes, 15)
        // 所有告警默认关闭
        XCTAssertFalse(alert.cpuEnabled)
        XCTAssertFalse(alert.cpuTemperatureEnabled)
        XCTAssertFalse(alert.memoryEnabled)
        XCTAssertFalse(alert.diskEnabled)
        XCTAssertFalse(alert.batteryEnabled)
    }

    func test_configurationPersistsAcrossInstances() {
        let suite = "MonitorPreferencesPersistence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let prefs1 = MonitorPreferences(userDefaults: defaults)
        prefs1.update {
            $0.isEnabled = false
            $0.refreshInterval = 5
            $0.alert.cpuEnabled = true
        }

        let prefs2 = MonitorPreferences(userDefaults: defaults)
        XCTAssertFalse(prefs2.configuration.isEnabled)
        XCTAssertEqual(prefs2.configuration.refreshInterval, 5)
        XCTAssertTrue(prefs2.configuration.alert.cpuEnabled)
    }

    func test_setRefreshIntervalUpdatesConfiguration() throws {
        let defaults = makeDefaults()
        let preferences = MonitorPreferences(userDefaults: defaults)
        try preferences.setRefreshInterval(5)
        XCTAssertEqual(preferences.configuration.refreshInterval, 5)
    }

    func test_celsiusTemperatureUnitPersists() {
        let suite = "MonitorPreferencesTempUnit"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let prefs1 = MonitorPreferences(userDefaults: defaults)
        prefs1.configuration.temperatureUnit = .fahrenheit

        let prefs2 = MonitorPreferences(userDefaults: defaults)
        XCTAssertEqual(prefs2.configuration.temperatureUnit, .fahrenheit)
    }

    func test_panelSectionOrder_roundTrips() throws {
        let suite = "MonitorPreferences.panelOrder"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let prefs = MonitorPreferences(userDefaults: defaults)
        prefs.update { config in
            config.panelSectionOrder = [.network, .system, .power, .disk]
            config.visibleSections = [.network, .system]
        }

        let reloaded = MonitorPreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.panelSectionOrder, [.network, .system, .power, .disk])
        XCTAssertEqual(reloaded.configuration.visibleSections, [.network, .system])
    }

    func test_update_replacesConfigurationToTriggerPublish() {
        let suite = "MonitorPreferences.updatePublish"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let preferences = MonitorPreferences(userDefaults: defaults)
        var publishedConfigs: [MonitorConfiguration] = []
        let cancellable = preferences.$configuration
            .dropFirst()
            .sink { publishedConfigs.append($0) }

        preferences.update { config in
            config.visibleSections = [.disk]
            config.panelSectionOrder = [.disk, .power, .system, .network]
            config.refreshInterval = 5
        }

        XCTAssertEqual(publishedConfigs.count, 1)
        XCTAssertEqual(publishedConfigs.first?.visibleSections, [.disk])
        XCTAssertEqual(publishedConfigs.first?.panelSectionOrder, [.disk, .power, .system, .network])
        XCTAssertEqual(preferences.configuration.visibleSections, [.disk])
        XCTAssertEqual(preferences.configuration.panelSectionOrder, [.disk, .power, .system, .network])

        // 持久化 sink 应已写入，重载后配置一致
        let reloaded = MonitorPreferences(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.visibleSections, [.disk])
        XCTAssertEqual(reloaded.configuration.panelSectionOrder, [.disk, .power, .system, .network])
        XCTAssertEqual(reloaded.configuration.refreshInterval, 5)

        _ = cancellable
    }

    func test_enabledMetricsFollowOrder() {
        var config = MonitorConfiguration()
        config.menuBarMetricOrder = [.memory, .cpu, .gpu]
        config.enabledMenuBarMetrics = [.gpu, .cpu]
        let ordered = config.menuBarMetricOrder.filter { config.enabledMenuBarMetrics.contains($0) }
        XCTAssertEqual(ordered, [.cpu, .gpu])
    }

    func test_legacyJSONWithoutPanelSectionOrder_preservesOtherPrefs() throws {
        let suite = "MonitorPreferences.legacyMigration"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // 模拟升级前无 panelSectionOrder 的已存 JSON
        let legacyJSON = """
        {
          "isEnabled": false,
          "refreshInterval": 5,
          "temperatureUnit": "fahrenheit",
          "visibleSections": ["disk", "network"],
          "visiblePanelMetrics": ["cpu", "memory"],
          "enabledMenuBarMetrics": [],
          "menuBarMetricOrder": ["cpu", "memory", "network", "disk", "power"],
          "menuBarPreset": "dense",
          "menuBarSpacing": "compact",
          "menuBarMemoryStyle": "percent",
          "combineTemperatures": true,
          "separateStatusItems": false,
          "hideMainIconWithMetrics": false,
          "networkUploadFirst": true,
          "alert": {
            "cpuEnabled": true,
            "cpuThreshold": 80,
            "cpuTemperatureEnabled": false,
            "cpuTemperatureThreshold": 90,
            "memoryEnabled": false,
            "diskEnabled": false,
            "diskFreeThreshold": 10,
            "batteryEnabled": false,
            "batteryThreshold": 15,
            "cooldownMinutes": 15
          }
        }
        """.data(using: .utf8)!
        // 模拟改名前用历史 key 写入的配置；MonitorPreferences 应回退读取并迁移到新 key。
        defaults.set(legacyJSON, forKey: "InputLock.monitorConfiguration")

        let preferences = MonitorPreferences(userDefaults: defaults)
        XCTAssertFalse(preferences.configuration.isEnabled)
        XCTAssertEqual(preferences.configuration.refreshInterval, 5)
        XCTAssertEqual(preferences.configuration.temperatureUnit, .fahrenheit)
        XCTAssertEqual(preferences.configuration.visibleSections, [.disk, .network])
        XCTAssertTrue(preferences.configuration.networkUploadFirst)
        XCTAssertTrue(preferences.configuration.alert.cpuEnabled)
        XCTAssertEqual(preferences.configuration.alert.cpuThreshold, 80)
        XCTAssertEqual(preferences.configuration.panelSectionOrder, Array(MonitorSection.allCases))
        // 迁移：读取后应写入新 key、清除历史 key。
        XCTAssertNotNil(defaults.data(forKey: "OmniForge.monitorConfiguration"))
        XCTAssertNil(defaults.data(forKey: "InputLock.monitorConfiguration"))
    }

    /// 存量 JSON 含已下线菜单栏指标（磁盘/电源/日期）时按 rawValue 剔除，
    /// 不抛错、不丢其余偏好
    func test_legacyJSONWithRemovedMenuBarMetrics_dropsUnknownCasesAndKeepsRest() throws {
        let suite = "MonitorPreferences.removedMenuBarMetrics"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let legacyJSON = """
        {
          "refreshInterval": 5,
          "temperatureUnit": "fahrenheit",
          "enabledMenuBarMetrics": ["cpu", "battery", "disk", "power", "date"],
          "menuBarMetricOrder": ["date", "cpu", "disk", "battery", "power", "fan"]
        }
        """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: "OmniForge.monitorConfiguration")

        let preferences = MonitorPreferences(userDefaults: defaults)
        XCTAssertEqual(
            preferences.configuration.enabledMenuBarMetrics,
            [.cpu, .battery],
            "已下线指标被剔除，保留仍存在的勾选"
        )
        XCTAssertEqual(
            preferences.configuration.menuBarMetricOrder,
            [.cpu, .battery, .fan],
            "排序中已下线指标被剔除，其余保持相对顺序"
        )
        XCTAssertEqual(preferences.configuration.refreshInterval, 5)
        XCTAssertEqual(preferences.configuration.temperatureUnit, .fahrenheit)
    }
}
