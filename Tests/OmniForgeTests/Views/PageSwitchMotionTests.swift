import XCTest
@testable import OmniForge

/// SPEC §7 Motion Token 与 §7.4 Reduce Motion 策略。
final class PageSwitchMotionTests: XCTestCase {
    private let allSemantics: [PageSwitchSemantics] = [.peer, .forward, .backward]

    func test_peerMotion_matchesSpecTokens() {
        let motion = PageSwitchMotion.resolved(semantics: .peer, reduceMotion: false)
        XCTAssertEqual(motion.exitDuration, 0.06, accuracy: 0.001)
        XCTAssertEqual(motion.enterDuration, 0.12, accuracy: 0.001)
        XCTAssertEqual(motion.exitOffsetX, 0)
        XCTAssertEqual(motion.enterStartOffsetX, 0)
    }

    func test_forwardMotion_uses4ptExitAnd12ptEnter() {
        let motion = PageSwitchMotion.resolved(semantics: .forward, reduceMotion: false)
        XCTAssertEqual(motion.exitDuration, 0.07, accuracy: 0.001)
        XCTAssertEqual(motion.enterDuration, 0.13, accuracy: 0.001)
        XCTAssertEqual(motion.exitOffsetX, -4, "旧页向退出方向轻移 4pt")
        XCTAssertEqual(motion.enterStartOffsetX, 12, "新页自前进方向 12pt 处进入")
    }

    func test_backwardMotion_mirrorsForward() {
        let motion = PageSwitchMotion.resolved(semantics: .backward, reduceMotion: false)
        XCTAssertEqual(motion.exitOffsetX, 4)
        XCTAssertEqual(motion.enterStartOffsetX, -12)
        XCTAssertEqual(motion.exitDuration, 0.07, accuracy: 0.001)
        XCTAssertEqual(motion.enterDuration, 0.13, accuracy: 0.001)
    }

    func test_reduceMotion_zeroesAllOffsetsAndCapsDurations() {
        for semantics in allSemantics {
            let motion = PageSwitchMotion.resolved(semantics: semantics, reduceMotion: true)
            XCTAssertEqual(motion.exitOffsetX, 0, "\(semantics)：位移必须归零")
            XCTAssertEqual(motion.enterStartOffsetX, 0, "\(semantics)：位移必须归零")
            XCTAssertLessThanOrEqual(
                motion.exitDuration,
                PageSwitchMotion.reduceMotionMaxDuration,
                "\(semantics)：透明度过渡不得超过 80ms"
            )
            XCTAssertLessThanOrEqual(
                motion.enterDuration,
                PageSwitchMotion.reduceMotionMaxDuration,
                "\(semantics)：透明度过渡不得超过 80ms"
            )
        }
    }

    func test_peerContentToken_matchesPeerEnterPace() {
        XCTAssertEqual(PageSwitchMotionToken.peerContentDuration, 0.12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            PageSwitchMotion.reduceMotionMaxDuration,
            PageSwitchMotionToken.peerContentDuration,
            "Reduce Motion 分支时长不得超过常规分支"
        )
    }

    func test_selectionIndicatorToken_matchesSpecSpring() {
        XCTAssertEqual(PageSwitchMotionToken.indicatorSpringResponse, 0.22, accuracy: 0.001)
        XCTAssertEqual(PageSwitchMotionToken.indicatorSpringDamping, 1, accuracy: 0.001)
        XCTAssertEqual(PageSwitchMotionToken.filterSelectionDuration, 0.12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            PageSwitchMotion.reduceMotionMaxDuration,
            0.08,
            "Reduce Motion 下选中底块过渡 ≤ 80ms"
        )
    }
}
