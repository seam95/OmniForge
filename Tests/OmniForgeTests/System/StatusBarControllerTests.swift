import XCTest
import Combine
@testable import OmniForge

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func test_panelContentIsCreatedOnDemandAndReleasedAfterClose() {
        let state = makeStatusBarState()
        let windowController = ClipboardWindowController(state: state)
        let controller = StatusBarController(
            state: state,
            clipboardWindowController: windowController
        )

        XCTAssertFalse(controller.hasPanelContent)

        let initialHeight = controller.installPanelContentIfNeeded()
        XCTAssertGreaterThan(initialHeight, 0)

        XCTAssertTrue(controller.hasPanelContent)

        controller.closePanel()

        XCTAssertFalse(controller.hasPanelContent)
    }

    func test_composeMainTitle_prefixesCountdownBeforeMetrics() {
        let metrics = NSAttributedString(string: "CPU 10%")
        let composed = StatusBarController.composeMainTitle(
            countdown: "15 min",
            metricsTitle: metrics
        )
        XCTAssertTrue(composed.string.contains("15 min"))
        XCTAssertTrue(composed.string.contains("CPU 10%"))
        XCTAssertLessThan(
            composed.string.range(of: "15 min")!.lowerBound,
            composed.string.range(of: "CPU 10%")!.lowerBound
        )
    }

    func test_composeMainTitle_emptyWhenNoCountdownAndNoMetrics() {
        let composed = StatusBarController.composeMainTitle(
            countdown: "",
            metricsTitle: NSAttributedString(string: "")
        )
        XCTAssertEqual(composed.length, 0)
    }

    func test_menuBarIcon_usesTemplateImage() {
        let image = StatusBarController.menuBarIcon()

        XCTAssertNotNil(image)
        XCTAssertTrue(image?.isTemplate ?? false)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        XCTAssertGreaterThan(image?.size.height ?? 0, 0)
    }

    func test_lockBadge_visibilityFollowsLockState() {
        let state = makeStatusBarState()
        let windowController = ClipboardWindowController(state: state)
        let controller = StatusBarController(
            state: state,
            clipboardWindowController: windowController
        )

        XCTAssertNotNil(controller.lockBadgeView)
        XCTAssertTrue(controller.lockBadgeView?.isHidden ?? false)

        state.lockState?.lock(to: "a")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertFalse(controller.lockBadgeView?.isHidden ?? true)

        state.lockState?.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(controller.lockBadgeView?.isHidden ?? false)
    }

    func test_lockBadgeDotView_sizeAndDrawing() {
        XCTAssertEqual(LockBadgeDotView.size, 6.5)
        let dot = LockBadgeDotView(frame: .zero)
        XCTAssertEqual(dot.frame.width, 6.5)
        XCTAssertEqual(dot.frame.height, 6.5)
        dot.viewDidChangeEffectiveAppearance()
        // verify draw call succeeds without crash
        dot.draw(dot.bounds)
    }

    func test_lockBadgeDotView_allStylesDrawWithoutCrash() {
        // 三种状态圆点（锁定蓝 / 唤醒橙 / 清理红）绘制冒烟。
        for style in [LockBadgeDotView.Style.lock, .keepAwakeActive, .keepAwakeWarning] {
            let dot = LockBadgeDotView(frame: .zero)
            dot.style = style
            XCTAssertEqual(dot.style, style)
            dot.draw(dot.bounds)
        }
    }

    func test_menuBarIconVisible_overridesHideMainIconWithMetricsAfterMetricRefresh() {
        // 回归锁：总开关开启后，指标刷新（monitor sink）不得把图钉藏回。
        // 旧代码 hideMain 仍叠加 hideMainIconWithMetrics，导致开关打开后
        // 图标短暂出现（keep-awake 路径）又随 2s 指标刷新消失。
        let state = makeStatusBarState()
        state.monitorPreferences?.update {
            $0.isEnabled = true
            $0.hideMainIconWithMetrics = true
            $0.enabledMenuBarMetrics = [.cpu]
        }
        FeatureRuntime.shared.setAvailable(.systemMonitor, true)
        defer { FeatureRuntime.shared.setAvailable(.systemMonitor, false) }

        let windowController = ClipboardWindowController(state: state)
        let controller = StatusBarController(state: state, clipboardWindowController: windowController)

        // 模拟用户在通用设置打开「显示菜单栏图标」。
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.menuBarIconVisible)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.menuBarIconVisible) }

        // 泵 runloop：让 metrics sink（combineLatest 初推 + defaults 变化链）执行。
        state.monitorPreferences?.update { $0.hideMainIconWithMetrics = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(controller.mainButtonImageForTesting)
    }

    func test_menuBarIconDisabled_hidesIconAfterMetricRefresh() {
        // 关闭方向：总开关关闭时，指标刷新后图钉必须为 nil（即便性能页未开隐藏）。
        let state = makeStatusBarState()
        state.monitorPreferences?.update {
            $0.isEnabled = true
            $0.enabledMenuBarMetrics = [.cpu]
        }
        FeatureRuntime.shared.setAvailable(.systemMonitor, true)
        defer { FeatureRuntime.shared.setAvailable(.systemMonitor, false) }

        let windowController = ClipboardWindowController(state: state)
        let controller = StatusBarController(state: state, clipboardWindowController: windowController)

        UserDefaults.standard.set(false, forKey: UserDefaultsKeys.menuBarIconVisible)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.menuBarIconVisible) }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(controller.mainButtonImageForTesting)
    }
}

@MainActor
private func makeStatusBarState() -> AppState {
    let defaults = UserDefaults(suiteName: "StatusBarControllerTests")!
    defaults.removePersistentDomain(forName: "StatusBarControllerTests")
    return AppState(
        inputMethods: InputMethodManager(
            tis: FakeTISClient(inputSources: [], currentID: "a"),
            scheduler: ImmediateScheduler(),
            notifications: FakeNotificationCenterClient()
        ),
        lockState: LockStateManager(userDefaults: defaults),
        l10n: L10n(userDefaults: defaults),
        appearance: AppearanceSettings(userDefaults: defaults),
        launchAtLogin: LaunchAtLoginManager(
            client: FakeLaunchAtLoginClient(),
            userDefaults: defaults
        ),
        clipboardHistory: ClipboardHistoryManager(
            store: StatusBarClipboardStore(),
            userDefaults: defaults
        ),
        clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
        quickPhrases: QuickPhraseManager(store: StatusBarQuickPhraseStore()),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
        userDefaults: defaults
    )
}

private final class StatusBarClipboardStore: ClipboardStore {
    func loadEntries() -> [ClipboardEntry] { [] }
    func saveEntries(_ entries: [ClipboardEntry]) {}
    func releaseMemory() {}
}

private final class StatusBarQuickPhraseStore: QuickPhraseStore {
    func loadPhrases() -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) {}
    func deletePhrase(id: UUID) {}
    func updatePhrase(_ phrase: QuickPhraseEntry) {}
    func releaseMemory() {}
}
