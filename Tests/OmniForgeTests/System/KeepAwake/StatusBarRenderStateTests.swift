import XCTest
@testable import OmniForge

final class StatusBarRenderStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func baseInput(
        state: KeepAwakeSessionState = .inactive,
        error: KeepAwakeError? = nil,
        showCountdown: Bool = true,
        locked: Bool = false,
        hideMain: Bool = false,
        hasMetrics: Bool = false
    ) -> StatusBarRenderInput {
        StatusBarRenderInput(
            isFeatureAvailable: true,
            sessionState: state,
            lastOperationError: error,
            showCountdown: showCountdown,
            isInputLocked: locked,
            hideMainIconWhenMetricsVisible: hideMain,
            hasVisibleMetrics: hasMetrics,
            metricsSeparateItems: false,
            now: now
        )
    }

    // MARK: - Countdown format

    func test_countdown_under60Minutes_showsMinutesCeil() {
        // 45.1 分钟 → 46 min（向上取整）
        let end = now.addingTimeInterval(45.1 * 60)
        let text = StatusBarRenderStateBuilder.menuBarCountdownText(
            endDate: end,
            now: now,
            showCountdown: true
        )
        XCTAssertEqual(text, .minutes(46))
        XCTAssertEqual(text.displayString, "46 min")
    }

    func test_countdown_exactlyOneMinuteFloor() {
        let end = now.addingTimeInterval(20)
        let text = StatusBarRenderStateBuilder.menuBarCountdownText(
            endDate: end,
            now: now,
            showCountdown: true
        )
        XCTAssertEqual(text, .minutes(1))
    }

    func test_countdown_atLeast60Minutes_showsHMM() {
        let end = now.addingTimeInterval(90 * 60)
        let text = StatusBarRenderStateBuilder.menuBarCountdownText(
            endDate: end,
            now: now,
            showCountdown: true
        )
        XCTAssertEqual(text, .hoursMinutes(hours: 1, minutes: 30))
        XCTAssertEqual(text.displayString, "1:30")
    }

    func test_countdown_indefinite_showsInfinity() {
        let text = StatusBarRenderStateBuilder.menuBarCountdownText(
            endDate: nil,
            now: now,
            showCountdown: true
        )
        XCTAssertEqual(text, .indefinite)
        XCTAssertEqual(text.displayString, "∞")
    }

    func test_countdown_hiddenWhenPreferenceOff() {
        let end = now.addingTimeInterval(30 * 60)
        let text = StatusBarRenderStateBuilder.menuBarCountdownText(
            endDate: end,
            now: now,
            showCountdown: false
        )
        XCTAssertEqual(text, .hidden)
    }

    // MARK: - Icon color

    func test_active_usesFixedOrangeTint() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .active(endDate: now.addingTimeInterval(600)))
        )
        XCTAssertEqual(state.iconColor, .tint(.orange))
    }

    func test_inactive_usesTemplateIconColor() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .inactive)
        )
        XCTAssertEqual(state.iconColor, .template)
    }

    func test_cleanupRequired_overridesTintWithWarning() {
        let residual = KeepAwakeResidualEffects.systemAssertion
        let state = StatusBarRenderStateBuilder.build(
            baseInput(
                state: .cleanupRequired(residual, .assertionReleaseFailed(kind: "system", code: 1))
            )
        )
        XCTAssertEqual(state.iconColor, .cleanupWarning)
        XCTAssertEqual(state.tooltip, .cleanupRequired)
        XCTAssertEqual(state.contextMenu, .cleanupRequired)
        XCTAssertEqual(state.countdown, .hidden)
    }

    // MARK: - Main item visibility

    func test_active_overridesHideMainIconWhenMetricsVisible() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(
                state: .active(endDate: nil),
                hideMain: true,
                hasMetrics: true
            )
        )
        XCTAssertTrue(state.mainItemVisible)
    }

    func test_inactive_canHideMainIconWhenMetricsVisible() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .inactive, hideMain: true, hasMetrics: true)
        )
        XCTAssertFalse(state.mainItemVisible)
    }

    // MARK: - Context menu matrix (SPEC 11.4)

    func test_contextMenu_inactive() {
        let state = StatusBarRenderStateBuilder.build(baseInput(state: .inactive))
        XCTAssertEqual(state.contextMenu, .inactive(canRetryLastStart: false))
        XCTAssertTrue(state.includeOpenKeepAwakeSettings)
        XCTAssertTrue(state.includeQuit)
    }

    func test_contextMenu_inactiveWithError_canRetry() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .inactive, error: .systemAssertionFailed(code: 1))
        )
        XCTAssertEqual(state.contextMenu, .inactive(canRetryLastStart: true))
        if case .inactiveWithError = state.tooltip {
            // ok
        } else {
            XCTFail("expected inactiveWithError tooltip, got \(state.tooltip)")
        }
    }

    func test_contextMenu_transitional() {
        XCTAssertEqual(
            StatusBarRenderStateBuilder.build(baseInput(state: .activating)).contextMenu,
            .transitional
        )
        XCTAssertEqual(
            StatusBarRenderStateBuilder.build(baseInput(state: .deactivating)).contextMenu,
            .transitional
        )
    }

    func test_contextMenu_active() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .active(endDate: now.addingTimeInterval(120)))
        )
        XCTAssertEqual(state.contextMenu, .active)
        XCTAssertEqual(state.countdown, .minutes(2))
    }

    // MARK: - Lock badge / equality

    func test_lockBadge_independentOfSession() {
        let a = StatusBarRenderStateBuilder.build(baseInput(locked: true))
        let b = StatusBarRenderStateBuilder.build(baseInput(locked: false))
        XCTAssertTrue(a.showLockBadge)
        XCTAssertFalse(b.showLockBadge)
    }

    func test_build_isDeterministic_forInterleavedInputs() {
        var input = baseInput(
            state: .active(endDate: now.addingTimeInterval(3_600)),
            showCountdown: true,
            locked: true,
            hideMain: true,
            hasMetrics: true
        )
        let first = StatusBarRenderStateBuilder.build(input)
        // 模拟交错更新：先改锁定再改回
        input.isInputLocked = false
        _ = StatusBarRenderStateBuilder.build(input)
        input.isInputLocked = true
        let second = StatusBarRenderStateBuilder.build(input)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.countdown, .hoursMinutes(hours: 1, minutes: 0))
        XCTAssertEqual(first.iconColor, .tint(.orange))
        XCTAssertTrue(first.mainItemVisible)
    }

    func test_featureUnavailable_hidesKeepAwakeChrome() {
        var input = baseInput(state: .active(endDate: nil))
        input.isFeatureAvailable = false
        let state = StatusBarRenderStateBuilder.build(input)
        XCTAssertEqual(state.iconColor, .template)
        XCTAssertEqual(state.countdown, .hidden)
        XCTAssertFalse(state.includeOpenKeepAwakeSettings)
        XCTAssertTrue(state.includeQuit)
    }
}
