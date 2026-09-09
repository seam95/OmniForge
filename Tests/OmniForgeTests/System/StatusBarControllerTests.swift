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
