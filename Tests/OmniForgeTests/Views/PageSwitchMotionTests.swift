import XCTest
@testable import OmniForge

/// SPEC §7 Motion Token 与 §7.4 Reduce Motion 策略。
final class PageSwitchMotionTests: XCTestCase {
    private let allSemantics: [PageSwitchSemantics] = [
        .peer, .lateralForward, .lateralBackward, .forward, .backward,
    ]

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

    func test_lateralSemantics_shareDirectionalMotionWithHierarchy() {
        // 平级滑移与层级 push 有意共享位移语言（SPEC 三期），仅语义来源不同。
        let forward = PageSwitchMotion.resolved(semantics: .forward, reduceMotion: false)
        let lateralForward = PageSwitchMotion.resolved(semantics: .lateralForward, reduceMotion: false)
        XCTAssertEqual(lateralForward.exitDuration, forward.exitDuration, accuracy: 0.001)
        XCTAssertEqual(lateralForward.enterDuration, forward.enterDuration, accuracy: 0.001)
        XCTAssertEqual(lateralForward.exitOffsetX, forward.exitOffsetX)
        XCTAssertEqual(lateralForward.enterStartOffsetX, forward.enterStartOffsetX)

        let backward = PageSwitchMotion.resolved(semantics: .backward, reduceMotion: false)
        let lateralBackward = PageSwitchMotion.resolved(semantics: .lateralBackward, reduceMotion: false)
        XCTAssertEqual(lateralBackward.exitDuration, backward.exitDuration, accuracy: 0.001)
        XCTAssertEqual(lateralBackward.enterDuration, backward.enterDuration, accuracy: 0.001)
        XCTAssertEqual(lateralBackward.exitOffsetX, backward.exitOffsetX)
        XCTAssertEqual(lateralBackward.enterStartOffsetX, backward.enterStartOffsetX)
    }

    func test_lateralResolution_byNavigationOrder() {
        let order = ["monitor", "token", "tools"]
        XCTAssertEqual(
            PageSwitchSemantics.lateral(from: "monitor", to: "token", order: order),
            .lateralForward,
            "目标在源右侧 → lateralForward"
        )
        XCTAssertEqual(
            PageSwitchSemantics.lateral(from: "tools", to: "token", order: order),
            .lateralBackward,
            "目标在源左侧 → lateralBackward"
        )
        XCTAssertEqual(
            PageSwitchSemantics.lateral(from: "monitor", to: "monitor", order: order),
            .peer,
            "相同 route 回退纯淡切"
        )
        XCTAssertEqual(
            PageSwitchSemantics.lateral(from: "monitor", to: "unknown", order: order),
            .peer,
            "order 外 route 回退纯淡切，不猜测"
        )
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
