import XCTest
@testable import OmniForge

final class SettingsToolbarTabTests: XCTestCase {
    func test_sidebarContainsStableTabs() {
        XCTAssertEqual(SettingsToolbarTab.allCases.count, 13)
        XCTAssertEqual(
            SettingsToolbarTab.allCases,
            [
                .general, .features, .inputMethod, .clipboard, .shelf, .screenshot, .mouse,
                .performance, .tokenUsage, .keepAwake, .providerSwitch, .cleaner, .uninstaller
            ]
        )
    }

    func test_visibleSections_groupsSettingsTabsByFeatureGroup() {
        XCTAssertEqual(
            SettingsToolbarTab.visibleSections(isAvailable: { _ in true }),
            [
                SettingsSidebarSection(group: .input, tabs: [.inputMethod]),
                SettingsSidebarSection(group: .clipboard, tabs: [.clipboard]),
                SettingsSidebarSection(group: .monitor, tabs: [.performance, .tokenUsage]),
                SettingsSidebarSection(group: .ai, tabs: [.providerSwitch]),
                SettingsSidebarSection(group: .productivity, tabs: [.shelf, .cleaner, .uninstaller]),
                SettingsSidebarSection(group: .mouse, tabs: [.mouse]),
                SettingsSidebarSection(group: .energy, tabs: [.keepAwake]),
                SettingsSidebarSection(group: .capture, tabs: [.screenshot]),
            ]
        )
    }

    func test_visibleSections_skipsEmptyGroupsAndKeepsStandaloneTabsOutOfSections() {
        XCTAssertEqual(
            SettingsToolbarTab.visibleSections(isAvailable: { $0 == .systemMonitor }),
            [
                SettingsSidebarSection(group: .monitor, tabs: [.performance]),
            ]
        )

        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { _ in false }).filter { $0.sidebarGroup == nil },
            [.general, .features]
        )
        XCTAssertEqual(SettingsToolbarTab.visibleSections(isAvailable: { _ in false }), [])
    }

    func test_tokenUsageSystemImageAndTitle() {
        XCTAssertEqual(SettingsToolbarTab.tokenUsage.systemImage, "chart.line.uptrend.xyaxis")
        XCTAssertEqual(SettingsToolbarTab.tokenUsage.title(in: .en), "Token Usage")
        XCTAssertEqual(SettingsToolbarTab.tokenUsage.title(in: .zhHans), "Token 用量")
    }

    func test_tokenUsageSections_orderAndTitles() {
        // 凭证配置已并入「提供商」页，分段收敛为通用 / 提供商 / 告警。
        XCTAssertEqual(
            TokenUsageSettingsSection.allCases,
            [.general, .providers, .alerts]
        )
        XCTAssertEqual(TokenUsageSettingsSection.general.title(in: .en), "General")
        XCTAssertEqual(TokenUsageSettingsSection.general.title(in: .zhHans), "通用")
        XCTAssertEqual(TokenUsageSettingsSection.providers.title(in: .en), "Providers")
        XCTAssertEqual(TokenUsageSettingsSection.providers.title(in: .zhHans), "提供商")
        XCTAssertEqual(TokenUsageSettingsSection.alerts.title(in: .en), "Alerts")
        XCTAssertEqual(TokenUsageSettingsSection.alerts.title(in: .zhHans), "告警")
    }

    func test_keepAwakeSystemImageAndTitle() {
        XCTAssertEqual(SettingsToolbarTab.keepAwake.systemImage, "moon.zzz.fill")
        XCTAssertEqual(SettingsToolbarTab.keepAwake.title(in: .en), "Keep Awake")
        XCTAssertEqual(SettingsToolbarTab.keepAwake.title(in: .zhHans), "保持唤醒")
    }

    func test_mouseSystemImage() {
        XCTAssertEqual(SettingsToolbarTab.mouse.systemImage, "computermouse")
    }

    func test_mouseTitle() {
        XCTAssertEqual(SettingsToolbarTab.mouse.title(in: .en), "Mouse")
        XCTAssertEqual(SettingsToolbarTab.mouse.title(in: .zhHans), "鼠标")
    }

    func test_shelfSystemImage() {
        XCTAssertEqual(SettingsToolbarTab.shelf.systemImage, "tray.full")
    }

    func test_shelfTitle() {
        XCTAssertEqual(SettingsToolbarTab.shelf.title(in: .en), "Shelf")
        XCTAssertEqual(SettingsToolbarTab.shelf.title(in: .zhHans), "暂存架")
    }

    func test_performanceSystemImage() {
        XCTAssertEqual(SettingsToolbarTab.performance.systemImage, "gauge.with.dots.needle.33percent")
    }

    func test_performanceTitle() {
        XCTAssertEqual(SettingsToolbarTab.performance.title(in: .en), "Performance")
        XCTAssertEqual(SettingsToolbarTab.performance.title(in: .zhHans), "性能")
    }

    func test_featuresSystemImage() {
        XCTAssertEqual(SettingsToolbarTab.features.systemImage, "puzzlepiece.extension")
    }

    func test_featuresTitle() {
        XCTAssertEqual(SettingsToolbarTab.features.title(in: .en), "Features")
    }

    func test_performanceSections_orderAndTitles() {
        XCTAssertEqual(
            PerformanceSettingsSection.allCases,
            [.monitor, .menuBar, .alerts, .fan]
        )
        XCTAssertEqual(PerformanceSettingsSection.monitor.title(in: .en), "Monitor")
        XCTAssertEqual(PerformanceSettingsSection.menuBar.title(in: .zhHans), "菜单栏")
        XCTAssertEqual(PerformanceSettingsSection.alerts.title(in: .en), "Alerts")
        XCTAssertEqual(PerformanceSettingsSection.fan.title(in: .zhHans), "风扇")
    }
}
