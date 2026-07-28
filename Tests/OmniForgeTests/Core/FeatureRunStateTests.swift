import XCTest
@testable import OmniForge

final class FeatureRunStateTests: XCTestCase {
    func test_disabledIntentIsStoppedRegardlessOfRuntimeDetails() {
        XCTAssertEqual(
            FeatureRunState.resolve(
                isEnabled: false,
                isRunning: true,
                hasPermission: false,
                lastError: "ignored"
            ),
            .stopped
        )
    }

    func test_runningServiceIsRunning() {
        XCTAssertEqual(
            FeatureRunState.resolve(
                isEnabled: true,
                isRunning: true,
                hasPermission: true,
                lastError: nil
            ),
            .running
        )
    }

    func test_enabledServiceWithoutPermissionIsWaiting() {
        XCTAssertEqual(
            FeatureRunState.resolve(
                isEnabled: true,
                isRunning: false,
                hasPermission: false,
                lastError: nil
            ),
            .waitingPermission
        )
    }

    func test_revokedPermissionOverridesStaleRunningFlag() {
        XCTAssertEqual(
            FeatureRunState.resolve(
                isEnabled: true,
                isRunning: true,
                hasPermission: false,
                lastError: nil
            ),
            .waitingPermission
        )
    }

    func test_startFailureExposesLatestError() {
        XCTAssertEqual(
            FeatureRunState.resolve(
                isEnabled: true,
                isRunning: false,
                hasPermission: true,
                lastError: "tap failed"
            ),
            .failed("tap failed")
        )
    }
}
