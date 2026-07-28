import XCTest
@testable import OmniForge

final class MouseRunGateTests: XCTestCase {
    func test_gateRequiresInstallationPreferenceAndPermission() {
        XCTAssertEqual(
            MouseRunGate.decision(for: input()),
            .start
        )
        XCTAssertEqual(
            MouseRunGate.decision(for: input(isAvailable: false)),
            .stopped
        )
        XCTAssertEqual(
            MouseRunGate.decision(for: input(featureEnabled: false)),
            .stopped
        )
        XCTAssertEqual(
            MouseRunGate.decision(for: input(hasPermission: false)),
            .waitingPermission
        )
    }

    func test_startFailureIsLatchedUntilExplicitRetry() {
        var isRunning = false
        var lastError: String?
        var attempts = 0
        let start: () throws -> Void = {
            attempts += 1
            throw TestError.startFailed(attempts)
        }

        MouseRunGate.synchronize(
            input: input(),
            isRunning: &isRunning,
            lastError: &lastError,
            start: start,
            stop: {}
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(lastError, "start failed 1")

        MouseRunGate.synchronize(
            input: input(),
            isRunning: &isRunning,
            lastError: &lastError,
            start: start,
            stop: {}
        )
        XCTAssertEqual(attempts, 1, "普通同步不得自动重试失败的启动")

        MouseRunGate.synchronize(
            input: input(),
            retry: true,
            isRunning: &isRunning,
            lastError: &lastError,
            start: start,
            stop: {}
        )
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(lastError, "start failed 2")
    }

    func test_stoppingClearsRuntimeErrorWithoutChangingPreferenceInput() {
        var isRunning = false
        var lastError: String? = "tap failed"
        var stopCount = 0
        let gateInput = input(featureEnabled: false)

        MouseRunGate.synchronize(
            input: gateInput,
            isRunning: &isRunning,
            lastError: &lastError,
            start: {},
            stop: { stopCount += 1 }
        )

        XCTAssertEqual(gateInput.isAvailable, true)
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(lastError)
    }

    private func input(
        isAvailable: Bool = true,
        featureEnabled: Bool = true,
        hasPermission: Bool = true
    ) -> MouseRunGate.Input {
        .init(
            isAvailable: isAvailable,
            featureEnabled: featureEnabled,
            hasPermission: hasPermission
        )
    }

    private enum TestError: LocalizedError {
        case startFailed(Int)

        var errorDescription: String? {
            switch self {
            case .startFailed(let attempt): "start failed \(attempt)"
            }
        }
    }
}
