import SwiftUI

/// SPEC §7.3 切换语义：由调用方按 route 显式表达，不从枚举顺序猜测。
enum PageSwitchSemantics {
    /// 平级页面：淡出后淡入，无位移。
    case peer
    /// 层级前进：进入下一层。
    case forward
    /// 层级返回：回到上一层。
    case backward
}

/// SPEC §7.1 Motion Token 常量：数值暴露以便确定性断言。
enum PageSwitchMotionToken {
    /// Tab/分段选中底块弹簧（临界阻尼，无过冲）。
    static let indicatorSpringResponse: TimeInterval = 0.22
    static let indicatorSpringDamping: Double = 1

    /// 过滤器选中态（SPEC §5.2：过滤器只动局部，不做页面转场）。
    static let filterSelectionDuration: TimeInterval = 0.12

    static var filterSelection: Animation {
        .easeOut(duration: filterSelectionDuration)
    }

    /// 选中底块动画；Reduce Motion 下改为 80ms 颜色/透明度过渡（SPEC §7.4.3）。
    static func selectionIndicator(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: PageSwitchMotion.reduceMotionMaxDuration)
            : .spring(
                response: indicatorSpringResponse,
                dampingFraction: indicatorSpringDamping
            )
    }
}

/// SPEC §7.2/§7.3/§7.4：一次切换的动效参数。
/// 时长与位移以数值暴露；`Animation` 仅由数值派生，保证视觉与阶段时钟一致。
struct PageSwitchMotion {
    /// Reduce Motion 下所有透明度过渡的上限（SPEC §7.4.2）。
    static let reduceMotionMaxDuration: TimeInterval = 0.08

    /// 旧内容淡出时长（平级 60ms / 层级 70ms）。
    var exitDuration: TimeInterval
    /// 新内容淡入时长（平级 120ms / 层级 130ms）。
    var enterDuration: TimeInterval
    /// 旧内容退出终点的横向位移（层级 ±4pt，平级与 RM 为 0）。
    var exitOffsetX: CGFloat
    /// 新内容进入起点的横向位移（层级 ±12pt，平级与 RM 为 0）。
    var enterStartOffsetX: CGFloat

    var exitAnimation: Animation {
        .easeOut(duration: exitDuration)
    }

    var enterAnimation: Animation {
        // 层级进入为 easeInOut；平级无位移，曲线等价于 easeOut。
        hasDirectionalOffset
            ? .easeInOut(duration: enterDuration)
            : .easeOut(duration: enterDuration)
    }

    private var hasDirectionalOffset: Bool {
        exitOffsetX != 0 || enterStartOffsetX != 0
    }

    /// 按语义解析动效；Reduce Motion 统一降级（位移归零、时长封顶）。
    static func resolved(
        semantics: PageSwitchSemantics,
        reduceMotion: Bool
    ) -> PageSwitchMotion {
        let base: PageSwitchMotion
        switch semantics {
        case .peer:
            base = .init(
                exitDuration: 0.06,
                enterDuration: 0.12,
                exitOffsetX: 0,
                enterStartOffsetX: 0
            )
        case .forward:
            // 前进：旧页向退出方向轻移，新页自前进方向 12pt 处进入。
            base = .init(
                exitDuration: 0.07,
                enterDuration: 0.13,
                exitOffsetX: -4,
                enterStartOffsetX: 12
            )
        case .backward:
            base = .init(
                exitDuration: 0.07,
                enterDuration: 0.13,
                exitOffsetX: 4,
                enterStartOffsetX: -12
            )
        }
        guard reduceMotion else { return base }
        return .init(
            exitDuration: min(base.exitDuration, reduceMotionMaxDuration),
            enterDuration: min(base.enterDuration, reduceMotionMaxDuration),
            exitOffsetX: 0,
            enterStartOffsetX: 0
        )
    }
}
