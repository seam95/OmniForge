import Foundation

struct ScrollWheelEventTraits: Equatable {
    let isContinuous: Bool
    let momentumPhase: Int64
    let scrollPhase: Int64
    let scrollCount: Int64
}

enum ScrollInverterSupport {
    /// 触摸设备在手势相位事件结束后，仍可能在一小段时间内发出无相位
    /// 的连续事件，这段时间内仍归属同一触摸设备。
    static let touchGestureGraceSeconds: TimeInterval = 1.0

    static func shouldInvertMouseWheel(_ traits: ScrollWheelEventTraits,
                                       secondsSinceLastGesturePhase: TimeInterval?) -> Bool {
        if !traits.isContinuous {
            return true
        }
        guard traits.momentumPhase == 0, traits.scrollPhase == 0 else {
            return false
        }
        // 触控板/Magic Mouse 在手势结束与惯性开始之间会发出一个无相位
        // 的过渡事件，但仍然携带该手势的 scrollCount。鼠标滚轮即便
        // 上报为连续也从不携带相位，因此只有紧跟在带相位事件之后的
        // 这种事件才视为触摸。
        if traits.scrollCount != 0,
           let elapsed = secondsSinceLastGesturePhase,
           elapsed <= touchGestureGraceSeconds {
            return false
        }
        return true
    }
}
