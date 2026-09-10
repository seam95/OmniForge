import XCTest
@testable import OmniForge

final class NavigationRoutesTests: XCTestCase {
    func test_menuPanels_followFeatureAvailabilityAndStableOrder() {
        // 终态 4 tab（信息架构重构阶段③）：唤醒降级为实用工具详情页。
        XCTAssertEqual(
            MenuPanel.primaryCases,
            [.systemMonitor, .tokenUsage, .providerSwitch, .utilities]
        )

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { _ in true }),
            [.systemMonitor, .tokenUsage, .providerSwitch, .utilities]
        )

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { feature in
                [.inputLock, .systemMonitor, .cleaner].contains(feature)
            }),
            [.systemMonitor, .utilities]
        )

        // 唤醒不再产生独立 panel：并入实用工具（阶段③）。
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { feature in
                [.systemMonitor, .networkDiagnostics, .keepAwake].contains(feature)
            }),
            [.systemMonitor, .utilities]
        )

        // 仅 tokenUsage 可用 → 独立页签出现，不并入实用工具
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .tokenUsage }),
            [.tokenUsage]
        )

        // 仅 providerSwitch 可用 → 独立页签出现，不并入实用工具
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .providerSwitch }),
            [.providerSwitch]
        )

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { feature in
                [.clipboardHistory, .uninstaller].contains(feature)
            }),
            [.utilities]
        )

        // 仅 keepAwake 可用 → 只有实用工具 tab（唤醒本体在工具详情页）。
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .keepAwake }),
            [.utilities]
        )

        // 仅网络诊断可用 → 实用工具 tab 可见（不再是独立 panel）
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .networkDiagnostics }),
            [.utilities]
        )
    }

    func test_menuPanel_formerControlFeaturesDoNotCreatePanel() {
        let formerControlFeatures: [AppFeature] = [
            .inputLock,
            .clipboardHistory,
            .shelf,
            .scrollInverter,
            .smoothScroll,
            .mouseNavigation,
            .dockClick,
        ]

        for availableFeature in formerControlFeatures {
            XCTAssertEqual(
                MenuPanel.visibleCases(isAvailable: { $0 == availableFeature }),
                [],
                "\(availableFeature) 不应再产生控制中心页签"
            )
        }
    }

    func test_menuPanels_ignoreFeaturesWithoutControlCenterEntry() {
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { feature in
                [.quickPhrase, .launchAtLogin].contains(feature)
            }),
            []
        )
    }

    /// 回归：仅便签或仅桌宠可用时，实用工具 tab 必须可见（此前判断遗漏这两项，
    /// 导致只启用便签/桌宠的用户整个工具 tab 消失）。详见 SPEC §5.2。
    func test_menuPanels_showUtilitiesForStickyNotesAndDesktopPet() {
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .stickyNotes }),
            [.utilities]
        )
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .desktopPet }),
            [.utilities]
        )
    }

    func test_menuPanelSelection_preservesValidSelectionAndRepairsInvalidSelection() {
        let visibleCases: [MenuPanel] = [.systemMonitor, .utilities]

        XCTAssertEqual(
            MenuPanel.resolvedSelection(.utilities, in: visibleCases),
            .utilities
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(.tokenUsage, in: visibleCases),
            .systemMonitor
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(nil, in: visibleCases),
            .systemMonitor
        )
        XCTAssertNil(MenuPanel.resolvedSelection(.utilities, in: []))
    }

    /// 升级无迁移：旧版本持久化的 `lastControlCenterPanel = "keepAwake"` 在
    /// 唤醒 tab 移除后解析为 nil，自动回退首个可见面板（监控）。SPEC §7。
    func test_menuPanelSelection_repairsLegacyKeepAwakePersistedValue() {
        XCTAssertNil(MenuPanel(rawValue: "keepAwake"))
        XCTAssertEqual(
            MenuPanel.resolvedSelection(MenuPanel(rawValue: "keepAwake"), in: [.systemMonitor, .utilities]),
            .systemMonitor
        )
    }

    func test_menuPanelSelection_usesPerformanceAsFirstOpenDefaultAndRepairsSavedUnavailablePanel() {
        let allPanels: [MenuPanel] = [.systemMonitor, .utilities]

        XCTAssertEqual(
            MenuPanel.resolvedSelection(nil, in: allPanels),
            .systemMonitor
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(.utilities, in: allPanels),
            .utilities
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(
                .tokenUsage,
                in: [.systemMonitor, .utilities]
            ),
            .systemMonitor
        )
    }

    func test_menuPanelMetadata_usesControlCenterStringsContract() {
        XCTAssertEqual(MenuPanel.utilities.id, "utilities")
        XCTAssertEqual(MenuPanel.systemMonitor.symbolName, "waveform.path.ecg")
        XCTAssertEqual(MenuPanel.tokenUsage.symbolName, "chart.line.uptrend.xyaxis")
        XCTAssertEqual(MenuPanel.providerSwitch.symbolName, "arrow.triangle.swap")
        XCTAssertEqual(MenuPanel.utilities.symbolName, "wrench.fill")
        XCTAssertEqual(MenuPanel.systemMonitor.title(in: .zhHans), Strings.zhHans.controlcenterTabSystemMonitor)
        XCTAssertEqual(MenuPanel.utilities.title(in: .en), Strings.en.controlcenterTabUtilities)
        XCTAssertEqual(MenuPanel.providerSwitch.title(in: .zhHans), Strings.zhHans.controlcenterTabProviderSwitch)
        XCTAssertEqual(MenuPanel.providerSwitch.navTitle(in: .en), "Provider")
        XCTAssertEqual(MenuPanel.providerSwitch.navTitle(in: .zhHans), "供应商")
        XCTAssertEqual(MenuPanel.tokenUsage.title(in: .en), "Token")
        XCTAssertEqual(MenuPanel.tokenUsage.navTitle(in: .zhHans), "Token")
        XCTAssertEqual(MenuPanel.systemMonitor.navTitle(in: .zhHans), "监控")
        XCTAssertEqual(MenuPanel.utilities.navTitle(in: .zhHans), "工具")
    }

    func test_settingsTabs_followFeatureAvailabilityAndStableOrder() {
        // 终态 12 项（信息架构重构阶段③）：清理/卸载全页壳移除，功能本体在工具详情页。
        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { _ in true }),
            [
                .general, .features, .inputMethod, .clipboard, .shelf, .screenshot, .mouse,
                .performance, .tokenUsage, .keepAwake, .providerSwitch, .promptOptimizer
            ]
        )

        // 清理/卸载可用也不再产生设置项（功能本体托管于控制中心工具页）。
        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { feature in
                [.cleaner, .uninstaller].contains(feature)
            }),
            [.general, .features]
        )

        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { feature in
                [.inputLock, .shelf, .smoothScroll, .systemMonitor].contains(feature)
            }),
            [.general, .features, .inputMethod, .shelf, .mouse, .performance]
        )

        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { $0 == .keepAwake }),
            [.general, .features, .keepAwake]
        )
    }

    /// 升级无迁移：旧版本持久化的设置选中项 `cleaner`/`uninstaller` 已不存在，
    /// 解析为 nil 并回退首个可见项（general）。SPEC §7。
    func test_settingsSelection_repairsLegacyCleanerAndUninstallerPersistedValues() {
        XCTAssertNil(SettingsToolbarTab(rawValue: "cleaner"))
        XCTAssertNil(SettingsToolbarTab(rawValue: "uninstaller"))
        XCTAssertEqual(
            SettingsToolbarTab.resolvedSelection(SettingsToolbarTab(rawValue: "cleaner"), in: [.general, .features]),
            .general
        )
        XCTAssertEqual(
            SettingsToolbarTab.resolvedSelection(SettingsToolbarTab(rawValue: "uninstaller"), in: [.general, .features]),
            .general
        )
    }

    func test_settingsTabs_keepPermanentEntriesWhenNoRelevantFeatureIsAvailable() {
        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { _ in false }),
            [.general, .features]
        )
        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { $0 == .quickPhrase }),
            [.general, .features]
        )
    }

    func test_settingsMouseTab_acceptsEveryMouseFeature() {
        for availableFeature in AppFeature.mouseFeatures {
            XCTAssertEqual(
                SettingsToolbarTab.visibleCases(isAvailable: { $0 == availableFeature }),
                [.general, .features, .mouse],
                "\(availableFeature) 应使鼠标设置入口可见"
            )
        }
    }

    func test_settingsSelection_preservesValidSelectionAndRepairsInvalidSelection() {
        let visibleCases: [SettingsToolbarTab] = [.general, .features, .performance]

        XCTAssertEqual(
            SettingsToolbarTab.resolvedSelection(.performance, in: visibleCases),
            .performance
        )
        XCTAssertEqual(
            SettingsToolbarTab.resolvedSelection(.clipboard, in: visibleCases),
            .general
        )
        XCTAssertEqual(
            SettingsToolbarTab.resolvedSelection(nil, in: visibleCases),
            .general
        )
        XCTAssertNil(SettingsToolbarTab.resolvedSelection(.general, in: []))
    }

    func test_utilityTools_followFeatureAvailabilityAndStableOrder() {
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { _ in true }),
            [.stickyNotes, .dshWeb, .networkDiagnostics, .colorPicker, .uninstaller, .cleaner, .cleaningMode, .desktopPet, .keepAwake]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .cleaningMode }),
            [.cleaningMode]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .desktopPet }),
            [.desktopPet]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .cleaner }),
            [.cleaner]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .uninstaller }),
            [.uninstaller]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .networkDiagnostics }),
            [.networkDiagnostics]
        )
        // 保持唤醒：工具页详情承载会话控制（信息架构重构阶段②）。
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .keepAwake }),
            [.keepAwake]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .inputLock }),
            []
        )
    }

    func test_utilityToolSelection_handlesSingleAndDoubleToolAvailability() {
        XCTAssertEqual(
            UtilityTool.resolvedSelection(nil, in: [.cleaner, .uninstaller]),
            .cleaner
        )
        XCTAssertEqual(
            UtilityTool.resolvedSelection(.uninstaller, in: [.cleaner, .uninstaller]),
            .uninstaller
        )
        XCTAssertEqual(
            UtilityTool.resolvedSelection(.uninstaller, in: [.cleaner]),
            .cleaner
        )
        XCTAssertEqual(
            UtilityTool.resolvedSelection(.cleaner, in: [.uninstaller]),
            .uninstaller
        )
        XCTAssertNil(UtilityTool.resolvedSelection(.cleaner, in: []))
    }

    func test_utilityToolTitles_useStringsContract() {
        XCTAssertEqual(UtilityTool.cleaner.title(in: .en), Strings.en.utilityCleaner)
        XCTAssertEqual(UtilityTool.uninstaller.title(in: .zhHans), Strings.zhHans.utilityUninstaller)
        XCTAssertEqual(
            UtilityTool.networkDiagnostics.title(in: .zhHans),
            Strings.zhHans.featureHubNameNetworkDiagnostics
        )
        XCTAssertEqual(
            UtilityTool.networkDiagnostics.title(in: .en),
            Strings.en.featureHubNameNetworkDiagnostics
        )
    }
}
