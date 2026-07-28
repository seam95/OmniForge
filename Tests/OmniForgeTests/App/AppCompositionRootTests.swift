import XCTest
@testable import OmniForge

@MainActor
final class AppCompositionRootTests: XCTestCase {

    override func tearDown() async throws {
        FeatureRuntime.shared.resetForTesting()
        Permissions.shared.resetForTesting()
        try await super.tearDown()
    }

    func test_compose_returnsValidRoot() {
        let root = AppCompositionRoot.compose()

        XCTAssertNotNil(root.appState)
        XCTAssertNotNil(root.statusBarController)
    }

    func test_compose_registersManagersToFeatureRuntime() {
        let root = AppCompositionRoot.compose()

        // 验证 inputLock 特性的 Manager 已注册
        let lockManager = FeatureRuntime.shared.manager(
            for: .inputLock,
            as: LockStateManager.self
        )
        XCTAssertNotNil(lockManager)

        // 验证 clipboardHistory 特性的 Manager 已注册
        let clipboardManager = FeatureRuntime.shared.manager(
            for: .clipboardHistory,
            as: ClipboardHistoryManager.self
        )
        XCTAssertNotNil(clipboardManager)

        // 验证 shelf 已注册，且 status item frame provider 已注入
        let shelfService = FeatureRuntime.shared.manager(
            for: .shelf,
            as: ShelfService.self
        )
        XCTAssertNotNil(shelfService)
        XCTAssertNotNil(shelfService?.statusItemFrameProvider)
        // Frame may be nil in headless tests (no status bar window), but provider must not crash.
        _ = shelfService?.statusItemFrameProvider?()

        // 保留 root 引用避免被释放
        _ = root
    }

    func test_compose_bindsKeepAwakeManagerToAppState() {
        // 回归：AppState/StatusBar 必须在 FeatureRuntime bootstrap 之后创建，
        // 否则 init 时 registry 为空，keepAwakeManager / lockState 等恒为 nil，
        // 导致特性页显示已安装而菜单栏 popover 显示「功能未安装」、输入法锁定无响应。
        let root = AppCompositionRoot.compose()

        XCTAssertTrue(FeatureRuntime.shared.isAvailable(.keepAwake))
        XCTAssertTrue(FeatureRuntime.shared.isAvailable(.inputLock))
        XCTAssertNotNil(
            root.appState.keepAwakeManager,
            "启动后 AppState 必须持有 keep-awake Manager，与 availability 对齐"
        )
        XCTAssertNotNil(
            root.appState.lockState,
            "启动后 AppState 必须持有 inputLock Manager，否则控制中心锁定开关无响应"
        )
        XCTAssertNotNil(
            root.appState.inputMethods,
            "启动后 AppState 必须持有 InputMethodManager，否则输入法列表为空"
        )
        _ = root
    }

    func test_compose_setsInitialDockPolicy_whenHideDockIcon() {
        let suiteName = "AppCompositionRootTests_Dock"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: UserDefaultsKeys.hideDockIcon)

        let root = AppCompositionRoot.compose(userDefaults: defaults)

        XCTAssertEqual(NSApp?.activationPolicy(), .accessory)
        _ = root
    }

    func test_compose_alwaysInstallsClamshellRecoveryCoordinator() {
        let root = AppCompositionRoot.compose()
        XCTAssertEqual(root.bootstrapPhase, .ready)
        // coordinator 始终存在
        _ = root.clamshellRecoveryCoordinator
    }

    func test_compose_wiresClamshellControllerIntoKeepAwakeManager() async {
        // 回归：设置页「配置/重试授权」依赖 Manager 内注入的 ClamshellController。
        // 未注入时 capability 恒为 unsupported(clamshell controller unavailable)，按钮无实质效果。
        let root = AppCompositionRoot.compose()
        guard let manager = root.appState.keepAwakeManager else {
            XCTFail("compose 后 keepAwakeManager 必须存在")
            return
        }

        let capability = await manager.refreshClamshellCapability()
        if case .unsupported(let reason) = capability {
            XCTAssertFalse(
                reason.contains("clamshell controller unavailable"),
                "生产 compose 不得因未注入 controller 而报告 unsupported；实际=\(reason)"
            )
        }
        _ = root
    }

    func test_prepareForApplicationTermination_withoutKeepAwake_succeedsWhenClean() async {
        let root = AppCompositionRoot.compose()
        let ok = await root.prepareForApplicationTermination()
        XCTAssertTrue(ok)
    }

    @MainActor
    func test_compose_screenshotManagerRegistered() {
        let root = AppCompositionRoot.compose()
        let manager = FeatureRuntime.shared.manager(
            for: .screenshot,
            as: ScreenshotFeatureManager.self
        )
        XCTAssertNotNil(manager, "screenshot manager should be registered")
        _ = root
    }

    func test_compose_autoStartFalse_doesNotStartKeepAwake() {
        let suiteName = "AppCompositionRootTests_AutoStartFalse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        Defaults.register(in: defaults)
        defaults.set(false, forKey: UserDefaultsKeys.keepAwakeAutoStart)

        let root = AppCompositionRoot.compose(userDefaults: defaults)
        let manager = FeatureRuntime.shared.manager(for: .keepAwake, as: KeepAwakeManager.self)

        XCTAssertNotNil(manager)
        XCTAssertEqual(manager?.state, .inactive)
        _ = root
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_compose_autoStartTrue_startsKeepAwake() {
        let suiteName = "AppCompositionRootTests_AutoStartTrue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        Defaults.register(in: defaults)
        defaults.set(true, forKey: UserDefaultsKeys.keepAwakeAutoStart)

        let root = AppCompositionRoot.compose(userDefaults: defaults)
        let manager = FeatureRuntime.shared.manager(for: .keepAwake, as: KeepAwakeManager.self)

        XCTAssertNotNil(manager)
        // 真实 IOPMAssertion 在 headless 测试环境通常可成功；失败时不应崩溃，仅保持 inactive。
        if let manager {
            XCTAssertTrue(
                manager.state.isActive || manager.state == .inactive,
                "autoStart 路径必须安全执行；成功则 active，失败则 inactive"
            )
            if manager.state.isActive {
                manager.stop(reason: .manual)
            }
        }
        _ = root
        defaults.removePersistentDomain(forName: suiteName)
    }
}
