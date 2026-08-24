import XCTest
@testable import OmniForge

final class SettingsToolbarTabTests: XCTestCase {
    func test_sidebarContainsStableTabs() {
        XCTAssertEqual(SettingsToolbarTab.allCases.count, 12)
        XCTAssertEqual(
            SettingsToolbarTab.allCases,
            [
                .general, .features, .inputMethod, .clipboard, .shelf, .screenshot, .mouse,
                .performance, .tokenUsage, .keepAwake, .cleaner, .uninstaller
            ]
        )
    }

    func test_tokenUsageSystemImageAndTitle() {
        XCTAssertEqual(SettingsToolbarTab.tokenUsage.systemImage, "chart.line.uptrend.xyaxis")
        XCTAssertEqual(SettingsToolbarTab.tokenUsage.title(in: .en), "Token Usage")
        XCTAssertEqual(SettingsToolbarTab.tokenUsage.title(in: .zhHans), "Token 用量")
    }

    func test_tokenUsageSections_orderAndTitles() {
        XCTAssertEqual(
            TokenUsageSettingsSection.allCases,
            [.general, .providers, .alerts, .deepSeek]
        )
        XCTAssertEqual(TokenUsageSettingsSection.general.title(in: .en), "General")
        XCTAssertEqual(TokenUsageSettingsSection.providers.title(in: .zhHans), "提供商")
        XCTAssertEqual(TokenUsageSettingsSection.alerts.title(in: .zhHans), "告警")
        XCTAssertEqual(TokenUsageSettingsSection.deepSeek.title(in: .zhHans), "DeepSeek 余额")
        XCTAssertEqual(TokenUsageSettingsSection.deepSeek.title(in: .en), "DeepSeek Balance")
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
            [.monitor, .menuBar, .alerts]
        )
        XCTAssertEqual(PerformanceSettingsSection.monitor.title(in: .en), "Monitor")
        XCTAssertEqual(PerformanceSettingsSection.menuBar.title(in: .zhHans), "菜单栏")
        XCTAssertEqual(PerformanceSettingsSection.alerts.title(in: .en), "Alerts")
    }
}
