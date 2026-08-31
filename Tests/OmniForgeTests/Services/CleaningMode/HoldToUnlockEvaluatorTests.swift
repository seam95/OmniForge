import XCTest
@testable import OmniForge

/// 长按解锁判定纯组件直测（SPEC D4）。
final class HoldToUnlockEvaluatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func test_pressBegan_未满时长不满足() {
        var evaluator = HoldToUnlockEvaluator(requiredDuration: 3)
        evaluator.pressBegan(at: base)
        XCTAssertFalse(evaluator.isSatisfied(at: base.addingTimeInterval(2.9)))
        XCTAssertEqual(evaluator.progress(at: base.addingTimeInterval(1.5)), 0.5, accuracy: 0.001)
    }

    func test_pressBegan_满时长满足且进度封顶() {
        var evaluator = HoldToUnlockEvaluator(requiredDuration: 3)
        evaluator.pressBegan(at: base)
        XCTAssertTrue(evaluator.isSatisfied(at: base.addingTimeInterval(3)))
        XCTAssertEqual(evaluator.progress(at: base.addingTimeInterval(10)), 1, accuracy: 0.001)
    }

    func test_pressEnded_中途松手重置() {
        var evaluator = HoldToUnlockEvaluator(requiredDuration: 3)
        evaluator.pressBegan(at: base)
        evaluator.pressEnded()
        XCTAssertFalse(evaluator.isHolding)
        XCTAssertFalse(evaluator.isSatisfied(at: base.addingTimeInterval(10)))
        XCTAssertEqual(evaluator.progress(at: base.addingTimeInterval(10)), 0)
    }

    func test_快速交替按下松开不满足() {
        var evaluator = HoldToUnlockEvaluator(requiredDuration: 3)
        for tick in 0..<10 {
            evaluator.pressBegan(at: base.addingTimeInterval(Double(tick)))
            evaluator.pressEnded()
        }
        XCTAssertFalse(evaluator.isSatisfied(at: base.addingTimeInterval(100)))
    }

    func test_重复按下以最近一次为准() {
        var evaluator = HoldToUnlockEvaluator(requiredDuration: 3)
        evaluator.pressBegan(at: base)
        evaluator.pressBegan(at: base.addingTimeInterval(5))
        // 相对第二次按下未满时长。
        XCTAssertFalse(evaluator.isSatisfied(at: base.addingTimeInterval(6)))
        XCTAssertTrue(evaluator.isSatisfied(at: base.addingTimeInterval(8)))
    }

    func test_未按下时进度为零() {
        let evaluator = HoldToUnlockEvaluator(requiredDuration: 3)
        XCTAssertEqual(evaluator.progress(at: base), 0)
        XCTAssertFalse(evaluator.isSatisfied(at: base))
    }
}
