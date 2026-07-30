import AppKit
import CoreGraphics
import KeyboardShortcuts
import XCTest
@testable import OmniForge

/// 截图启动延迟优化时序 / apply / 不抓 snapshot 契约（SPEC §9.1 items 2–5）。
///
/// 时序用调用顺序标志（onStartCaptureForTesting + onSnapshot），不 sleep。
/// headless 下 NSScreen.screens 可能为空：startCapture 仍同步触发钩子；
/// 冻屏 Task.detached 无屏时不调 captureSnapshot，有屏时在 startCapture 之后。
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

        let screenCount = NSScreen.screens.compactMap(\.displayID).count
        let snapshotExpectation: XCTestExpectation?
        if screenCount > 0 {
            let exp = expectation(description: "captureSnapshot after startCapture")
            exp.expectedFulfillmentCount = screenCount
            captureClient.onSnapshot = { _ in
                XCTAssertTrue(
                    startCaptureCalled,
                    "captureSnapshot 不得在 startCapture 之前调用（生产须先遮罩再 Task.detached 冻屏）"
                )
                exp.fulfill()
            }
            snapshotExpectation = exp
        } else {
            // 无屏：仍断言 start 同步调用 startCapture，且此刻尚未 snapshot
            captureClient.onSnapshot = { _ in
                XCTFail("headless 无屏时不应调用 captureSnapshot")
            }
            snapshotExpectation = nil
        }

        let session = AllInOneCaptureSession(
            captureClient: captureClient,
            overlayController: overlay,
            onComplete: { _ in }
        )
        session.start()

        XCTAssertTrue(startCaptureCalled, "start() 必须同步先调用 startCapture")

        if let snapshotExpectation {
            await fulfillment(of: [snapshotExpectation], timeout: 2.0)
            XCTAssertEqual(captureClient.captureSnapshotCalls.count, screenCount)
        } else {
            XCTAssertTrue(captureClient.captureSnapshotCalls.isEmpty)
        }

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
