import XCTest
@testable import OmniForge

/// 鼠标与触控板纯逻辑测试 — 复刻 vorssaint 的 Support 单元测试。
/// 覆盖 ScrollInverterSupport / MouseNavigationSupport / SmoothScrollSupport。
final class MouseSupportTests: XCTestCase {

    // MARK: - ScrollInverterSupport

    func test_scrollInverter_flipsClassicMouseWheelTicks() {
        let traits = ScrollWheelEventTraits(isContinuous: false, momentumPhase: 0, scrollPhase: 0, scrollCount: 0)
        XCTAssertTrue(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: nil))
    }

    func test_scrollInverter_flipsPhaselessContinuousWheelEvents() {
        let traits = ScrollWheelEventTraits(isContinuous: true, momentumPhase: 0, scrollPhase: 0, scrollCount: 0)
        XCTAssertTrue(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: nil))
    }

    func test_scrollInverter_leavesTouchScrollingPhasesAlone() {
        let traits = ScrollWheelEventTraits(isContinuous: true, momentumPhase: 0, scrollPhase: 2, scrollCount: 0)
        XCTAssertFalse(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: nil))
    }

    func test_scrollInverter_leavesMomentumScrollingAlone() {
        let traits = ScrollWheelEventTraits(isContinuous: true, momentumPhase: 3, scrollPhase: 0, scrollCount: 1)
        XCTAssertFalse(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: 0.1))
    }

    func test_scrollInverter_leavesTouchTransitionEventsAlone() {
        // 无相位、带计数、紧跟在带相位事件之后 → 视为触摸
        let traits = ScrollWheelEventTraits(isContinuous: true, momentumPhase: 0, scrollPhase: 0, scrollCount: 2)
        XCTAssertFalse(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: 0.05))
    }

    func test_scrollInverter_flipsCountedWheelEventsLongAfterGesture() {
        let traits = ScrollWheelEventTraits(isContinuous: true, momentumPhase: 0, scrollPhase: 0, scrollCount: 2)
        XCTAssertTrue(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: 5.0))
    }

    func test_scrollInverter_flipsCountedWheelEventsWhenNoGestureSeen() {
        let traits = ScrollWheelEventTraits(isContinuous: true, momentumPhase: 0, scrollPhase: 0, scrollCount: 2)
        XCTAssertTrue(ScrollInverterSupport.shouldInvertMouseWheel(traits, secondsSinceLastGesturePhase: nil))
    }

    // MARK: - MouseNavigationSupport

    func test_backButtonMapsToBack() {
        XCTAssertEqual(
            MouseNavigationSupport.direction(forButtonNumber: MouseNavigationSupport.backButtonNumber),
            .back
        )
    }

    func test_forwardButtonMapsToForward() {
        XCTAssertEqual(
            MouseNavigationSupport.direction(forButtonNumber: MouseNavigationSupport.forwardButtonNumber),
            .forward
        )
    }

    func test_middleButtonNeverConsumedAsNavigation() {
        XCTAssertNil(MouseNavigationSupport.direction(forButtonNumber: 2))
    }

    func test_unrelatedExtraButtonsPassThrough() {
        XCTAssertNil(MouseNavigationSupport.direction(forButtonNumber: 9))
    }

    func test_backUsesCommandLeftBracket() {
        XCTAssertEqual(MouseNavigationSupport.commandCharacter(for: .back), "[")
    }

    func test_forwardUsesCommandRightBracket() {
        XCTAssertEqual(MouseNavigationSupport.commandCharacter(for: .forward), "]")
    }

    // MARK: - SmoothScrollSupport

    func test_oneWheelTickQueuesOneStepOfGlide() {
        XCTAssertEqual(SmoothScrollSupport.remaining(afterTicks: 1, step: 40, current: 0), 40)
    }

    func test_sameDirectionTicksAddToLeftover() {
        XCTAssertEqual(SmoothScrollSupport.remaining(afterTicks: 2, step: 40, current: 30), 110)
    }

    func test_reversingDirectionAbandonsLeftover() {
        XCTAssertEqual(SmoothScrollSupport.remaining(afterTicks: -1, step: 40, current: 100), -40)
    }

    func test_ticklessEventLeavesGlideUntouched() {
        XCTAssertEqual(SmoothScrollSupport.remaining(afterTicks: 0, step: 40, current: 25), 25)
    }

    func test_frameEmitsFractionOfRemaining() {
        XCTAssertEqual(SmoothScrollSupport.frameDelta(remaining: 100), 18)
    }

    func test_negativeGlidesEmitNegativeFrames() {
        XCTAssertEqual(SmoothScrollSupport.frameDelta(remaining: -100), -18)
    }

    func test_smallLeftoversFlushInOneFinalFrame() {
        XCTAssertEqual(SmoothScrollSupport.frameDelta(remaining: 0.8), 0.8)
    }

    func test_glideNeverStallsBelowOnePixelPerFrame() {
        XCTAssertEqual(SmoothScrollSupport.frameDelta(remaining: 3), 1)
    }

    func test_noRemainingDistanceEmitsNothing() {
        XCTAssertEqual(SmoothScrollSupport.frameDelta(remaining: 0), 0)
    }

    func test_unsetStepFallsBackToDefault() {
        XCTAssertEqual(SmoothScrollSupport.sanitizedStep(0), SmoothScrollSupport.defaultStep)
    }

    func test_stepClampsToRange() {
        XCTAssertEqual(SmoothScrollSupport.sanitizedStep(500), SmoothScrollSupport.stepRange.upperBound)
    }

    func test_naturalScrollingPreFlipsGlide() {
        XCTAssertEqual(SmoothScrollSupport.postedDelta(18, naturalScrolling: true), -18)
    }

    func test_classicScrollingPostsGlideAsIs() {
        XCTAssertEqual(SmoothScrollSupport.postedDelta(18, naturalScrolling: false), 18)
    }
}
