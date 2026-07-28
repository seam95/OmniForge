import XCTest
@testable import OmniForge

final class KeepAwakeModelsTests: XCTestCase {

    // MARK: - Duration

    func test_duration_parsesAllLegalValuesAndRoundTrips() throws {
        let legal = [0, 15, 30, 60, 120, 240, 480]
        for minutes in legal {
            let duration = try KeepAwakeDuration.parse(minutes)
            XCTAssertEqual(duration.minutes, minutes)
            XCTAssertEqual(try KeepAwakeDuration.parse(duration.minutes), duration)
        }
        XCTAssertEqual(KeepAwakeDuration.allCases.map(\.minutes), legal)
    }

    func test_duration_rejectsIllegalValuesWithoutSubstitution() {
        for minutes in [-1, 1, 10, 45, 90, 180, 360, 999] {
            XCTAssertThrowsError(try KeepAwakeDuration.parse(minutes)) { error in
                XCTAssertEqual(error as? KeepAwakeError, .invalidDuration(minutes))
            }
        }
    }

    func test_duration_indefiniteAndTimedFlags() throws {
        let indefinite = try KeepAwakeDuration.parse(0)
        let timed = try KeepAwakeDuration.parse(30)
        XCTAssertTrue(indefinite.isIndefinite)
        XCTAssertFalse(indefinite.isTimed)
        XCTAssertFalse(timed.isIndefinite)
        XCTAssertTrue(timed.isTimed)
    }

    // MARK: - Battery limit

    func test_batteryLimit_parsesAllLegalValuesAndRoundTrips() throws {
        let legal = [0, 5, 10, 15, 20]
        for percent in legal {
            let limit = try KeepAwakeBatteryLimit.parse(percent)
            XCTAssertEqual(limit.percent, percent)
            XCTAssertEqual(try KeepAwakeBatteryLimit.parse(limit.percent), limit)
        }
        XCTAssertEqual(KeepAwakeBatteryLimit.allCases.map(\.percent), legal)
    }

    func test_batteryLimit_rejectsIllegalValuesWithoutSubstitution() {
        for percent in [-1, 1, 3, 25, 50, 100] {
            XCTAssertThrowsError(try KeepAwakeBatteryLimit.parse(percent)) { error in
                XCTAssertEqual(error as? KeepAwakeError, .invalidBatteryLimit(percent))
            }
        }
    }

    func test_batteryLimit_zeroMeansDisabled() throws {
        XCTAssertTrue(try KeepAwakeBatteryLimit.parse(0).isDisabled)
        XCTAssertFalse(try KeepAwakeBatteryLimit.parse(10).isDisabled)
    }

    // MARK: - Pointer interval

    func test_pointerInterval_parsesAllLegalValuesAndRoundTrips() throws {
        let legal = [1, 2, 5, 10, 15]
        for minutes in legal {
            let interval = try KeepAwakePointerInterval.parse(minutes)
            XCTAssertEqual(interval.minutes, minutes)
            XCTAssertEqual(try KeepAwakePointerInterval.parse(interval.minutes), interval)
        }
        XCTAssertEqual(KeepAwakePointerInterval.allCases.map(\.minutes), legal)
    }

    func test_pointerInterval_rejectsIllegalValuesWithoutSubstitution() {
        for minutes in [0, 3, 4, 6, 20, -1] {
            XCTAssertThrowsError(try KeepAwakePointerInterval.parse(minutes)) { error in
                XCTAssertEqual(error as? KeepAwakeError, .invalidPointerInterval(minutes))
            }
        }
    }

    // MARK: - Icon tint

    func test_iconTint_parsesAllLegalValuesAndRoundTrips() throws {
        let legal = ["orange", "green", "blue", "purple", "pink", "none"]
        for raw in legal {
            let tint = try KeepAwakeIconTint.parse(raw)
            XCTAssertEqual(tint.rawValue, raw)
            XCTAssertEqual(try KeepAwakeIconTint.parse(tint.rawValue), tint)
        }
        XCTAssertEqual(KeepAwakeIconTint.allCases.map(\.rawValue), legal)
    }

    func test_iconTint_rejectsIllegalValuesWithoutSubstitution() {
        for raw in ["red", "ORANGE", "", "yellow", "default"] {
            XCTAssertThrowsError(try KeepAwakeIconTint.parse(raw)) { error in
                XCTAssertEqual(error as? KeepAwakeError, .invalidIconTint(raw))
            }
        }
    }

    // MARK: - Residual effects

    func test_residualEffects_expressesThreeIndependentFlags() {
        XCTAssertEqual(KeepAwakeResidualEffects.systemAssertion.rawValue, 1 << 0)
        XCTAssertEqual(KeepAwakeResidualEffects.displayAssertion.rawValue, 1 << 1)
        XCTAssertEqual(KeepAwakeResidualEffects.clamshellSleepDisabled.rawValue, 1 << 2)

        let all: KeepAwakeResidualEffects = [
            .systemAssertion, .displayAssertion, .clamshellSleepDisabled
        ]
        XCTAssertTrue(all.contains(.systemAssertion))
        XCTAssertTrue(all.contains(.displayAssertion))
        XCTAssertTrue(all.contains(.clamshellSleepDisabled))
        XCTAssertFalse(KeepAwakeResidualEffects().contains(.systemAssertion))
    }

