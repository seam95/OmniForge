import AppKit
import CoreGraphics
import Foundation

/// 标注几何工具函数。实现逻辑参照 capcap（`Editor/Annotations.swift`），
/// 保留 OmniForge 既有函数签名以维持测试契约与值类型 API。

/// 描边路径的命中测试容差（pt）。与 capcap 保持一致。
let strokeHitTolerance: CGFloat = 8

/// 检查描边膨胀后的路径是否包含指定点。
///
/// 参照 capcap `strokedPathContains`：把路径按 `lineWidth + 4`（且不小于
/// `strokeHitTolerance`）的宽度 stroke 成填充区域，再做 contains 测试。
/// 这样命中区域随线宽缩放，细笔也能被点中。
///
/// - Parameters:
///   - point: 待测试点
///   - path: CGPath
///   - lineWidth: 描边宽度
/// - Returns: 点是否在描边命中区域内
func strokedPathContains(_ point: CGPoint, path: CGPath, lineWidth: CGFloat) -> Bool {
    let hitWidth = max(lineWidth + 4, strokeHitTolerance)
    let hitPath = path.copy(strokingWithWidth: hitWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return hitPath.contains(point)
}

/// 点到线段的最短距离。
func distanceFromPoint(_ point: CGPoint, toSegment start: CGPoint, end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else {
        return hypot(point.x - start.x, point.y - start.y)
    }
    var t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
    t = min(max(t, 0), 1)
    let projX = start.x + t * dx
    let projY = start.y + t * dy
    return hypot(point.x - projX, point.y - projY)
}

/// 点到二次贝塞尔曲线的最短距离（采样近似）。
/// 参照 capcap `distanceFrom(_:toQuadCurveFrom:to:)` 的采样思路，
/// 20 步采样对短曲线足够精确。
func distanceFromPoint(_ point: CGPoint, toQuadCurve start: CGPoint, control: CGPoint, end: CGPoint) -> CGFloat {
    var minDist = CGFloat.greatestFiniteMagnitude
    let steps = 20
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let curvePoint = CGPoint.pointOnQuadCurve(t, start: start, control: control, end: end)
        minDist = min(minDist, hypot(point.x - curvePoint.x, point.y - curvePoint.y))
    }
    return minDist
}

extension CGPoint {
    /// 二次贝塞尔曲线在参数 t 处的点。
    /// B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
    func pointOnQuadCurve(t: CGFloat, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        CGPoint.pointOnQuadCurve(t, start: start, control: control, end: end)
    }

    /// 二次贝塞尔曲线在参数 t 处的点（静态入口）。
    static func pointOnQuadCurve(_ t: CGFloat, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * start.x + 2 * mt * t * control.x + t * t * end.x
        let y = mt * mt * start.y + 2 * mt * t * control.y + t * t * end.y
        return CGPoint(x: x, y: y)
    }
}

// MARK: - 路径平滑

extension NSBezierPath {
    /// 把二次贝塞尔转换为等效三次贝塞尔追加到路径。
    /// NSBezierPath 无原生二次曲线原语，Q(P0,C,P2) 映射为
    /// C(P0, P0+2/3·(C-P0), P2+2/3·(C-P2), P2)。参照 capcap 实现。
    fileprivate func addQuadCurveAsCubic(to endPoint: NSPoint, controlPoint c: NSPoint) {
        let start = currentPoint
        let cp1 = NSPoint(
            x: start.x + (c.x - start.x) * 2.0 / 3.0,
            y: start.y + (c.y - start.y) * 2.0 / 3.0
        )
        let cp2 = NSPoint(
            x: endPoint.x + (c.x - endPoint.x) * 2.0 / 3.0,
            y: endPoint.y + (c.y - endPoint.y) * 2.0 / 3.0
        )
        curve(to: endPoint, controlPoint1: cp1, controlPoint2: cp2)
    }

    /// 用中点二次贝塞尔平滑构建穿过 `points` 的路径。
    ///
    /// 参照 capcap `NSBezierPath.smoothed(through:)`：每个原始点作为二次控制点，
    /// 锚点取相邻原始点的中点，曲线穿过中点且无硬角；连接处切线连续。
    static func smoothed(through points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { return path }
        if points.count == 2 {
            path.line(to: points[1])
            return path
        }
        let firstMid = NSPoint(
            x: (points[0].x + points[1].x) / 2,
            y: (points[0].y + points[1].y) / 2
        )
        path.line(to: firstMid)
        for i in 1..<points.count - 1 {
            let mid = NSPoint(
                x: (points[i].x + points[i + 1].x) / 2,
                y: (points[i].y + points[i + 1].y) / 2
            )
            path.addQuadCurveAsCubic(to: mid, controlPoint: points[i])
        }
        path.line(to: points[points.count - 1])
        return path
    }
}
