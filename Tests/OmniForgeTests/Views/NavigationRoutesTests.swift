import XCTest
@testable import OmniForge

final class NavigationRoutesTests: XCTestCase {
    func test_menuPanels_followFeatureAvailabilityAndStableOrder() {
        XCTAssertEqual(
            MenuPanel.primaryCases,
            [.systemMonitor, .tokenUsage, .keepAwake, .providerSwitch, .utilities]
        )

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { _ in true }),
            [.systemMonitor, .tokenUsage, .keepAwake, .providerSwitch, .utilities]
        )

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { feature in
                [.inputLock, .systemMonitor, .cleaner].contains(feature)
            }),
            [.systemMonitor, .utilities]
        )

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { feature in
                [.systemMonitor, .networkDiagnostics, .keepAwake].contains(feature)
            }),
            [.systemMonitor, .keepAwake, .utilities]
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

        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .keepAwake }),
            [.keepAwake]
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

    func test_menuPanelSelection_preservesValidSelectionAndRepairsInvalidSelection() {
        let visibleCases: [MenuPanel] = [.systemMonitor, .utilities]

        XCTAssertEqual(
            MenuPanel.resolvedSelection(.utilities, in: visibleCases),
            .utilities
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(.keepAwake, in: visibleCases),
            .systemMonitor
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(nil, in: visibleCases),
            .systemMonitor
        )
        XCTAssertNil(MenuPanel.resolvedSelection(.utilities, in: []))
    }

    func test_menuPanelSelection_usesPerformanceAsFirstOpenDefaultAndRepairsSavedUnavailablePanel() {
        let allPanels: [MenuPanel] = [
            .systemMonitor, .keepAwake, .utilities,
        ]

        XCTAssertEqual(
            MenuPanel.resolvedSelection(nil, in: allPanels),
            .systemMonitor
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(.utilities, in: allPanels),
            .utilities
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(.utilities, in: [.systemMonitor, .keepAwake]),
            .systemMonitor
        )
        XCTAssertEqual(
            MenuPanel.resolvedSelection(
                .keepAwake,
                in: [.systemMonitor, .utilities]
            ),
            .systemMonitor
        )
    }

    func test_menuPanelMetadata_usesControlCenterStringsContract() {
        XCTAssertEqual(MenuPanel.utilities.id, "utilities")
        XCTAssertEqual(MenuPanel.systemMonitor.symbolName, "waveform.path.ecg")
        XCTAssertEqual(MenuPanel.tokenUsage.symbolName, "chart.line.uptrend.xyaxis")
        XCTAssertEqual(MenuPanel.keepAwake.symbolName, "moon.fill")
        XCTAssertEqual(MenuPanel.providerSwitch.symbolName, "arrow.triangle.swap")
        XCTAssertEqual(MenuPanel.utilities.symbolName, "wrench.fill")
        XCTAssertEqual(MenuPanel.systemMonitor.title(in: .zhHans), Strings.zhHans.controlcenterTabSystemMonitor)
        XCTAssertEqual(MenuPanel.utilities.title(in: .en), Strings.en.controlcenterTabUtilities)
        XCTAssertEqual(MenuPanel.keepAwake.title(in: .en), Strings.en.featureHubNameKeepAwake)
        XCTAssertEqual(MenuPanel.providerSwitch.title(in: .zhHans), Strings.zhHans.controlcenterTabProviderSwitch)
        XCTAssertEqual(MenuPanel.providerSwitch.navTitle(in: .en), "Provider")
        XCTAssertEqual(MenuPanel.providerSwitch.navTitle(in: .zhHans), "供应商")
        XCTAssertEqual(MenuPanel.tokenUsage.title(in: .en), "Token")
        XCTAssertEqual(MenuPanel.tokenUsage.navTitle(in: .zhHans), "Token")
        XCTAssertEqual(MenuPanel.systemMonitor.navTitle(in: .zhHans), "监控")
        XCTAssertEqual(MenuPanel.keepAwake.navTitle(in: .zhHans), "唤醒")
        XCTAssertEqual(MenuPanel.utilities.navTitle(in: .zhHans), "工具")
    }

    func test_settingsTabs_followFeatureAvailabilityAndStableOrder() {
        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { _ in true }),
            [
                .general, .features, .inputMethod, .clipboard, .shelf, .screenshot, .mouse,
                .performance, .tokenUsage, .keepAwake, .providerSwitch, .cleaner, .uninstaller
            ]
        )

        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { feature in
                [.inputLock, .shelf, .smoothScroll, .systemMonitor, .uninstaller].contains(feature)
            }),
            [.general, .features, .inputMethod, .shelf, .mouse, .performance, .uninstaller]
        )

        XCTAssertEqual(
            SettingsToolbarTab.visibleCases(isAvailable: { $0 == .keepAwake }),
            [.general, .features, .keepAwake]
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
            [.stickyNotes, .dshWeb, .networkDiagnostics, .colorPicker, .uninstaller, .cleaner, .cleaningMode]
        )
        XCTAssertEqual(
            UtilityTool.visibleCases(isAvailable: { $0 == .cleaningMode }),
            [.cleaningMode]
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
