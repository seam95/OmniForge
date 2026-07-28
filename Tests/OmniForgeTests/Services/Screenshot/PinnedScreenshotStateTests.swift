import CoreGraphics
import XCTest
@testable import OmniForge

final class PinnedScreenshotStateTests: XCTestCase {
    func test_lock_rejectsTranslationAndScale() {
        var state = PinnedScreenshotState(scale: 1, isLocked: true, isClickThrough: false)
        XCTAssertNil(state.proposedTranslation(CGPoint(x: 10, y: -5)))
        XCTAssertNil(state.proposedScale(multiplying: 1.2))
        XCTAssertFalse(state.applyScale(1.5))
        XCTAssertEqual(state.scale, 1)
    }

    func test_unlock_allowsTranslationAndScale() {
        var state = PinnedScreenshotState(scale: 1, isLocked: false)
        XCTAssertEqual(state.proposedTranslation(CGPoint(x: 3, y: 4)), CGPoint(x: 3, y: 4))
        XCTAssertEqual(state.proposedScale(multiplying: 2)!, 2, accuracy: 0.0001)
        XCTAssertTrue(state.applyScale(0.5))
        XCTAssertEqual(state.scale, 0.5, accuracy: 0.0001)
    }

    func test_proposedScale_atMax_outwardIsNoOp() {
        let state = PinnedScreenshotState(scale: PinnedScreenshotGeometry.maxScale)
        XCTAssertNil(state.proposedScale(multiplying: 1.1))
        XCTAssertNil(state.proposedScale(multiplying: 2))
        XCTAssertEqual(state.scale, PinnedScreenshotGeometry.maxScale, accuracy: 0.0001)
        // 向内缩小仍有效
        let inward = state.proposedScale(multiplying: 0.5)
        XCTAssertNotNil(inward)
        XCTAssertEqual(inward!, PinnedScreenshotGeometry.maxScale * 0.5, accuracy: 0.0001)
    }

    func test_proposedScale_atMin_outwardIsNoOp() {
        let state = PinnedScreenshotState(scale: PinnedScreenshotGeometry.minScale)
        XCTAssertNil(state.proposedScale(multiplying: 0.5))
        XCTAssertNil(state.proposedScale(multiplying: 0.1))
        XCTAssertEqual(state.scale, PinnedScreenshotGeometry.minScale, accuracy: 0.0001)
        // 向内放大仍有效
        let inward = state.proposedScale(multiplying: 2)
        XCTAssertNotNil(inward)
        XCTAssertEqual(inward!, PinnedScreenshotGeometry.minScale * 2, accuracy: 0.0001)
    }

    func test_proposedScale_factorOne_isNoOp() {
        let state = PinnedScreenshotState(scale: 1.5)
        XCTAssertNil(state.proposedScale(multiplying: 1))
        XCTAssertEqual(state.scale, 1.5, accuracy: 0.0001)
    }

    func test_lockAndClickThrough_areIndependent() {
        var state = PinnedScreenshotState()
        state.setLocked(true)
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.isClickThrough)

        state.setClickThrough(true)
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.isClickThrough)

        state.setLocked(false)
        XCTAssertFalse(state.isLocked)
        XCTAssertTrue(state.isClickThrough)

        state.setClickThrough(false)
        XCTAssertFalse(state.isLocked)
        XCTAssertFalse(state.isClickThrough)
    }

    func test_fourCombinations_doNotCouple() {
        let combos: [(Bool, Bool)] = [
            (false, false),
            (true, false),
            (false, true),
            (true, true)
        ]
        for (locked, through) in combos {
            var state = PinnedScreenshotState(isLocked: !locked, isClickThrough: !through)
            state.setLocked(locked)
            state.setClickThrough(through)
            XCTAssertEqual(state.isLocked, locked)
            XCTAssertEqual(state.isClickThrough, through)
            // 穿透不改变缩放/位移门禁；锁定才拒绝
            if locked {
                XCTAssertNil(state.proposedTranslation(CGPoint(x: 1, y: 1)))
            } else {
                XCTAssertNotNil(state.proposedTranslation(CGPoint(x: 1, y: 1)))
            }
        }
    }

    func test_opacityIndependentOfLockAndThrough() {
        var state = PinnedScreenshotState(opacity: 1, isLocked: true, isClickThrough: true)
        state.setOpacity(0.4)
        XCTAssertEqual(state.opacity, 0.4, accuracy: 0.0001)
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.isClickThrough)
    }
}
