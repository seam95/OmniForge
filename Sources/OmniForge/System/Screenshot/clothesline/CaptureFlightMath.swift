// Sources/OmniForge/System/Screenshot/clothesline/CaptureFlightMath.swift
import CoreGraphics

/// 飞行/掉落动画插值，纯函数（120Hz 驱动逐帧取值）。
enum CaptureFlightMath {
    struct FlightState {
        var bounds: CGRect      // 动画卡尺寸（含相框）
        var position: CGPoint   // 窗内坐标，卡顶中心
        var angle: CGFloat      // 弧度，正值顺时针（CA 需取负）
        var chrome: Float       // 相框+衣夹渐显 0…1
    }

    struct FallState {
        var offset: CGFloat     // 向下位移
        var angle: CGFloat      // 相对静止角的附加倾角（度）
        var opacity: Float
    }

    static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// (a,b) 窗口内的平滑阶跃。
    static func smoothstep(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// 起点矩形 → 落位矩形：缩放、抛物弧、倾斜入位、铬件渐显。
    /// position/angle 以「卡顶中心为锚点」口径输出（CALayer anchorPoint (0.5, 1)）。
    static func flightState(k rawK: Double, from: CGRect, to: CGRect, tilt: CGFloat, arc: CGFloat) -> FlightState {
        let k = CGFloat(easeInOutCubic(rawK))
        let chrome = Float(smoothstep(Double(k), 0.35, 1))
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return FlightState(
            bounds: CGRect(x: 0, y: 0, width: lerp(from.width, to.width), height: lerp(from.height, to.height)),
            position: CGPoint(
                x: lerp(from.midX, to.midX),
                y: lerp(from.maxY, to.maxY) + sin(.pi * k) * arc),
            angle: tilt * k,
            chrome: chrome)
    }

    /// 掉落：cubic ease-in 下坠 520pt、倾斜加大、淡出。
    static func fallState(k rawK: Double, tilt: CGFloat) -> FallState {
        let e = CGFloat(rawK * rawK * rawK)
        return FallState(offset: 520 * e, angle: (tilt * 7 + 20) * e, opacity: Float(1 - e))
    }
}
