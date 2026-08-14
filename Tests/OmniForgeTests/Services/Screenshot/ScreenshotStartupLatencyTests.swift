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
        // 仅 keyDown：五入口齐全；Fake 无 keyUp API
        XCTAssertEqual(keyboardShortcuts.keyDownHandlers.count, 5)
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotAllInOne.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotCopy.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotPin.rawValue])
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
        XCTAssertEqual(captureClient.captureSnapshotCalls.map(\.displayID), forcedDisplayIDs)

        overlay.tearDown()
    }

    // MARK: - 全能会话：冻屏必须排除 overlay 自身窗口

    /// 冻屏发生在遮罩 orderFront 之后。若不排除 overlay 窗口，暗化遮罩会被烤进底图，
    /// 导致选区内部即使挖洞也透出已暗化的画面（回归：选区内蒙灰）。
    /// 断言：会话把 startCapture 后的 overlayWindowIDs 原样透传给 captureSnapshot。
    /// headless 无 NSScreen.screens 时退化为空集合一致性，仍验证透传链路。
    func test_allInOne_freezeExcludesOverlayWindows() async {
        let captureClient = FakeScreenCaptureClient()
        captureClient.stubbedSnapshot = FakeScreenCaptureClient.placeholderImage()

        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)

        let forcedDisplayIDs: [CGDirectDisplayID] = [1]
        let exp = expectation(description: "captureSnapshot excludes overlay windows")
        exp.expectedFulfillmentCount = forcedDisplayIDs.count
        captureClient.onSnapshot = { _ in exp.fulfill() }

        let session = AllInOneCaptureSession(
            captureClient: captureClient,
            overlayController: overlay,
            onComplete: { _ in }
        )
        session.freezeDisplayIDsForTesting = forcedDisplayIDs
        session.start()

        // session.start() 已同步完成 startCapture，panel 列表定型；
        // detached Task 读到的 overlayWindowIDs 与此刻读取的完全一致。
        let expectedExcluded = Set(overlay.overlayWindowIDs)

        await fulfillment(of: [exp], timeout: 2.0)
        await Task.yield()

        XCTAssertEqual(captureClient.captureSnapshotCalls.count, forcedDisplayIDs.count)
        for call in captureClient.captureSnapshotCalls {
            XCTAssertEqual(
                Set(call.excludingWindowIDs),
                expectedExcluded,
                "冻屏必须排除与 startCapture 同一刻的 overlay 窗口"
            )
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

        let generation = overlay.snapshotGeneration
        let displayID: CGDirectDisplayID = 42
        let image = FakeScreenCaptureClient.placeholderImage()
        var applied: [CGDirectDisplayID: CGImage]?
        overlay.onApplySnapshotsForTesting = { applied = $0 }

        overlay.applyScreenSnapshots([displayID: image], generation: generation)

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
        let generation = overlay.snapshotGeneration
        overlay.tearDown()
        XCTAssertTrue(overlay.isTornDownForTesting)

        var applyHookFired = false
        overlay.onApplySnapshotsForTesting = { _ in applyHookFired = true }

        let image = FakeScreenCaptureClient.placeholderImage()
        overlay.applyScreenSnapshots([99: image], generation: generation)

        XCTAssertFalse(applyHookFired, "tearDown 后 apply 必须 early-return，不得触钩子")
        XCTAssertTrue(overlay.screenSnapshotsForTesting.isEmpty)
        XCTAssertTrue(overlay.isTornDownForTesting)
    }

    // MARK: - 跨会话 stale generation 不得污染新会话

    func test_apply_staleGeneration_afterNewStartCapture_isNoOp() {
        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)

        // Session A
        overlay.startCapture(screenSnapshots: [:]) { _ in }
        let generationA = overlay.snapshotGeneration
        XCTAssertEqual(generationA, 1)
        overlay.tearDown()

        // Session B reuses same controller
        overlay.startCapture(screenSnapshots: [:]) { _ in }
        let generationB = overlay.snapshotGeneration
        XCTAssertEqual(generationB, 3) // start A(+1) → tearDown(+1) → start B(+1)
        XCTAssertTrue(overlay.screenSnapshotsForTesting.isEmpty)

        var applyHookFired = false
        overlay.onApplySnapshotsForTesting = { _ in applyHookFired = true }

        let image = FakeScreenCaptureClient.placeholderImage()
        // Late Task A apply with A's generation must not write B
        overlay.applyScreenSnapshots([7: image], generation: generationA)

        XCTAssertFalse(applyHookFired, "stale generation 不得注入新会话")
        XCTAssertTrue(
            overlay.screenSnapshotsForTesting.isEmpty,
            "Session A 冻屏不得写入 Session B 的 screenSnapshots"
        )
        XCTAssertFalse(overlay.isTornDownForTesting)

        // Matching B generation still works
        overlay.applyScreenSnapshots([7: image], generation: generationB)
        XCTAssertTrue(applyHookFired)
        XCTAssertEqual(overlay.screenSnapshotsForTesting.count, 1)
        XCTAssertTrue(overlay.screenSnapshotsForTesting[7] != nil)

        overlay.tearDown()
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
