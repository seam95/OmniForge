import XCTest
@testable import OmniForge

final class UtilityToolsPresentationTests: XCTestCase {
    func test_compactLayoutFitsControlCenterContentWidth() {
        // 平面分区规范：内容 + 左右边距（h16×2）恰好铺满 380pt 面板。
        XCTAssertEqual(UtilityContentLayout.compact.contentWidth, 348)
        XCTAssertEqual(UtilityContentLayout.compact.horizontalPadding, 16)
        XCTAssertEqual(
            UtilityContentLayout.compact.contentWidth! + UtilityContentLayout.compact.horizontalPadding * 2,
            ControlCenterContentMetrics.panelWidth
        )
        XCTAssertEqual(UtilityContentLayout.settings.contentWidth, nil)
    }

    func test_compactResultsListHasExplicitHeightForControlCenterNesting() {
        XCTAssertEqual(UtilityContentLayout.compactResultsListHeight, 300)
        XCTAssertEqual(UtilityContentLayout.compact.resultsListHeight, 300)
        XCTAssertNil(UtilityContentLayout.settings.resultsListHeight)
    }

    func test_compactResultsListFitsControlCenterMaxHeight() {
        // 分段控件 + header + footer 粗估上限；列表高度必须留给可见条目区。
        let reservedChrome: CGFloat = 200
        XCTAssertLessThanOrEqual(
            UtilityContentLayout.compactResultsListHeight + reservedChrome,
            ControlCenterContentMetrics.viewportHeight
        )
        XCTAssertGreaterThan(UtilityContentLayout.compactResultsListHeight, 120)
    }

    func test_toolMetadataMapsToAppFeatureForListPresentation() {
        // 列表行图标 / 名称 / 描述通过 AppFeature 复用，确保映射稳定且都有非空展示文案。
        XCTAssertEqual(UtilityTool.cleaner.feature, .cleaner)
        XCTAssertEqual(UtilityTool.uninstaller.feature, .uninstaller)
        XCTAssertEqual(UtilityTool.colorPicker.feature, .colorPicker)
        XCTAssertEqual(UtilityTool.networkDiagnostics.feature, .networkDiagnostics)
        XCTAssertEqual(UtilityTool.cleaner.symbolName(), "trash")
        XCTAssertEqual(UtilityTool.uninstaller.symbolName(), "trash")
        XCTAssertEqual(UtilityTool.colorPicker.symbolName(), "eyedropper")
        XCTAssertEqual(UtilityTool.networkDiagnostics.symbolName(), "globe")
        XCTAssertEqual(UtilityTool.dshWeb.symbolName(), "server.rack")
        // 保持唤醒详情页（信息架构重构阶段②）：映射到 keepAwake 特性与唤醒图标。
        XCTAssertEqual(UtilityTool.keepAwake.feature, .keepAwake)
        XCTAssertEqual(UtilityTool.keepAwake.symbolName(), "moon.zzz.fill")

        let strings = Strings.zhHans
        for tool in UtilityTool.allCases {
            XCTAssertFalse(tool.hubName(in: strings).isEmpty, "\(tool)")
            XCTAssertFalse(tool.hubDescription(in: strings).isEmpty, "\(tool)")
        }
    }

    func test_persistedToolSelectionUsesStoredValueAndRepairsUnavailableValue() {
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedSelection(
                storedRawValue: UtilityTool.uninstaller.rawValue,
                visibleTools: [.cleaner, .uninstaller]
            ),
            .uninstaller
        )
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedSelection(
                storedRawValue: UtilityTool.uninstaller.rawValue,
                visibleTools: [.cleaner]
            ),
            .cleaner
        )
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedSelection(
                storedRawValue: "removed-tool",
                visibleTools: [.cleaner, .uninstaller]
            ),
            .cleaner
        )
        XCTAssertNil(
            UtilityToolsPresentation.resolvedSelection(
                storedRawValue: UtilityTool.cleaner.rawValue,
                visibleTools: []
            )
        )
    }

    func test_reentryRoute_keepsDetailLevelWhenMultipleToolsVisible() {
        // 面板切走再切回：用户停在详情层时不再弹回列表（回归保护）。
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedReentryRoute(
                current: .detail(.cleaner),
                visibleTools: [.cleaner, .uninstaller, .colorPicker]
            ),
            .detail(.cleaner)
        )
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedReentryRoute(
                current: .list,
                visibleTools: [.cleaner, .uninstaller, .colorPicker]
            ),
            .list
        )
    }

    func test_reentryRoute_autoEntersDetailOnlyWhenSingleToolRemainsAtList() {
        // 单工具且仍处列表层 → 直达详情（保留原自动直达行为）。
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedReentryRoute(
                current: .list,
                visibleTools: [.stickyNotes]
            ),
            .detail(.stickyNotes)
        )
        // 单工具但已在详情层（即唯一工具本身）→ 保留现状，不重复路由。
        XCTAssertEqual(
            UtilityToolsPresentation.resolvedReentryRoute(
                current: .detail(.stickyNotes),
                visibleTools: [.stickyNotes]
            ),
            .detail(.stickyNotes)
        )
    }

    func test_busyUtilityBlocksOnlyDestructiveAvailabilityChanges() {
        let guardPolicy = UtilityUninstallGuard(cleanerIsBusy: true, uninstallerIsBusy: false)

        XCTAssertFalse(guardPolicy.canSetAvailability(of: .cleaner, to: false))
        XCTAssertTrue(guardPolicy.canSetAvailability(of: .cleaner, to: true))
        XCTAssertTrue(guardPolicy.canSetAvailability(of: .uninstaller, to: false))
        XCTAssertFalse(guardPolicy.canUninstallAll)
        XCTAssertTrue(guardPolicy.isUninstallBlocked(for: .cleaner))
        XCTAssertFalse(guardPolicy.isUninstallBlocked(for: .uninstaller))
        XCTAssertFalse(guardPolicy.isUninstallBlocked(for: .clipboardHistory))
    }

    func test_idleUtilitiesDoNotBlockUninstallActions() {
        let guardPolicy = UtilityUninstallGuard(cleanerIsBusy: false, uninstallerIsBusy: false)

        XCTAssertTrue(guardPolicy.canUninstallAll)
        XCTAssertTrue(guardPolicy.canSetAvailability(of: .cleaner, to: false))
        XCTAssertTrue(guardPolicy.canSetAvailability(of: .uninstaller, to: false))
    }
}
