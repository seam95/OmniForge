import XCTest
@testable import OmniForge

final class KeepAwakeSessionSupportTests: XCTestCase {

    // MARK: - SPEC 5.8 状态 × 操作

    func test_inactive_allowsStartAndToggle_rejectsStopExtend() {
        let state = KeepAwakeSessionState.inactive
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .start, state: state), .allow)
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .toggle, state: state), .allow)
        XCTAssertEqual(
            KeepAwakeSessionSupport.decide(action: .stop, state: state),
            .reject(.alreadyInactive)
        )
        XCTAssertEqual(
            KeepAwakeSessionSupport.decide(action: .extend, state: state),
            .reject(.operationInProgress)
        )
        XCTAssertEqual(
            KeepAwakeSessionSupport.decide(action: .retryCleanup, state: state),
            .reject(.alreadyInactive)
        )
    }

    func test_activating_allowsStopOnly() {
        let state = KeepAwakeSessionState.activating
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .stop, state: state), .allow)
        for action: KeepAwakeSessionAction in [.start, .toggle, .extend, .retryCleanup] {
            XCTAssertEqual(
                KeepAwakeSessionSupport.decide(action: action, state: state),
                .reject(.operationInProgress),
                "activating should reject \(action)"
            )
        }
    }

    func test_active_toggleAndStopAllowed_startRejected() {
        let timed = KeepAwakeSessionState.active(endDate: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .toggle, state: timed), .allow)
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .stop, state: timed), .allow)
        XCTAssertEqual(
            KeepAwakeSessionSupport.decide(action: .start, state: timed),
            .reject(.alreadyActive)
        )
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .extend, state: timed), .allow)
        XCTAssertEqual(
            KeepAwakeSessionSupport.decide(action: .retryCleanup, state: timed),
            .reject(.operationInProgress)
        )
    }

    func test_activeIndefinite_cannotExtend() {
        let indefinite = KeepAwakeSessionState.active(endDate: nil)
        XCTAssertEqual(
            KeepAwakeSessionSupport.decide(action: .extend, state: indefinite),
            .reject(.operationInProgress)
        )
        XCTAssertFalse(indefinite.canExtend)
    }

    func test_deactivating_rejectsAllActions() {
        let state = KeepAwakeSessionState.deactivating
        for action: KeepAwakeSessionAction in [.start, .stop, .toggle, .extend, .retryCleanup] {
            XCTAssertEqual(
                KeepAwakeSessionSupport.decide(action: action, state: state),
                .reject(.operationInProgress),
                "deactivating should reject \(action)"
            )
        }
    }

    func test_cleanupRequired_onlyAllowsRetryOrStopAsRetry() {
        let state = KeepAwakeSessionState.cleanupRequired(
            .systemAssertion,
            .assertionReleaseFailed(kind: "system", code: 1)
        )
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .retryCleanup, state: state), .allow)
        XCTAssertEqual(KeepAwakeSessionSupport.decide(action: .stop, state: state), .allow)
        for action: KeepAwakeSessionAction in [.start, .toggle, .extend] {
            XCTAssertEqual(
                KeepAwakeSessionSupport.decide(action: action, state: state),
                .reject(.operationInProgress),
                "cleanupRequired should reject \(action)"
            )
        }
        XCTAssertTrue(state.canRetryCleanup)
        XCTAssertFalse(state.canStart)
    }

    // MARK: - 快速重复与同时结束

    func test_rapidToggle_secondOperationRejectedWhileDeactivating() {
        // 第一次 toggle 进入 deactivating 后，第二次不得排队。
        let first = KeepAwakeSessionSupport.decide(
            action: .toggle,
            state: .active(endDate: Date())
        )
        XCTAssertEqual(first, .allow)

        let second = KeepAwakeSessionSupport.decide(
            action: .toggle,
            state: .deactivating
        )
        XCTAssertEqual(second, .reject(.operationInProgress))
    }

    func test_lowBatteryAndManualStop_onlyFirstEndReasonAccepted() {
        // 首个结束原因获胜；后续同时到达的结束请求被拒绝。
        XCTAssertTrue(
            KeepAwakeSessionSupport.shouldAcceptEndReason(
                currentState: .active(endDate: nil),
                existingEndReason: nil
            )
        )
        XCTAssertFalse(
            KeepAwakeSessionSupport.shouldAcceptEndReason(
                currentState: .deactivating,
                existingEndReason: .lowBattery
            )
        )
        XCTAssertFalse(
            KeepAwakeSessionSupport.shouldAcceptEndReason(
                currentState: .active(endDate: nil),
                existingEndReason: .lowBattery
            )
        )
    }

    // MARK: - generation

    func test_staleGeneration_isNotCurrent() {
        XCTAssertTrue(KeepAwakeSessionSupport.isCurrentGeneration(callbackGeneration: 3, currentGeneration: 3))
        XCTAssertFalse(KeepAwakeSessionSupport.isCurrentGeneration(callbackGeneration: 2, currentGeneration: 3))
    }

    // MARK: - 延长公式

    func test_extendedEndDate_usesMaxOfCurrentAndNow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureEnd = Date(timeIntervalSince1970: 1_500)
        let pastEnd = Date(timeIntervalSince1970: 900)

        let fromFuture = KeepAwakeSessionSupport.extendedEndDate(
            currentEndDate: futureEnd,
            now: now,
            extensionMinutes: 15
        )
        XCTAssertEqual(fromFuture, Date(timeIntervalSince1970: 1_500 + 15 * 60))

        let fromPast = KeepAwakeSessionSupport.extendedEndDate(
            currentEndDate: pastEnd,
            now: now,
            extensionMinutes: 30
        )
        XCTAssertEqual(fromPast, Date(timeIntervalSince1970: 1_000 + 30 * 60))
    }

    func test_initialEndDate_indefiniteIsNil_timedUsesNowPlusMinutes() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertNil(KeepAwakeSessionSupport.initialEndDate(duration: .indefinite, now: now))
        XCTAssertEqual(
            KeepAwakeSessionSupport.initialEndDate(duration: .minutes30, now: now),
            Date(timeIntervalSince1970: 2_000 + 30 * 60)
        )
    }

    func test_shouldEndForExpiredDeadline_onlyTimedActivePastEnd() {
        let now = Date(timeIntervalSince1970: 1_000)
        let past = Date(timeIntervalSince1970: 900)
        let future = Date(timeIntervalSince1970: 1_100)
        XCTAssertFalse(
            KeepAwakeSessionSupport.shouldEndForExpiredDeadline(state: .inactive, now: now)
        )
        XCTAssertFalse(
            KeepAwakeSessionSupport.shouldEndForExpiredDeadline(
                state: .active(endDate: nil),
                now: now
            )
        )
        XCTAssertFalse(
            KeepAwakeSessionSupport.shouldEndForExpiredDeadline(
                state: .active(endDate: future),
                now: now
            )
        )
        XCTAssertTrue(
            KeepAwakeSessionSupport.shouldEndForExpiredDeadline(
                state: .active(endDate: past),
                now: now
            )
        )
        XCTAssertTrue(
            KeepAwakeSessionSupport.shouldEndForExpiredDeadline(
                state: .active(endDate: now),
                now: now
            )
        )
    }

    // MARK: - 通知决策

    func test_notificationDecision_byEndReasonAndCleanup() {
        XCTAssertEqual(
            KeepAwakeSessionSupport.notificationDecision(endReason: .manual, enteredCleanupRequired: false),
            .none
        )
        XCTAssertEqual(
            KeepAwakeSessionSupport.notificationDecision(endReason: .featureUninstall, enteredCleanupRequired: true),
            .none
        )
        XCTAssertEqual(
            KeepAwakeSessionSupport.notificationDecision(endReason: .applicationTermination, enteredCleanupRequired: false),
            .none
        )
        XCTAssertEqual(
            KeepAwakeSessionSupport.notificationDecision(endReason: .durationElapsed, enteredCleanupRequired: false),
            .sessionEnded(.durationElapsed)
        )
        XCTAssertEqual(
            KeepAwakeSessionSupport.notificationDecision(endReason: .lowBattery, enteredCleanupRequired: true),
            .cleanupRequiredWarning(.lowBattery)
        )
    }
}
