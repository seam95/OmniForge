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

    /// 退出回归锁：清理必须同步完成并直接返回 `.terminateNow`。
    /// 不能返回 `.terminateLater` 等异步 Task —— AppKit 的 terminate 流程不会调度
    /// MainActor 任务，任务主体从未执行（2026-10-25 实测），应用点退出后永不退出，
    /// 甚至 SIGTERM 都无法结束。
    func test_applicationShouldTerminate_cleansUpSynchronouslyAndAllows() {
        let delegate = AppDelegate()
        delegate.compositionRoot = AppCompositionRoot.compose()

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow,
            "同步清理成功后必须直接放行终止"
        )
        XCTAssertTrue(delegate.hasCompletedTerminationCleanup)
        // 后续终止请求（AppKit 重复调用）同样直接放行。
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
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
