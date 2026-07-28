import XCTest
@testable import OmniForge

final class LaunchAtLoginManagerTests: XCTestCase {
    func test_setEnabledFailurePreservesStateAndPublishesError() {
        let suiteName = "LaunchAtLoginManagerTests.failure"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = LaunchAtLoginManager(
            client: ThrowingLaunchAtLoginClient(),
            userDefaults: defaults
        )

        let result = manager.setEnabled(true)

        guard case .failure = result else {
            return XCTFail("预期注册失败")
        }
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.launchAtLogin))
        XCTAssertNotNil(manager.lastError)
    }

    func test_togglePersistsPreference() {
        let suiteName = "LaunchAtLoginManagerTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let client = FakeLaunchAtLoginClient()
        let manager = LaunchAtLoginManager(client: client, userDefaults: defaults)

        XCTAssertFalse(manager.isEnabled)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)

        let reloaded = LaunchAtLoginManager(client: client, userDefaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
    }

    func test_toggleCallsClient() {
        let suiteName = "LaunchAtLoginManagerTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let client = FakeLaunchAtLoginClient()
        let manager = LaunchAtLoginManager(client: client, userDefaults: defaults)

        manager.setEnabled(true)
        XCTAssertEqual(client.lastEnabled, true)

        manager.setEnabled(false)
        XCTAssertEqual(client.lastEnabled, false)
    }
}

private struct ThrowingLaunchAtLoginClient: LaunchAtLoginClient {
    func setEnabled(_ enabled: Bool) throws {
        throw NSError(domain: "LaunchAtLoginTests", code: 9)
    }
}
