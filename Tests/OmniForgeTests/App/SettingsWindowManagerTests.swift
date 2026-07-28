import XCTest
@testable import OmniForge

@MainActor
final class SettingsWindowManagerTests: XCTestCase {

    override func tearDown() async throws {
        FeatureRuntime.shared.resetForTesting()
        Permissions.shared.resetForTesting()
        try await super.tearDown()
    }

    func test_showSettings_createsWindow() {
        let root = AppCompositionRoot.compose()
        let manager = SettingsWindowManager(appState: root.appState)

        XCTAssertNil(manager.window)
        manager.showSettings()
        XCTAssertNotNil(manager.window)
        XCTAssertTrue(manager.window?.isVisible ?? false)
    }

    func test_showSettings_reusesExistingWindow() {
        let root = AppCompositionRoot.compose()
        let manager = SettingsWindowManager(appState: root.appState)

        manager.showSettings()
        let firstWindow = manager.window
        manager.showSettings()
        XCTAssertEqual(manager.window, firstWindow)
    }

    func test_closeSettings_closesAndReleasesReference() {
        let root = AppCompositionRoot.compose()
        let manager = SettingsWindowManager(appState: root.appState)

        manager.showSettings()
        manager.closeSettings()
        XCTAssertNil(manager.window)
    }

    func test_showSettings_windowHasCorrectStyleMask() {
        let root = AppCompositionRoot.compose()
        let manager = SettingsWindowManager(appState: root.appState)

        manager.showSettings()
        let styleMask = manager.window?.styleMask
        XCTAssertTrue(styleMask?.contains(.titled) ?? false)
        XCTAssertTrue(styleMask?.contains(.closable) ?? false)
        XCTAssertTrue(styleMask?.contains(.miniaturizable) ?? false)
    }

    @MainActor
    private func makeAppState() -> AppState {
        AppCompositionRoot.compose().appState
    }
}
