import CoreGraphics
import Foundation

/// 看向方向索引：纯函数，只输出 16 向槽位（0…15），不感知图集。
/// 坐标统一为 AppKit 屏幕坐标（Y 向上）；顺时针编号，正上 / 右 / 下 / 左 = 0 / 4 / 8 / 12。
/// 半格边界（11.25° + 22.5k）归入顺时针下一格。
enum PetLookOverlay {
    /// 方向槽位总数（petdex v2 行 9/10 的固定容量）。
    static let directionCount = 16

    /// 计算指针相对宠物矩形中心的看向方向索引。
    /// - Returns: 指针在矩形**外**（不含边界）时返回 0…15；矩形内（含边界）返回 nil（死区）。
    ///   死区判定与调用方的拖动 / 投掷禁用互补，共同决定看向是否生效。
    static func directionIndex(pointer: CGPoint, petRect: CGRect) -> Int? {
        // 含边界的矩形内为死区：CGRect.contains 对边界的处理在浮点下不稳定，显式半开区间判定。
        let insideX = pointer.x >= petRect.minX && pointer.x <= petRect.maxX
        let insideY = pointer.y >= petRect.minY && pointer.y <= petRect.maxY
        if insideX && insideY { return nil }

        let dx = pointer.x - petRect.midX
        let dy = pointer.y - petRect.midY
        // atan2(dx, dy)：正上 = 0°、顺时针增大（AppKit Y 向上坐标系下右 = 90°）。
        let degrees = (atan2(dx, dy) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
        // .rounded() 半格边界向上取整（顺时针下一格）；% 16 处理 359.x°→0 的衔接。
        // 加 1e-9 偏移抵消三角函数往返的浮点误差，让数学半格边界（11.25° + 22.5k）
        // 稳定归入下一格——该偏移对应约 6e-8 pt，物理上不可感知。
        let slotValue = degrees / 22.5 + 1e-9
        return Int(slotValue.rounded()) % directionCount
    }
}
