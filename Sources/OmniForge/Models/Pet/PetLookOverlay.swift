import CoreGraphics
import Foundation

/// 看向方向索引：纯函数，只输出 16 向槽位（0…15），不感知图集。
/// 坐标统一为 AppKit 屏幕坐标（Y 向上）；顺时针编号，正上 / 右 / 下 / 左 = 0 / 4 / 8 / 12。
/// 半格边界（11.25° + 22.5k）归入顺时针下一格。
enum PetLookOverlay {
    /// 方向槽位总数（petdex v2 行 9/10 的固定容量）。
    static let directionCount = 16

    /// 内死区半径（pt）：指针与视线枢轴的距离小于该值不产生看向。
    /// 取值对齐 Codex 桌面宠物参考实现（其判定为 ` hypot > 35 `）。两个作用：
    /// 1. 指针刚越过窗缘时不算看向，避免方向在相邻两格间反复横跳；
    /// 2. 指针贴近枢轴时 `atan2` 方向随微小位移剧变，需留出稳定区。
    static let innerDeadZone: CGFloat = 35

    /// 外截止半径（pt）：指针与枢轴距离超过该值不再跟随。
    /// 对齐参考实现的 ` hypot < 1100 `；远距时方向变化对宠物已无感知意义。
    static let outerCutoff: CGFloat = 1100

    /// 视线枢轴相对窗口几何中心的纵向偏移（正值上移）。
    /// +0.05 使枢轴落在窗口高度 55% 处，即宠物头部 / 眼部位置。
    /// 参考实现以 ` height * 0.45 `（自顶部起算）为枢轴；本项目坐标为 Y 向上，
    /// 顶部起算 45% 换算为底部起算 55%，即 ` midY + height * 0.05 `。
    /// 以窗口中心为枢轴会把头部朝向整体算偏，故必须上移至眼位。
    static let pivotVerticalOffset: CGFloat = 0.05

    /// 窗口内的视线枢轴（宠物眼位）。
    static func pivot(in petRect: CGRect) -> CGPoint {
        CGPoint(x: petRect.midX, y: petRect.midY + petRect.height * pivotVerticalOffset)
    }

    /// 指针是否位于宠物窗口矩形内（含边界）。半开区间显式判定，
    /// 避免 `CGRect.contains` 对边界的处理在浮点下不稳定。
    ///
    /// 悬停边沿检测使用本函数，**不**复用 `directionIndex == nil`：
    /// 后者的 nil 还包含「距枢轴过近 / 过远」两种语义，拿它判矩形内外会把
    /// 窗外 35pt 内的指针误判为窗内，导致悬停误触发。
    static func isInside(_ pointer: CGPoint, petRect: CGRect) -> Bool {
        let insideX = pointer.x >= petRect.minX && pointer.x <= petRect.maxX
        let insideY = pointer.y >= petRect.minY && pointer.y <= petRect.maxY
        return insideX && insideY
    }

    /// 计算指针相对宠物眼位的看向方向索引。
    /// - Parameters:
    ///   - pointer: 指针屏幕坐标。
    ///   - petRect: 宠物窗口矩形。
    ///   - pivotOverride: 视线枢轴覆写；nil 时取 `pivot(in:)`（眼位）。
    /// - Returns: 需要生效看向时返回 0…15；否则 nil。nil 的三种情形：
    ///   指针在矩形内（含边界）、距枢轴小于 `innerDeadZone`、距枢轴大于 `outerCutoff`。
    ///   死区判定与调用方的拖动 / 投掷禁用互补，共同决定看向是否生效。
    static func directionIndex(
        pointer: CGPoint,
        petRect: CGRect,
        pivotOverride: CGPoint? = nil
    ) -> Int? {
        // 含边界的矩形内为死区：与悬停触发域同源，指针在宠物身上时不做看向。
        if isInside(pointer, petRect: petRect) { return nil }

        let anchor = pivotOverride ?? pivot(in: petRect)
        let dx = pointer.x - anchor.x
        let dy = pointer.y - anchor.y
        // 内死区（贴近枢轴）与外截止（过远）均不产生看向。
        let distance = hypot(dx, dy)
        guard distance > innerDeadZone, distance < outerCutoff else { return nil }

        // atan2(dx, dy)：正上 = 0°、顺时针增大（AppKit Y 向上坐标系下右 = 90°）。
        let degrees = (atan2(dx, dy) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
        // .rounded() 半格边界向上取整（顺时针下一格）；% 16 处理 359.x°→0 的衔接。
        // 加 1e-9 偏移抵消三角函数往返的浮点误差，让数学半格边界（11.25° + 22.5k）
        // 稳定归入下一格——该偏移对应约 6e-8 pt，物理上不可感知。
        let slotValue = degrees / 22.5 + 1e-9
        return Int(slotValue.rounded()) % directionCount
    }
}
