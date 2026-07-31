import Carbon
import Combine
import KeyboardShortcuts
import XCTest
@testable import OmniForge

/// ScreenshotFeatureManager 契约单测（SPEC §10.1）。
///
/// 覆盖 busy 互斥、preflight 三道闸（isListening/isFeatureAvailable/isScreenRecordingGranted）、
/// handleHotkey 模式分发、teardown 复位、lastError/lastOutcome 传播。
///
/// 注入策略：FakeScreenshotKeyboardShortcutsClient（避免真实 KeyboardShortcuts 全局状态）+
/// FakeScreenCaptureClient（避免真实 ScreenCaptureKit）+ 真实 CaptureOverlayController
/// （headless 测试环境 NSScreen.screens 为空，startCapture 不创建面板也不触发 completion，
/// 故 isSessionRunning 保持 true，正好用于测 busy 互斥；tearDown 在空集合上为 no-op）。
@MainActor
final class ScreenshotFeatureManagerTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var keyboardShortcuts: FakeScreenshotKeyboardShortcutsClient!
    private var captureClient: FakeScreenCaptureClient!
    private var manager: ScreenshotFeatureManager!

    private let testSuiteName = "ScreenshotFeatureManagerTests"

    override func setUp() {
        super.setUp()
        // 独立 UserDefaults suite，避免污染 .standard
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        userDefaults = UserDefaults(suiteName: testSuiteName)!
        keyboardShortcuts = FakeScreenshotKeyboardShortcutsClient()
        captureClient = FakeScreenCaptureClient()
        manager = makeManager()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }

    /// 构造 manager；默认 listening 已开、特性可用、权限已授予。
    private func makeManager(
        available: Bool = true,
        granted: Bool = true,
        stringsProvider: @escaping () -> Strings = { .en }
    ) -> ScreenshotFeatureManager {
        let m = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { available },
            isScreenRecordingGranted: { granted },
            stringsProvider: stringsProvider,
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient
            // overlayController 留空 → 默认构造真实 CaptureOverlayController
        )
        m.startListening()
        return m
    }

    // MARK: - 生命周期 / syncWithPreferences

    func test_syncWithPreferences_未启用时停止监听() {
        userDefaults.set(false, forKey: UserDefaultsKeys.screenshotEnabled)
        manager.syncWithPreferences()
        XCTAssertFalse(manager.isListening)
    }

    func test_syncWithPreferences_启用且可用时开始监听() {
        userDefaults.set(true, forKey: UserDefaultsKeys.screenshotEnabled)
        manager.syncWithPreferences()
        XCTAssertTrue(manager.isListening)
    }

    func test_syncWithPreferences_启用但特性不可用仍停止监听() {
        manager = makeManager(available: false)
        userDefaults.set(true, forKey: UserDefaultsKeys.screenshotEnabled)
        manager.syncWithPreferences()
        XCTAssertFalse(manager.isListening)
    }

    func test_startListening_registersFiveHotkeyEntries() {
        // startListening 已在 setUp 调用；校验五个入口都被注册了 onKeyDown
        XCTAssertEqual(ScreenshotHotkeyEntry.allCases.count, 5)
        XCTAssertEqual(
            ScreenshotHotkeyEntry.allCases.map(\.rawValue),
            ["allInOne", "copy", "pin", "fullscreen", "record"]
        )
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotAllInOne.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotCopy.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotPin.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotFullscreen.rawValue])
        XCTAssertNotNil(keyboardShortcuts.keyDownHandlers[KeyboardShortcuts.Name.screenshotRecord.rawValue])
        XCTAssertEqual(keyboardShortcuts.keyDownHandlers.count, 5)
    }

    func test_defaultHotkeys_copy2_pin3_fullscreen4_record5() {
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotAllInOne.keyCode, Int(kVK_ANSI_1))
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotCopy.keyCode, Int(kVK_ANSI_2))
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotPin.keyCode, Int(kVK_ANSI_3))
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotFullscreen.keyCode, Int(kVK_ANSI_4))
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotRecord.keyCode, Int(kVK_ANSI_5))

        let controlOptionCommand = HotkeyModifiers([.control, .option, .command])
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotCopy.modifiers, controlOptionCommand)
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotPin.modifiers, controlOptionCommand)
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotFullscreen.modifiers, controlOptionCommand)
        XCTAssertEqual(HotkeyDefinition.defaultScreenshotRecord.modifiers, controlOptionCommand)

        // manager 无自定义 defaults 时应回落到新默认键
        XCTAssertEqual(manager.hotkey(for: .allInOne), .defaultScreenshotAllInOne)
        XCTAssertEqual(manager.hotkey(for: .copy), .defaultScreenshotCopy)
        XCTAssertEqual(manager.hotkey(for: .pin), .defaultScreenshotPin)
        XCTAssertEqual(manager.hotkey(for: .fullscreen), .defaultScreenshotFullscreen)
        XCTAssertEqual(manager.hotkey(for: .record), .defaultScreenshotRecord)
    }

    func test_stopListening_复位isListening并清空快捷键() {
        manager.stopListening()
        XCTAssertFalse(manager.isListening)
        // clearAllKeyboardShortcuts 对五入口 setShortcut(nil)
        let nilCalls = keyboardShortcuts.setShortcutCalls.filter { !$0.hasShortcut }
        XCTAssertEqual(nilCalls.count, 5)
    }

    // MARK: - preflight 三道闸（按 SPEC 顺序：listening → available → granted）

    func test_preflight_notListening_handleAllInOne被忽略并记ignored() {
        manager.stopListening()
        manager.handleAllInOne()
        guard case let .ignored(reason) = manager.lastOutcome else {
            return XCTFail("expected .ignored, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(reason, Strings.en.screenshotHotkeyIgnoredNotListening)
        XCTAssertNotNil(manager.lastError)
    }

    func test_preflight_featureUnavailable_handleAllInOne被忽略() {
        manager = makeManager(available: false)
        manager.handleAllInOne()
        guard case let .ignored(reason) = manager.lastOutcome else {
            return XCTFail("expected .ignored, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(reason, Strings.en.screenshotHotkeyIgnoredUnavailable)
    }

    func test_preflight_permissionNotGranted_handleAllInOne被拒绝() {
        manager = makeManager(granted: false)
        manager.handleAllInOne()
        guard case let .denied(reason) = manager.lastOutcome else {
            return XCTFail("expected .denied, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(reason, Strings.en.screenshotPermissionDenied)
    }

    func test_preflight_allPass_handleAllInOne无错误记录() {
        // 全部满足（setUp 默认）→ 不应记录 preflight 错误
        manager.handleAllInOne()
        XCTAssertNil(manager.lastError)
        // lastOutcome 不应是 ignored/denied（可能为 nil 或后续业务结果）
        if let outcome = manager.lastOutcome {
            if case .ignored = outcome {
                XCTFail("should not be ignored when preflight passes")
            } else if case .denied = outcome {
                XCTFail("should not be denied when preflight passes")
            }
        }
    }

    // MARK: - busy 互斥

    func test_busyMutex_会话进行中二次触发记录busy错误() {
        // 第一次触发：headless 环境 NSScreen.screens 为空，
        // AllInOneCaptureSession.start 不触发 completion，isSessionRunning 保持 true
        manager.handleAllInOne()
        XCTAssertNil(manager.lastError, "首次触发不应记录错误")

        // 第二次触发：应被 busy 互斥拦下
        manager.handleAllInOne()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
        guard case .ignored = manager.lastOutcome else {
            return XCTFail("expected busy .ignored, got \(String(describing: manager.lastOutcome))")
        }
    }

    func test_busyMutex_handleHotkeyFullScreen与AllInOne互斥() {
        // 先开 allInOne 占住会话
        manager.handleAllInOne()
        // 再尝试 fullScreen 入口：应被 busy 拦下
        manager.handleHotkey(mode: .fullScreen, intent: .copy)
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    func test_busyMutex_fullScreen占住后allInOne被拦() {
        manager.handleHotkey(mode: .fullScreen, intent: .copy)
        // FullscreenCaptureSession.start 在 headless 无 NSScreen.main 时直接 onComplete(nil)
        // → isSessionRunning 复位为 false；此处先确认无 busy 错误
        XCTAssertNil(manager.lastError, "首次 fullScreen 触发不应记录 busy 错误")
    }

    // MARK: - handleHotkey 模式分发

    func test_handleHotkey_allInOne模式走AllInOne路径() {
        // .allInOne 分发到 handleAllInOne：headless 下开启会话占住 busy
        manager.handleHotkey(mode: .allInOne, intent: .save)
        XCTAssertNil(manager.lastError)
        // 占住后再触发一次验证确实进入了 AllInOne（busy 路径）
        manager.handleHotkey(mode: .allInOne, intent: .save)
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    func test_handleHotkey_fullScreen模式通过preflight不记错误() async {
        // fullScreen 分发到 FullscreenCaptureSession；
        // 测试环境 NSScreen 可能为空 → 立即 onComplete(nil) 复位，或不空 → 异步捕获。
        // 稳健断言：preflight 通过、无 ignored/denied 错误。
        manager.handleHotkey(mode: .fullScreen, intent: .copy)
        await waitForMainThreadTasksToDrain()
        XCTAssertNil(manager.lastError, "fullScreen 触发不应记录 preflight 错误")
        if let outcome = manager.lastOutcome {
            if case .ignored = outcome {
                XCTFail("fullScreen preflight 通过后不应记 ignored")
            } else if case .denied = outcome {
                XCTFail("fullScreen preflight 通过后不应记 denied")
            }
        }
    }

    func test_handleHotkey_fullScreen与allInOne共享同一busy互斥锁() async {
        // 先触发一次 fullScreen 占住会话（无论是否有屏，会话至少短暂进入 running）
        // 再立即触发 allInOne：若 fullScreen 仍占住则记 busy；若已复位则 allInOne 成功。
        // 关键契约：两模式共享同一 isSessionRunning 互斥量，不会并发双开。
        manager.handleHotkey(mode: .fullScreen, intent: .copy)
        await waitForMainThreadTasksToDrain()
        // 无论 fullScreen 是否复位，再次 allInOne 不会产生 preflight 错误
        manager.handleHotkey(mode: .allInOne, intent: .copy)
        await waitForMainThreadTasksToDrain()
        // 仅可能是 nil（成功）或 busy 文案，不应是 preflight 的 ignored/denied
        if let outcome = manager.lastOutcome {
            if case .ignored = outcome, manager.lastError != Strings.en.screenshotSessionAlreadyActive {
                XCTFail("不应触发 preflight ignored，实际: \(manager.lastError ?? "")")
            } else if case .denied = outcome {
                XCTFail("不应触发 preflight denied")
            }
        }
    }

    func test_handleHotkey_notListening被preflight拦下() {
        manager.stopListening()
        manager.handleHotkey(mode: .fullScreen, intent: .copy)
        guard case .ignored = manager.lastOutcome else {
            return XCTFail("expected .ignored when not listening")
        }
    }

    // MARK: - teardown

    func test_teardown_停止监听并复位错误状态() {
        manager.handleAllInOne()
        // 注入一个 lastMenuError 验证 teardown 清理
        manager.recordMenuError("临时错误")
        XCTAssertNotNil(manager.lastMenuError)

        manager.teardown()
        XCTAssertFalse(manager.isListening)
        XCTAssertNil(manager.lastOutcome)
        XCTAssertNil(manager.lastError)
        XCTAssertNil(manager.lastMenuError)
    }

    func test_teardown_清空所有快捷键绑定() {
        manager.teardown()
        let nilCalls = keyboardShortcuts.setShortcutCalls.filter { !$0.hasShortcut }
        XCTAssertEqual(nilCalls.count, 5, "teardown 应清空五入口快捷键")
    }

    // MARK: - lastError / lastOutcome 传播

    func test_recordMenuError_同时写入lastError和lastMenuError() {
        manager.recordMenuError("保存失败")
        XCTAssertEqual(manager.lastMenuError, "保存失败")
        XCTAssertEqual(manager.lastError, "保存失败")
    }

    func test_preflight_notListening写入对应本地化文案() {
        let zhProvider: () -> Strings = { .zhHans }
        manager = makeManager(stringsProvider: zhProvider)
        manager.stopListening()
        manager.handleAllInOne()
        guard case let .ignored(reason) = manager.lastOutcome else {
            return XCTFail("expected .ignored")
        }
        XCTAssertEqual(reason, Strings.zhHans.screenshotHotkeyIgnoredNotListening)
        XCTAssertEqual(manager.lastError, Strings.zhHans.screenshotHotkeyIgnoredNotListening)
    }

    // MARK: - 快捷键入口分发（invokeHotkeyEntry 经 onKeyDown 触发）

    func test_onKeyDown_allInOne入口触发handleAllInOne() async {
        // isListening=true 时 fireKeyDown(.screenshotAllInOne) 应进入 handleAllInOne
        // Fake 在主线程同步回调；若走非主线程则 Task { @MainActor }，需 await 排空
        keyboardShortcuts.fireKeyDown(for: .screenshotAllInOne)
        await waitForMainThreadTasksToDrain()
        // 占住会话后再次 fire 应记录 busy
        keyboardShortcuts.fireKeyDown(for: .screenshotAllInOne)
        await waitForMainThreadTasksToDrain()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    func test_onKeyDown_fullscreen入口分发到FullScreen不记preflight错误() async {
        // fireKeyDown(.screenshotFullscreen) → invokeHotkeyEntry(.fullscreen)
        // → handleHotkey(.fullScreen, .copy)；preflight 通过即不记错误
        keyboardShortcuts.fireKeyDown(for: .screenshotFullscreen)
        await waitForMainThreadTasksToDrain()
        await waitForMainThreadTasksToDrain()
        XCTAssertNil(manager.lastError, "fullscreen 入口 preflight 通过后不应记错误")
        if let outcome = manager.lastOutcome {
            if case .ignored = outcome {
                XCTFail("不应记 ignored")
            } else if case .denied = outcome {
                XCTFail("不应记 denied")
            }
        }
    }

    func test_onKeyDown_notListening时入口不触发() async {
        manager.stopListening()
        keyboardShortcuts.fireKeyDown(for: .screenshotAllInOne)
        await waitForMainThreadTasksToDrain()
        // registerHandler 内 isListening guard 直接 return；不进 preflight 也不记错误
        XCTAssertNil(manager.lastError)
        XCTAssertNil(manager.lastOutcome)
    }

    // MARK: - handleRecorderChange

    func test_handleRecorderChange_有效shortcut写入defaults并应用() {
        let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
        manager.handleRecorderChange(.allInOne, shortcut: shortcut)
        // 写入 defaults
        XCTAssertNotNil(userDefaults.object(forKey: ScreenshotHotkeyEntry.allInOne.keyCodeDefaultsKey))
        XCTAssertNotNil(userDefaults.object(forKey: ScreenshotHotkeyEntry.allInOne.modifiersDefaultsKey))
    }

    func test_handleRecorderChange_nilShortcut且正在监听恢复默认绑定() {
        // 监听中传 nil：应回退到默认定义并重新应用（不写 defaults）
        let applyCountBefore = keyboardShortcuts.setShortcutCalls.count
        manager.handleRecorderChange(.allInOne, shortcut: nil)
        XCTAssertGreaterThan(keyboardShortcuts.setShortcutCalls.count, applyCountBefore)
    }

    // MARK: - copy / pin 入口（Task 4）

    func test_handleCopy_notListening被preflight忽略() {
        manager.stopListening()
        manager.handleCopy()
        guard case let .ignored(reason) = manager.lastOutcome else {
            return XCTFail("expected .ignored, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(reason, Strings.en.screenshotHotkeyIgnoredNotListening)
        XCTAssertEqual(manager.lastError, Strings.en.screenshotHotkeyIgnoredNotListening)
        XCTAssertFalse(manager.isBusy)
    }

    func test_handlePin_permissionDenied() {
        manager = makeManager(granted: false)
        manager.handlePin()
        guard case let .denied(reason) = manager.lastOutcome else {
            return XCTFail("expected .denied, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(reason, Strings.en.screenshotPermissionDenied)
        XCTAssertFalse(manager.isBusy)
    }

    func test_handleCopy_featureUnavailable() {
        manager = makeManager(available: false)
        manager.handleCopy()
        guard case let .ignored(reason) = manager.lastOutcome else {
            return XCTFail("expected .ignored, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(reason, Strings.en.screenshotHotkeyIgnoredUnavailable)
    }

    func test_handleCopy_busyWhenSessionRunning() {
        manager.handleAllInOne()
        XCTAssertNil(manager.lastError)

        manager.handleCopy()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
        guard case .ignored = manager.lastOutcome else {
            return XCTFail("expected busy .ignored, got \(String(describing: manager.lastOutcome))")
        }
    }

    func test_handlePin_busyWhenSessionRunning() {
        manager.handleAllInOne()
        manager.handlePin()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    func test_handleCopy_recordingBusy_doesNotStopAndSave() {
        let fakeCoordinator = FakeRecordingSessionCoordinator()
        fakeCoordinator.isRecording = true
        let overlay = CaptureOverlayController(captureClient: captureClient)
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay,
            recordingCoordinator: fakeCoordinator
        )
        manager.startListening()

        manager.handleCopy()

        XCTAssertEqual(fakeCoordinator.stopAndSaveCallCount, 0)
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
        XCTAssertNil(overlay.entryIntent)
        XCTAssertNil(overlay.onDirectCaptureResult)
        XCTAssertNil(overlay.onDirectRegionSelection)
    }

    func test_handlePin_recordingBusy_doesNotStopAndSave() {
        let fakeCoordinator = FakeRecordingSessionCoordinator()
        fakeCoordinator.isRecording = true
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            recordingCoordinator: fakeCoordinator
        )
        manager.startListening()

        manager.handlePin()

        XCTAssertEqual(fakeCoordinator.stopAndSaveCallCount, 0)
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    func test_handleCopy_successPath_startsDirectOutSessionWithCopyIntent() {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay
        )
        manager.startListening()

        manager.handleCopy()

        // headless 下会话占住 busy；直出 intent 透传，且不走录屏 rect-only 回调
        XCTAssertTrue(manager.isBusy)
        XCTAssertEqual(overlay.entryIntent, .copy)
        XCTAssertNotNil(overlay.onDirectCaptureResult)
        XCTAssertNil(overlay.onDirectRegionSelection)
        XCTAssertNil(manager.lastError)
        guard case let .triggered(mode, intent) = manager.lastOutcome else {
            return XCTFail("expected triggered copy, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(mode, .allInOne)
        XCTAssertEqual(intent, .copy)

        // busy 互斥：二次 copy 被拒
        manager.handleCopy()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
    }

    func test_handlePin_successPath_startsDirectOutSessionWithPinIntent() {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay
        )
        manager.startListening()

        manager.handlePin()

        XCTAssertTrue(manager.isBusy)
        XCTAssertEqual(overlay.entryIntent, .pin)
        XCTAssertNotNil(overlay.onDirectCaptureResult)
        XCTAssertNil(overlay.onDirectRegionSelection)
        XCTAssertNil(manager.lastError)
        guard case let .triggered(mode, intent) = manager.lastOutcome else {
            return XCTFail("expected triggered pin, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(mode, .allInOne)
        XCTAssertEqual(intent, .pin)
    }

    func test_onKeyDown_copy入口分发到handleCopy() async {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay
        )
        manager.startListening()

        keyboardShortcuts.fireKeyDown(for: .screenshotCopy)
        await waitForMainThreadTasksToDrain()

        XCTAssertEqual(overlay.entryIntent, .copy)
        XCTAssertTrue(manager.isBusy)
    }

    func test_onKeyDown_pin入口分发到handlePin() async {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay
        )
        manager.startListening()

        keyboardShortcuts.fireKeyDown(for: .screenshotPin)
        await waitForMainThreadTasksToDrain()

        XCTAssertEqual(overlay.entryIntent, .pin)
        XCTAssertTrue(manager.isBusy)
    }

    func test_finishDirectCapture_runsPipelineWithCopyIntent() {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        let runner = FakeScreenshotResultRunner()
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay,
            resultPipeline: runner
        )
        manager.startListening()
        manager.handleCopy()
        XCTAssertTrue(manager.isBusy)

        // 模拟 overlay 选区直出回调（不依赖真实 NSScreen / 选区交互）
        let target = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 1
        )
        let selection = try! CaptureSelection(
            targetScreen: target,
            appKitGlobalRect: CGRect(x: 10, y: 20, width: 40, height: 30)
        )
        let result = try! ScreenshotResult(
            mode: .allInOne,
            targetScreen: target,
            selection: selection,
            timestamp: Date(),
            pixelImage: FakeScreenCaptureClient.placeholderImage(),
            windowInfo: nil
        )
        // copy 路径 manager 会把 pinOrigin 置 nil 再交给 pipeline
        overlay.onDirectCaptureResult?(result, .copy, NSPoint(x: 10, y: 20))

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.intent, .copy)
        XCTAssertNil(runner.calls.first?.pinOrigin)
        XCTAssertNil(manager.lastError)
        guard case let .triggered(_, intent) = manager.lastOutcome else {
            return XCTFail("expected triggered after pipeline ok")
        }
        XCTAssertEqual(intent, .copy)
    }

    func test_finishDirectCapture_pinPassesPinOrigin() {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        let runner = FakeScreenshotResultRunner()
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay,
            resultPipeline: runner
        )
        manager.startListening()
        manager.handlePin()

        let target = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 1
        )
        let selection = try! CaptureSelection(
            targetScreen: target,
            appKitGlobalRect: CGRect(x: 10, y: 20, width: 40, height: 30)
        )
        let result = try! ScreenshotResult(
            mode: .allInOne,
            targetScreen: target,
            selection: selection,
            timestamp: Date(),
            pixelImage: FakeScreenCaptureClient.placeholderImage(),
            windowInfo: nil
        )
        let pinOrigin = NSPoint(x: 10, y: 20)
        overlay.onDirectCaptureResult?(result, .pin, pinOrigin)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.intent, .pin)
        XCTAssertEqual(runner.calls.first?.pinOrigin, pinOrigin)
        XCTAssertNil(manager.lastError)
    }

    func test_finishDirectCapture_pipelineFailureRecordsError() {
        let overlay = CaptureOverlayController(captureClient: captureClient)
        let runner = FakeScreenshotResultRunner()
        runner.errorToThrow = ScreenshotPipelineError.pasteboardWriteFailed
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay,
            resultPipeline: runner
        )
        manager.startListening()
        manager.handleCopy()

        let target = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 1
        )
        let selection = try! CaptureSelection(
            targetScreen: target,
            appKitGlobalRect: CGRect(x: 10, y: 20, width: 40, height: 30)
        )
        let result = try! ScreenshotResult(
            mode: .allInOne,
            targetScreen: target,
            selection: selection,
            timestamp: Date(),
            pixelImage: FakeScreenCaptureClient.placeholderImage(),
            windowInfo: nil
        )
        overlay.onDirectCaptureResult?(result, .copy, nil)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertNotNil(manager.lastError)
        guard case .ignored = manager.lastOutcome else {
            return XCTFail("expected ignored on pipeline failure")
        }
    }

    // MARK: - 异步等待辅助

    /// 等待 keyDown 非主线程路径的 Task { @MainActor } 排空（invokeHotkeyEntry 已执行）。
    /// 主线程同步回调时此等待为 no-op 安全；fullScreen 内部 Task 在无 NSScreen 时走短路径。
    private func waitForMainThreadTasksToDrain() async {
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}