    // MARK: - Session state derived properties

    func test_inactive_hasNoResidualAndLimitedCapabilities() {
        let state = KeepAwakeSessionState.inactive
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.endDate)
        XCTAssertTrue(state.canStart)
        XCTAssertFalse(state.canExtend)
        XCTAssertFalse(state.canRetryCleanup)
        XCTAssertNil(state.residualEffects)
    }

    func test_activating_and_deactivating_blockStartExtendRetry() {
        for state in [KeepAwakeSessionState.activating, .deactivating] {
            XCTAssertFalse(state.isActive)
            XCTAssertNil(state.endDate)
            XCTAssertFalse(state.canStart)
            XCTAssertFalse(state.canExtend)
            XCTAssertFalse(state.canRetryCleanup)
            XCTAssertNil(state.residualEffects)
        }
    }

    func test_active_timed_and_indefinite_derivedProperties() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = KeepAwakeSessionState.active(endDate: end)
        let indefinite = KeepAwakeSessionState.active(endDate: nil)

        XCTAssertTrue(timed.isActive)
        XCTAssertEqual(timed.endDate, end)
        XCTAssertFalse(timed.canStart)
        XCTAssertTrue(timed.canExtend)
        XCTAssertFalse(timed.canRetryCleanup)

        XCTAssertTrue(indefinite.isActive)
        XCTAssertNil(indefinite.endDate)
        XCTAssertFalse(indefinite.canStart)
        XCTAssertFalse(indefinite.canExtend)
        XCTAssertFalse(indefinite.canRetryCleanup)
    }

    func test_cleanupRequired_requiresExactResidualCombinations() {
        let residuals: [KeepAwakeResidualEffects] = [
            .systemAssertion,
            .displayAssertion,
            .clamshellSleepDisabled,
            [.systemAssertion, .displayAssertion],
            [.systemAssertion, .clamshellSleepDisabled],
            [.displayAssertion, .clamshellSleepDisabled],
            [.systemAssertion, .displayAssertion, .clamshellSleepDisabled],
        ]

        for residual in residuals {
            let state = KeepAwakeSessionState.cleanupRequired(
                residual,
                .assertionReleaseFailed(kind: "system", code: 1)
            )
            XCTAssertFalse(state.isActive)
            XCTAssertNil(state.endDate)
            XCTAssertFalse(state.canStart)
            XCTAssertFalse(state.canExtend)
            XCTAssertTrue(state.canRetryCleanup)
            XCTAssertEqual(state.residualEffects, residual)
        }
    }

    func test_inactive_mustNotCarryResidualEffects() {
        // inactive 语义上不得携带残留；仅 cleanupRequired 暴露 residualEffects。
        XCTAssertNil(KeepAwakeSessionState.inactive.residualEffects)
        XCTAssertNil(KeepAwakeSessionState.activating.residualEffects)
        XCTAssertNil(KeepAwakeSessionState.active(endDate: nil).residualEffects)
        XCTAssertNil(KeepAwakeSessionState.deactivating.residualEffects)
    }

    // MARK: - End reason / clamshell / equatable

    func test_endReason_allCasesExist() {
        let reasons: [KeepAwakeEndReason] = [
            .manual,
            .durationElapsed,
            .lowBattery,
            .featureUninstall,
            .applicationTermination,
        ]
        XCTAssertEqual(Set(reasons.map { String(describing: $0) }).count, 5)
    }

    func test_clamshellState_and_errors_areEquatable() {
        XCTAssertEqual(ClamshellState.off, .off)
        XCTAssertEqual(ClamshellState.failed(.pointerEventFailed), .failed(.pointerEventFailed))
        XCTAssertNotEqual(ClamshellState.failed(.pointerEventFailed), .failed(.accessibilityPermissionMissing))

        XCTAssertEqual(
            KeepAwakeError.systemAssertionFailed(code: 42),
            .systemAssertionFailed(code: 42)
        )
        XCTAssertNotEqual(
            KeepAwakeError.systemAssertionFailed(code: 42),
            .displayAssertionFailed(code: 42)
        )

        XCTAssertEqual(
            KeepAwakeSessionState.cleanupRequired(.systemAssertion, .featureUnavailable),
            .cleanupRequired(.systemAssertion, .featureUnavailable)
        )
        XCTAssertNotEqual(
            KeepAwakeSessionState.cleanupRequired(.systemAssertion, .featureUnavailable),
            .cleanupRequired(.displayAssertion, .featureUnavailable)
        )
    }
}
