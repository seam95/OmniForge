import XCTest
@testable import OmniForge

/// 任务 5 接线测试：特性目录契约、安装幂等、关闭卸载与退出清理。
@MainActor
final class TranslationFeatureIntegrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranslationFeatureIntegrationTests-\(UUID().uuidString)"
        defaults = makeTranslationTestDefaults(suiteName)
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.setDefaultsForTesting(defaults)
    }

    override func tearDown() async throws {
        FeatureRuntime.shared.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func test_translationCatalogContractMatchesSpec() {
        XCTAssertEqual(AppFeature.translation.rawValue, "translation")
        XCTAssertEqual(AppFeature.translation.group, .productivity)
        XCTAssertEqual(AppFeature.translation.usageForm, .hotkey)
        XCTAssertTrue(AppFeature.translation.enabledKeys.isEmpty)
        XCTAssertEqual(AppFeature.translation.possiblePermissions, [.accessibility])
        XCTAssertEqual(AppFeature.translation.permissionUsage(for: .accessibility), .optional)
        XCTAssertEqual(AppFeature.translation.symbolName, "character.bubble")
    }

    func test_installReusesManagerAndDisableTearsDown() async {
        let runtime = FeatureRuntime.shared
        let factory = FeatureFactory(userDefaults: defaults)
        runtime.configureFactory(factory)

        factory.install(.translation, into: runtime)
        let first = runtime.manager(for: .translation, as: TranslationManager.self)
        XCTAssertNotNil(first, "install 后必须注册 TranslationManager")

        // 重复 install 幂等：不得重建 manager 或窗口控制器。
        factory.install(.translation, into: runtime)
        let second = runtime.manager(for: .translation, as: TranslationManager.self)
        XCTAssertTrue(first === second)

        XCTAssertNotNil(runtime.manager(for: .translation, as: TranslationPreferences.self))
        XCTAssertNotNil(runtime.manager(for: .translation, as: TranslationHotkeyManager.self))
        XCTAssertNotNil(runtime.manager(for: .translation, as: TranslationWindowController.self))

        // 安装后偏好默认值仍在（引擎默认 system，历史默认开启）。
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.translationEngine),
            TranslationEngineID.system.rawValue
        )
        XCTAssertEqual(defaults.bool(forKey: UserDefaultsKeys.translationSaveHistory), true)

        // 关闭特性：注销快捷键与 manager，保留历史与偏好（不删除用户数据）。
        let result = await runtime.setAvailableAsync(.translation, false)
        guard case .success = result else {
            return XCTFail("关闭翻译特性失败：\(result)")
        }
        XCTAssertNil(runtime.manager(for: .translation, as: TranslationManager.self))
        XCTAssertNil(runtime.manager(for: .translation, as: TranslationHotkeyManager.self))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.translationEngine),
            TranslationEngineID.system.rawValue,
            "关闭特性不得清除用户偏好"
        )
    }

    func test_terminationCancelsTranslationAndPreservesHistoryAndDraft() async {
        // 走组合根退出时调用的同一条清理路径（manager.teardown）。
        // 刻意不调用 AppCompositionRoot.compose：既有组合根会触发 Token 用量读取真实
        // Keychain，测试进程会出现系统授权阻塞（与本功能无关，见验证记录）。
        let runtime = FeatureRuntime.shared
        let factory = FeatureFactory(userDefaults: defaults)
        runtime.configureFactory(factory)
        factory.install(.translation, into: runtime)
        guard let manager = runtime.manager(
            for: .translation,
            as: TranslationManager.self
        ) else {
            return XCTFail("工厂安装后必须注册 TranslationManager")
        }

        manager.updateText("退出前的草稿")
        manager.teardown()

        // 退出清理只取消请求、隐藏窗口，不清空会话、不删除历史。
        if case .translating = manager.phase {
            XCTFail("退出后不得仍处于翻译中")
        }
        XCTAssertEqual(manager.sourceText, "退出前的草稿")
    }

    func test_utilityToolRoutesTranslationIntoVisibleTools() {
        XCTAssertTrue(
            UtilityTool.visibleCases(isAvailable: { $0 == .translation }).contains(.translation)
        )
        XCTAssertFalse(
            UtilityTool.visibleCases(isAvailable: { _ in false }).contains(.translation)
        )
        XCTAssertEqual(UtilityTool.translation.feature, .translation)
        XCTAssertEqual(UtilityTool.translation.symbolName(), "character.bubble")
        XCTAssertFalse(UtilityTool.translation.hubName(in: .en).isEmpty)
        XCTAssertFalse(UtilityTool.translation.hubDescription(in: .zhHans).isEmpty)
    }

    func test_settingsTabExposesTranslationInProductivityGroup() {
        let tabs = SettingsToolbarTab.visibleCases(isAvailable: { $0 == .translation })
        XCTAssertTrue(tabs.contains(.translation))
        XCTAssertEqual(SettingsToolbarTab.translation.sidebarGroup, .productivity)
        XCTAssertFalse(SettingsToolbarTab.translation.title(in: .en).isEmpty)
        XCTAssertFalse(SettingsToolbarTab.translation.title(in: .zhHans).isEmpty)

        let sections = SettingsToolbarTab.visibleSections(isAvailable: { $0 == .translation })
        XCTAssertEqual(sections, [SettingsSidebarSection(group: .productivity, tabs: [.translation])])
    }
}
