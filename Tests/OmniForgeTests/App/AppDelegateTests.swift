import XCTest
@testable import OmniForge

@MainActor
final class AppDelegateTests: XCTestCase {

    override func tearDown() async throws {
        FeatureRuntime.shared.resetForTesting()
        Permissions.shared.resetForTesting()
        try await super.tearDown()
    }

    func test_appDelegate_conformsToNSApplicationDelegate() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate is NSApplicationDelegate)
    }

    func test_appDelegate_conformsToMainMenuSettingsTarget() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate is MainMenuSettingsTarget)
    }

    func test_applicationSupportsSecureRestorableState_returnsTrue() {
        let delegate = AppDelegate()
        let result = delegate.applicationSupportsSecureRestorableState(NSApplication.shared)
        XCTAssertTrue(result)
    }

    func test_openSettings_createsWindowWhenAbsent() {
        let delegate = AppDelegate()
        delegate.compositionRoot = AppCompositionRoot.compose()
        delegate.setupSettingsManager()

        delegate.openSettings()

        XCTAssertNotNil(delegate.settingsWindowManager?.window)
    }

    func test_wakeNotificationBeforeComposition_finishesOpensSettingsAfterSetup() {
        let notifications = AppDelegateNotificationCenterClient()
        let delegate = AppDelegate(wakeNotifications: notifications)

        notifications.send(.inputLockWakeExistingInstance)
        XCTAssertNil(delegate.settingsWindowManager)

        delegate.compositionRoot = AppCompositionRoot.compose()
        delegate.setupSettingsManager()

        XCTAssertNotNil(delegate.settingsWindowManager?.window)
    }

    func test_applicationShouldHandleReopen_returnsTrueWhenNoWindows() {
        let delegate = AppDelegate()
        let result = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )
        XCTAssertTrue(result)
    }

    /// 退出事务回归锁：不能返回 `.terminateLater` —— AppKit 会在 `_shouldTerminate`
    /// 内进入等待 reply 的嵌套 runloop，MainActor 清理任务在该循环中不执行，
    /// 应用会卡在「终止中」且主线程被占住（2026-10-25 实测点面板「退出」后必现）。
    /// 现改为 cancel-then-retry：首次取消、清理完成后重试直接放行。
    func test_applicationShouldTerminate_cancelsThenAllowsAfterCleanup() async {
        let delegate = AppDelegate()
        delegate.compositionRoot = AppCompositionRoot.compose()
        var terminateRetryCount = 0
        delegate.terminateAction = { terminateRetryCount += 1 }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertTrue(delegate.isTerminating)
        // 清理进行中重复 Quit：仍然取消，不重启第二个事务。
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        var waited = 0
        while delegate.isTerminating && waited < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }

        XCTAssertFalse(delegate.isTerminating, "清理完成后事务必须收尾")
        XCTAssertTrue(delegate.hasCompletedTerminationCleanup)
        XCTAssertEqual(terminateRetryCount, 1, "清理成功后应重试一次 terminate")
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow,
            "重试的终止请求必须直接放行"
        )
    }

    func test_runTerminationCleanup_withoutKeepAwakeManager_returnsTrueWhenClean() async {
        let delegate = AppDelegate()
        delegate.compositionRoot = AppCompositionRoot.compose()
        // 无 keepAwake manager、无恢复记录时 cleanup 应成功。
        let ok = await delegate.runTerminationCleanup()
        XCTAssertTrue(ok)
    }

    func test_captureScreenshot_withoutManager_failsVisibly() {
        FeatureRuntime.shared.resetForTesting()
        let delegate = AppDelegate()
        XCTAssertNil(
            FeatureRuntime.shared.manager(for: .screenshot, as: ScreenshotFeatureManager.self)
        )
        XCTAssertNil(delegate.lastScreenshotMenuError)

        delegate.captureScreenshotFullscreen()

        XCTAssertEqual(
            delegate.lastScreenshotMenuError,
            L10n().s.screenshotHotkeyIgnoredUnavailable
        )
    }

    /// 已收敛的入口保留可用性校验。
    func test_screenshotEntries_allInOneAndFullscreen() {
        // 仅验证 allInOne + fullscreen 入口可编译（断言在 handleHotkey 内部）
        XCTAssertNotNil(ScreenshotHotkeyEntry.allInOne)
        XCTAssertNotNil(ScreenshotHotkeyEntry.fullscreen)
    }
}

private final class AppDelegateNotificationCenterClient: NotificationCenterClient {
    private var observers: [Notification.Name: () -> Void] = [:]

    func addObserver(forName name: Notification.Name, using block: @escaping () -> Void) -> AnyObject {
        observers[name] = block
        return NSObject()
    }

    func removeObserver(_ token: AnyObject) {}

    func post(name: Notification.Name) {
        send(name)
    }

    func send(_ name: Notification.Name) {
        observers[name]?()
    }
}
