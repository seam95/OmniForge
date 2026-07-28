import XCTest
@testable import OmniForge

final class UtilityToolsPresentationTests: XCTestCase {
    func test_compactLayoutFitsControlCenterContentWidth() {
        XCTAssertEqual(UtilityContentLayout.compact.contentWidth, 356)
        XCTAssertEqual(UtilityContentLayout.compact.horizontalPadding, 12)
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
            ControlCenterContentMetrics.maxContentHeight
        )
        XCTAssertGreaterThan(UtilityContentLayout.compactResultsListHeight, 120)
    }

    func test_toolMetadataMapsToAppFeatureForListPresentation() {
        // 列表行图标 / 名称 / 描述通过 AppFeature 复用，确保映射稳定且都有非空展示文案。
        XCTAssertEqual(UtilityTool.cleaner.feature, .cleaner)
        XCTAssertEqual(UtilityTool.uninstaller.feature, .uninstaller)
        XCTAssertEqual(UtilityTool.colorPicker.feature, .colorPicker)
        XCTAssertEqual(UtilityTool.networkDiagnostics.feature, .networkDiagnostics)
        XCTAssertEqual(UtilityTool.cleaner.symbolName(), "sparkles")
        XCTAssertEqual(UtilityTool.uninstaller.symbolName(), "trash")
        XCTAssertEqual(UtilityTool.colorPicker.symbolName(), "eyedropper")
        XCTAssertEqual(UtilityTool.networkDiagnostics.symbolName(), "network")

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
