import XCTest
@testable import OmniForge

final class KeepAwakeControlStateTests: XCTestCase {
    func test_inactive_showsStartAndDurationPicker() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true
        )
        XCTAssertEqual(p.primaryAction, .start)
        XCTAssertTrue(p.showsDurationPicker)
        XCTAssertFalse(p.showsExtendButtons)
        XCTAssertTrue(p.isPrimaryEnabled)
    }

    func test_activeTimed_showsStopAndExtend() {
        let end = Date().addingTimeInterval(900)
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: end),
            clamshell: .active,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true
        )
        XCTAssertEqual(p.primaryAction, .stop)
        XCTAssertTrue(p.showsExtendButtons)
        XCTAssertEqual(p.clamshellStatusLine, Strings.en.keepAwakeClamshellActive)
    }

    func test_activeIndefinite_hidesExtend() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: nil),
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true
        )
        XCTAssertFalse(p.showsExtendButtons)
    }

    func test_cleanupRequired_prioritizesRetry() {
        let residual = KeepAwakeResidualEffects.systemAssertion
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .cleanupRequired(residual, .assertionReleaseFailed(kind: "system", code: 1)),
            clamshell: .failed(.sleepRestoreFailed("x")),
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true
        )
        XCTAssertEqual(p.primaryAction, .retryCleanup)
        XCTAssertFalse(p.showsDurationPicker)
    }

    func test_blocksStart_disablesPrimary() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: nil,
            blocksStart: true,
            isFeatureAvailable: true
        )
        XCTAssertEqual(p.primaryAction, .none)
        XCTAssertFalse(p.isPrimaryEnabled)
    }

    func test_featureUnavailable_disablesAll() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: nil),
            clamshell: .active,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: false
        )
        XCTAssertEqual(p.primaryAction, .none)
        XCTAssertFalse(p.isPrimaryEnabled)
        // 固化 unavailable 主文案字段：状态栏 popover 的「功能未安装」即由此触发。
        XCTAssertEqual(p.statusLine, Strings.en.keepAwakeStatusFeatureUnavailable)
    }

    func test_recoveryBanner_independentOfFeatureAvailability() {
        let model = KeepAwakeRecoveryBannerModel.from(
            state: .cleanupRequired(.sleepRestoreFailed("need admin"))
        )
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(model.showsRetry)
        XCTAssertEqual(
            KeepAwakeRecoveryBannerModel.from(state: .recovered),
            .hidden
        )
    }

    func test_countdown_underOneHour_includesSeconds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let end = now.addingTimeInterval(12 * 60 + 5) // 12m5s
        let text = KeepAwakeControlCountdownFormatter.text(endDate: end, now: now, strings: .en)
        // 固定格式：H:MM:SS 若 >= 1h，否则 M:SS 或 "12:05 remaining" — 实现采用：
        // remaining >= 3600 -> "H:MM:SS"
        // remaining > 0 -> "M:SS"  (分钟可不补零到小时)
        // remaining <= 0 -> "0:00"
        XCTAssertEqual(text, "12:05")
    }

    func test_countdown_overOneHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let end = now.addingTimeInterval(1 * 3600 + 2 * 60 + 3)
        let text = KeepAwakeControlCountdownFormatter.text(endDate: end, now: now, strings: .en)
        XCTAssertEqual(text, "1:02:03")
    }

    func test_countdown_expired_isZero() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let end = now.addingTimeInterval(-5)
        let text = KeepAwakeControlCountdownFormatter.text(endDate: end, now: now, strings: .en)
        XCTAssertEqual(text, "0:00")
    }

    func test_endTimeText_sameDay_usesShortTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let end = now.addingTimeInterval(90)
        let text = KeepAwakeControlCountdownFormatter.endTimeText(endDate: end, now: now)
        XCTAssertFalse(text.isEmpty)
        // 同日格式不应包含换行；具体样式随 locale，仅断言可解析且非空。
        XCTAssertNil(text.range(of: "\n"))
    }

    func test_inactive_toggleOff_enabled_showsDurationPicker() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertEqual(p.primaryAction, .start)
        XCTAssertFalse(p.isSessionToggleOn)
        XCTAssertTrue(p.isSessionToggleEnabled)
        XCTAssertTrue(p.showsDurationPicker)
        XCTAssertTrue(p.showsSessionCard)
        XCTAssertTrue(p.showsOptionsSection)
        XCTAssertTrue(p.showsClamshellSection)
        XCTAssertFalse(p.showsRetryCleanupButton)
        XCTAssertNil(p.countdownText)
    }

    func test_activeTimed_toggleOn_extend_andCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let end = now.addingTimeInterval(90)
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: end),
            clamshell: .active,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            now: now,
            strings: .en
        )
        XCTAssertEqual(p.primaryAction, .stop)
        XCTAssertTrue(p.isSessionToggleOn)
        XCTAssertTrue(p.isSessionToggleEnabled)
        XCTAssertTrue(p.showsExtendButtons)
        XCTAssertFalse(p.showsDurationPicker)
        XCTAssertTrue(p.showsSessionCard)
        XCTAssertEqual(p.countdownText, "1:30")
        XCTAssertEqual(p.countdownEndDate, end)
        XCTAssertEqual(p.clamshellStatusLine, Strings.en.keepAwakeClamshellActive)
    }

    func test_activeIndefinite_hidesExtendAndCountdown() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: nil),
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertTrue(p.isSessionToggleOn)
        XCTAssertFalse(p.showsExtendButtons)
        XCTAssertNil(p.countdownText)
        XCTAssertNil(p.countdownEndDate)
        XCTAssertFalse(p.showsDurationPicker)
        // 合盖并入会话卡后，无限期仍可能因 showsClamshellSection 显示合并卡片。
        XCTAssertTrue(p.showsClamshellSection)
        XCTAssertTrue(p.showsSessionCard)
    }

    func test_cleanupRequired_showsSessionCardForRetry() {
        let residual = KeepAwakeResidualEffects.systemAssertion
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .cleanupRequired(residual, .assertionReleaseFailed(kind: "system", code: 1)),
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertTrue(p.showsRetryCleanupButton)
        XCTAssertTrue(p.showsSessionCard)
    }

    func test_shortError_coversPointerAndBatteryCases() {
        // secondaryStatusLine 依赖 shortError；指针/电量错误不得退化为泛化 "error"
        let pointer = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: nil),
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            pointerError: .accessibilityPermissionMissing,
            batteryError: .batteryReadFailed("x"),
            strings: .en
        )
        XCTAssertEqual(
            pointer.secondaryStatusLine,
            "accessibility permission missing · battery read failed"
        )

        let interval = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: nil),
            clamshell: .off,
            lastError: .invalidPointerInterval(3),
            blocksStart: false,
            isFeatureAvailable: true,
            pointerError: .pointerEventFailed,
            strings: .en
        )
        XCTAssertEqual(
            interval.secondaryStatusLine,
            "invalid pointer interval · pointer event failed"
        )

        // inactive：lastError 进主 statusLine；pointer 仍进 secondary
        let inactive = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: .systemAssertionFailed(code: 1),
            blocksStart: false,
            isFeatureAvailable: true,
            pointerError: .pointerEventFailed,
            strings: .en
        )
        XCTAssertTrue(inactive.statusLine.contains("system assertion failed"))
        XCTAssertEqual(inactive.secondaryStatusLine, "pointer event failed")
    }

    func test_cleanupRequired_retryButton_disablesToggle() {
        let residual = KeepAwakeResidualEffects.systemAssertion
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .cleanupRequired(residual, .assertionReleaseFailed(kind: "system", code: 1)),
            clamshell: .failed(.sleepRestoreFailed("x")),
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertEqual(p.primaryAction, .retryCleanup)
        XCTAssertTrue(p.showsRetryCleanupButton)
        XCTAssertFalse(p.isSessionToggleOn)
        XCTAssertFalse(p.isSessionToggleEnabled)
        XCTAssertFalse(p.showsDurationPicker)
    }

    func test_blocksStart_and_unavailable_disableToggle() {
        let blocked = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: nil,
            blocksStart: true,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertFalse(blocked.isSessionToggleEnabled)
        XCTAssertEqual(blocked.primaryAction, .none)

        let unavailable = KeepAwakeControlPresentationBuilder.build(
            session: .active(endDate: nil),
            clamshell: .active,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: false,
            strings: .en
        )
        XCTAssertFalse(unavailable.isSessionToggleEnabled)
        XCTAssertFalse(unavailable.showsOptionsSection)
        XCTAssertEqual(unavailable.statusLine, Strings.en.keepAwakeStatusFeatureUnavailable)
    }

    func test_activating_toggleOn_disabled() {
        let p = KeepAwakeControlPresentationBuilder.build(
            session: .activating,
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertTrue(p.isSessionToggleOn)
        XCTAssertFalse(p.isSessionToggleEnabled)
        XCTAssertEqual(p.primaryAction, .stop) // 语义保留；View 以禁用 Toggle 呈现
    }

    func test_statusSubtitle_formatting() {
        let pZh = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .zhHans
        )
        XCTAssertEqual(pZh.statusSubtitle, "当前: 正常睡眠")

        let pEn = KeepAwakeControlPresentationBuilder.build(
            session: .inactive,
            clamshell: .off,
            lastError: nil,
            blocksStart: false,
            isFeatureAvailable: true,
            strings: .en
        )
        XCTAssertEqual(pEn.statusSubtitle, "Current: Normal sleep")
    }
}
