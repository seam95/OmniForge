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
        hasMetrics: Bool = false,
        menuBarIconEnabled: Bool = true
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
            menuBarIconEnabled: menuBarIconEnabled,
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

    // MARK: - Icon visibility & badge style

    func test_active_showsKeepAwakeBadgeDot() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .active(endDate: now.addingTimeInterval(600)))
        )
        XCTAssertTrue(state.iconVisible)
        XCTAssertEqual(state.badge, .keepAwakeActive)
    }

    func test_inactive_iconAdaptsTemplate_withoutBadge() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(state: .inactive)
        )
        XCTAssertTrue(state.iconVisible)
        XCTAssertEqual(state.badge, .hidden)
    }

    func test_cleanupRequired_showsWarningBadge() {
        let residual = KeepAwakeResidualEffects.systemAssertion
        let state = StatusBarRenderStateBuilder.build(
            baseInput(
                state: .cleanupRequired(residual, .assertionReleaseFailed(kind: "system", code: 1))
            )
        )
        XCTAssertEqual(state.badge, .keepAwakeWarning)
        XCTAssertEqual(state.tooltip, .cleanupRequired)
        XCTAssertEqual(state.contextMenu, .cleanupRequired)
        XCTAssertEqual(state.countdown, .hidden)
    }

    func test_menuBarIconDisabled_hidesIconRegardlessOfSession() {
        let state = StatusBarRenderStateBuilder.build(
            baseInput(
                state: .active(endDate: nil),
                menuBarIconEnabled: false
            )
        )
        XCTAssertFalse(state.iconVisible)
        // 圆点样式仍由会话状态推导（controller 在开关关闭时统一抑制显示）。
        XCTAssertEqual(state.badge, .keepAwakeActive)
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

    // MARK: - Badge priority / equality

    func test_badge_keepAwakeTakesPriorityOverLock() {
        // 活动会话 + 输入锁定 → 橙点优先
        let active = StatusBarRenderStateBuilder.build(
            baseInput(state: .active(endDate: nil), locked: true)
        )
        XCTAssertEqual(active.badge, .keepAwakeActive)

        // 非活动 + 输入锁定 → 蓝点
        let lockedIdle = StatusBarRenderStateBuilder.build(baseInput(locked: true))
        XCTAssertEqual(lockedIdle.badge, .lock)

        // 非活动 + 未锁定 → 无圆点
        let idle = StatusBarRenderStateBuilder.build(baseInput(locked: false))
        XCTAssertEqual(idle.badge, .hidden)
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
        XCTAssertTrue(first.iconVisible)
        XCTAssertEqual(first.badge, .keepAwakeActive)
        XCTAssertTrue(first.mainItemVisible)
    }

    func test_featureUnavailable_hidesKeepAwakeChrome() {
        var input = baseInput(state: .active(endDate: nil))
        input.isFeatureAvailable = false
        let state = StatusBarRenderStateBuilder.build(input)
        XCTAssertTrue(state.iconVisible)
        XCTAssertEqual(state.countdown, .hidden)
        XCTAssertFalse(state.includeOpenKeepAwakeSettings)
        XCTAssertTrue(state.includeQuit)
    }
}
