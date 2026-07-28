import XCTest
@testable import OmniForge

final class MonitorPanelStringsTests: XCTestCase {
    func test_newMonitorPanelStrings_nonEmpty_enAndZh() {
        for s in [Strings.en, Strings.zhHans] {
            XCTAssertFalse(s.monitorDeviceFallbackName.isEmpty)
            XCTAssertFalse(s.monitorStatusNormal.isEmpty)
            XCTAssertFalse(s.monitorStatusIssue.isEmpty)
            XCTAssertFalse(s.monitorPreferences.isEmpty)
            XCTAssertFalse(s.monitorRefreshAll.isEmpty)
            XCTAssertFalse(s.monitorCardStorage.isEmpty)
            XCTAssertFalse(s.monitorCardDisk.isEmpty)
            XCTAssertFalse(s.monitorCardDiskIO.isEmpty)
            XCTAssertFalse(s.monitorCardEnergy.isEmpty)
            XCTAssertFalse(s.monitorLiveBadge.isEmpty)
            XCTAssertFalse(s.monitorProcessNameHeader.isEmpty)
            XCTAssertFalse(s.monitorProcessShareHeader.isEmpty)
            XCTAssertFalse(s.monitorRankingTitleCPU.isEmpty)
            XCTAssertFalse(s.monitorRankingTitleGPU.isEmpty)
            XCTAssertFalse(s.monitorRankingTitleMemory.isEmpty)
            XCTAssertFalse(s.monitorRankingTitleNetwork.isEmpty)
            XCTAssertFalse(s.monitorRankingTitleEnergy.isEmpty)
            XCTAssertFalse(s.monitorFreeLabel.isEmpty)
            XCTAssertFalse(s.monitorSubtitleSeparator.isEmpty)
            XCTAssertFalse(s.monitorPressureNormal.isEmpty)
            XCTAssertFalse(s.monitorPressureWarning.isEmpty)
            XCTAssertFalse(s.monitorPressureCritical.isEmpty)
        }
    }

    func test_newMonitorPanelStrings_expectedEnglishValues() {
        let s = Strings.en
        XCTAssertEqual(s.monitorDeviceFallbackName, "Mac")
        XCTAssertEqual(s.monitorStatusNormal, "Online")
        XCTAssertEqual(s.monitorStatusIssue, "Issue")
        XCTAssertEqual(s.monitorPreferences, "Preferences")
        XCTAssertEqual(s.monitorRefreshAll, "Refresh All")
        XCTAssertEqual(s.monitorCardStorage, "Storage")
        XCTAssertEqual(s.monitorCardDisk, "Disk")
        XCTAssertEqual(s.monitorCardDiskIO, "Disk I/O")
        XCTAssertEqual(s.monitorCardEnergy, "Energy")
        XCTAssertEqual(s.monitorLiveBadge, "Live")
        XCTAssertEqual(s.monitorProcessNameHeader, "Process Name")
        XCTAssertEqual(s.monitorProcessShareHeader, "Share")
        XCTAssertEqual(s.monitorRankingTitleCPU, "CPU Usage")
        XCTAssertEqual(s.monitorRankingTitleGPU, "GPU Usage")
        XCTAssertEqual(s.monitorRankingTitleMemory, "Memory Usage")
        XCTAssertEqual(s.monitorRankingTitleNetwork, "Network Usage")
        XCTAssertEqual(s.monitorRankingTitleEnergy, "Energy Usage")
        XCTAssertEqual(s.monitorFreeLabel, "Free")
        XCTAssertEqual(s.monitorSubtitleSeparator, "•")
        XCTAssertEqual(s.monitorPressureNormal, "OK")
        XCTAssertEqual(s.monitorPressureWarning, "WARN")
        XCTAssertEqual(s.monitorPressureCritical, "CRIT")
    }

    func test_newMonitorPanelStrings_expectedChineseValues() {
        let s = Strings.zhHans
        XCTAssertEqual(s.monitorDeviceFallbackName, "Mac")
        XCTAssertEqual(s.monitorStatusNormal, "正常")
        XCTAssertEqual(s.monitorStatusIssue, "异常")
        XCTAssertEqual(s.monitorPreferences, "偏好设置")
        XCTAssertEqual(s.monitorRefreshAll, "全部刷新")
        XCTAssertEqual(s.monitorCardStorage, "存储")
        XCTAssertEqual(s.monitorCardDisk, "磁盘")
        XCTAssertEqual(s.monitorCardDiskIO, "磁盘 I/O")
        XCTAssertEqual(s.monitorCardEnergy, "能耗")
        XCTAssertEqual(s.monitorLiveBadge, "实时")
        XCTAssertEqual(s.monitorProcessNameHeader, "进程名")
        XCTAssertEqual(s.monitorProcessShareHeader, "占比")
        XCTAssertEqual(s.monitorRankingTitleCPU, "CPU 占用")
        XCTAssertEqual(s.monitorRankingTitleGPU, "GPU 占用")
        XCTAssertEqual(s.monitorRankingTitleMemory, "内存占用")
        XCTAssertEqual(s.monitorRankingTitleNetwork, "网络占用")
        XCTAssertEqual(s.monitorRankingTitleEnergy, "能耗占用")
        XCTAssertEqual(s.monitorFreeLabel, "可用")
        XCTAssertEqual(s.monitorSubtitleSeparator, "•")
        XCTAssertEqual(s.monitorPressureNormal, "正常")
        XCTAssertEqual(s.monitorPressureWarning, "警告")
        XCTAssertEqual(s.monitorPressureCritical, "危急")
    }
}
