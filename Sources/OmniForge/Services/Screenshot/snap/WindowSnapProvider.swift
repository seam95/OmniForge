import AppKit
import CoreGraphics

/// 窗口吸附候选(视图坐标)。
struct SnapCandidate: Equatable {
    let rect: NSRect
    let windowID: CGWindowID?
}

/// 提供鼠标位置下的窗口/元素吸附候选。
/// 实现负责坐标系转换,对外只暴露视图坐标。
protocol WindowSnapProvider: AnyObject {
    /// 查询视图坐标 point 处的吸附候选。
    /// - Parameters:
    ///   - point: 视图坐标点。
    ///   - viewBounds: 视图 bounds(用于过滤超出视图的候选)。
    ///   - screenFrame: 视图所在屏的 frame(用于坐标转换)。
    ///   - visibleFrame: 视图所在屏的 visibleFrame(已扣除菜单栏/Dock,AppKit 坐标);
    ///     边缘条带吸附用它推算系统保留区。
    ///   - primaryDisplayHeight: 主屏高度(AppKit 全局 Y 翻转基准,通常 `NSScreen.screens[0].frame.maxY`)。
    /// - Returns: 候选;无合适候选返回 nil。
    func candidate(
        at point: NSPoint,
        in viewBounds: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        primaryDisplayHeight: CGFloat
    ) async -> SnapCandidate?
}

/// 视图坐标 ↔ CG 全局坐标转换纯函数。
///
/// AX / CGWindow / SCWindow 使用 CG 全局坐标(左上原点,主屏高度为 Y 翻转基准)。
/// 不得用 `screenFrame.maxY` 代替主屏高度,否则上下/不等高多屏会偏移。
enum SnapCoordinate {
    /// 视图坐标点 → CG 全局点(hit-test 输入)。
    static func cgPoint(
        viewPoint: NSPoint,
        screenFrame: NSRect,
        primaryDisplayHeight: CGFloat
    ) -> CGPoint {
        let appKitGlobal = CGPoint(
            x: viewPoint.x + screenFrame.minX,
            y: viewPoint.y + screenFrame.minY
        )
        return DisplayCoordinate.appKitGlobalPointToCGGlobal(
            appKitGlobal,
            primaryDisplayHeight: primaryDisplayHeight
        )
    }

    /// CG 全局矩形 → 视图坐标矩形(高亮绘制输入)。
    static func viewRect(
        cgRect: CGRect,
        screenFrame: NSRect,
        primaryDisplayHeight: CGFloat
    ) -> NSRect {
        let appKitGlobal = DisplayCoordinate.cgGlobalRectToAppKitGlobal(
            cgRect,
            primaryDisplayHeight: primaryDisplayHeight
        )
        return NSRect(
            x: appKitGlobal.minX - screenFrame.minX,
            y: appKitGlobal.minY - screenFrame.minY,
            width: appKitGlobal.width,
            height: appKitGlobal.height
        )
    }
}
