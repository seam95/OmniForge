import XCTest
import SwiftUI
@testable import OmniForge

@MainActor
final class GeneralSettingsViewTests: XCTestCase {

    func test_softwareUpdateStrings_existInBothLanguages() {
        for s in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(s.settingsSoftwareUpdateSection.isEmpty)
            XCTAssertTrue(s.settingsVersionFormat.contains("%@"))
            XCTAssertFalse(s.settingsSoftwareUpdateHint.isEmpty)
            XCTAssertFalse(s.settingsCheckForUpdates.isEmpty)
        }
    }

    func test_generalSettingsView_triggersInjectedUpdateAction() {
        let appState = AppCompositionRoot.compose().appState
        var updateTriggered = false

        let view = GeneralSettingsView(state: appState) {
            updateTriggered = true
        }

        XCTAssertFalse(updateTriggered)
        view.onCheckForUpdates()
        XCTAssertTrue(updateTriggered)
    }

    func test_generalSettingsView_bodyCanBeInstantiated() {
        let appState = AppCompositionRoot.compose().appState
        let view = GeneralSettingsView(state: appState)

        // 验证 body 属性可正常计算（不崩溃、View 层次正常展开）
        _ = view.body
    }
}
