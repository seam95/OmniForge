import AppKit
import CoreGraphics
import KeyboardShortcuts
import XCTest
@testable import OmniForge

/// 截图启动延迟优化时序 / apply / 不抓 snapshot 契约（SPEC §9.1 items 2–5）。
///
/// 时序用调用顺序标志（onStartCaptureForTesting + onSnapshot），不 sleep。
/// 冻屏枚举经 `freezeDisplayIDsForTesting` 强制 ≥1 次 captureSnapshot，
/// 不依赖 headless 下空的 NSScreen.screens。
@MainActor
final class ScreenshotStartupLatencyTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var keyboardShortcuts: FakeScreenshotKeyboardShortcutsClient!
    private var captureClient: FakeScreenCaptureClient!
    private var manager: ScreenshotFeatureManager!

    private let testSuiteName = "ScreenshotStartupLatencyTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        userDefaults = UserDefaults(suiteName: testSuiteName)!
        keyboardShortcuts = FakeScreenshotKeyboardShortcutsClient()
        captureClient = FakeScreenCaptureClient()
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient
        )
        manager.startListening()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }

    // MARK: - keyDown 注册 / 分发（与 ScreenshotFeatureManagerTests 互补）

    func test_registerHandlers_usesKeyDown() {
        // 仅 keyDown：三入口齐全；Fake 无 keyUp API
        XCTAssertEqual(keyboardShortcuts.keyDownHandlers.count, 3)
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotAllInOne.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotFullscreen.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotRecord.rawValue])
    }

    func test_keyDown_allInOne_invokesSession() async {
        keyboardShortcuts.fireKeyDown(for: .screenshotAllInOne)
        await drainMain()
        // headless 时会话不 completion，isSessionRunning 保持 true；再 fire 记 busy
        keyboardShortcuts.fireKeyDown(for: .screenshotAllInOne)
        await drainMain()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    // MARK: - 全能会话：startCapture 先于 captureSnapshot

    func test_allInOne_startCapture_beforeSnapshot() async {
        let captureClient = FakeScreenCaptureClient()
        captureClient.stubbedSnapshot = FakeScreenCaptureClient.placeholderImage()
        captureClient.captureSnapshotDeferred = true

        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)
        var startCaptureCalled = false
        overlay.onStartCaptureForTesting = {
            startCaptureCalled = true
        }

        // 强制 ≥1 次冻屏 captureSnapshot，不依赖 NSScreen.screens（CI headless 常为空）。
        let forcedDisplayIDs: [CGDirectDisplayID] = [1]
        let exp = expectation(description: "captureSnapshot after startCapture")
        exp.expectedFulfillmentCount = forcedDisplayIDs.count
        captureClient.onSnapshot = { _ in
            XCTAssertTrue(
                startCaptureCalled,
                "captureSnapshot 不得在 startCapture 之前调用（生产须先遮罩再 Task.detached 冻屏）"
            )
            exp.fulfill()
        }

        let session = AllInOneCaptureSession(
            captureClient: captureClient,
            overlayController: overlay,
            onComplete: { _ in }
        )
        session.freezeDisplayIDsForTesting = forcedDisplayIDs
        session.start()

        // startCapture 在 start() 内同步触发钩子；冻屏在 Task.detached，可能已并发开始。
        // 顺序契约由 onSnapshot 内 XCTAssertTrue(startCaptureCalled) 保证（非 wall clock）。
        XCTAssertTrue(startCaptureCalled, "start() 必须同步先调用 startCapture")

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(captureClient.captureSnapshotCalls.count, forcedDisplayIDs.count)
        XCTAssertEqual(captureClient.captureSnapshotCalls, forcedDisplayIDs)

        overlay.tearDown()
    }

    // MARK: - applyScreenSnapshots

    func test_applyScreenSnapshots_updatesDictionary() {
        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)
        // startCapture 复位 isTornDown，允许 apply 合并字典（headless 无 panel 亦可）
        var startCalled = false
        overlay.onStartCaptureForTesting = { startCalled = true }
        overlay.startCapture(screenSnapshots: [:]) { _ in }

        XCTAssertTrue(startCalled)
        XCTAssertFalse(overlay.isTornDownForTesting)
        XCTAssertTrue(overlay.screenSnapshotsForTesting.isEmpty)

        let displayID: CGDirectDisplayID = 42
        let image = FakeScreenCaptureClient.placeholderImage()
        var applied: [CGDirectDisplayID: CGImage]?
        overlay.onApplySnapshotsForTesting = { applied = $0 }

        overlay.applyScreenSnapshots([displayID: image])

        XCTAssertNotNil(applied)
        XCTAssertEqual(overlay.screenSnapshotsForTesting.count, 1)
        XCTAssertTrue(overlay.screenSnapshotsForTesting[displayID] != nil)
        overlay.tearDown()
    }

    // MARK: - startCapture 空预抓不回退同步 snapshot

    func test_startCapture_empty_doesNotCallCaptureSnapshot() {
        let captureClient = FakeScreenCaptureClient()
        captureClient.stubbedSnapshot = FakeScreenCaptureClient.placeholderImage()
        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)

        overlay.startCapture(screenSnapshots: [:]) { _ in }

        XCTAssertTrue(
            captureClient.captureSnapshotCalls.isEmpty,
            "空预抓 startCapture 不得同步 captureSnapshot（已删回退）"
        )
        overlay.tearDown()
    }

    // MARK: - tearDown 后 apply no-op

    func test_apply_afterTearDown_isNoOp() {
        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)
        overlay.startCapture(screenSnapshots: [:]) { _ in }
        overlay.tearDown()
        XCTAssertTrue(overlay.isTornDownForTesting)

        var applyHookFired = false
        overlay.onApplySnapshotsForTesting = { _ in applyHookFired = true }

        let image = FakeScreenCaptureClient.placeholderImage()
        overlay.applyScreenSnapshots([99: image])

        XCTAssertFalse(applyHookFired, "tearDown 后 apply 必须 early-return，不得触钩子")
        XCTAssertTrue(overlay.screenSnapshotsForTesting.isEmpty)
        XCTAssertTrue(overlay.isTornDownForTesting)
    }

    // MARK: - helpers

    private func drainMain() async {
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}
