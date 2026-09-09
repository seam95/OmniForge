import CoreGraphics
import Foundation

/// 屏幕几何摘要：位置规划只依赖这些值，便于单测构造任意屏幕组合。
struct PetScreenGeometry: Equatable {
    /// 屏幕可见区域（已避开 Dock 与菜单栏），坐标系为全局屏幕坐标。
    let visibleFrame: CGRect
    /// 屏幕唯一标识（用于持久化恢复）。
    let identifier: String

    /// 地面高度（可见区底边）。
    var groundY: CGFloat { visibleFrame.minY }

    /// 水平可行走区间。
    var horizontalRange: ClosedRange<CGFloat> { visibleFrame.minX...visibleFrame.maxX }
}

/// 位置规划：把宠物位置约束到合法区域。
/// 全部为纯函数，输入屏幕几何与宠物尺寸，输出约束后的位置。
enum PetPositionPlanner {
    /// 把位置夹回屏幕可见区（宠物整体不出界）。
    /// - 垂直方向夹在「地面之上、可见区顶部之下」。
    static func clamp(_ position: CGPoint, petSize: CGSize, to screen: PetScreenGeometry) -> CGPoint {
        let frame = screen.visibleFrame
        let maxX = frame.maxX - petSize.width
        let maxY = frame.maxY - petSize.height
        let minX = frame.minX
        let minY = frame.minY
        // 可见区比宠物还小时以左下角为准，避免产生非法区间。
        let x = maxX >= minX ? min(max(position.x, minX), maxX) : minX
        let y = maxY >= minY ? min(max(position.y, minY), maxY) : minY
        return CGPoint(x: x, y: y)
    }

    /// 行走活动范围：以锚点为中心、左右半径受限的水平区间（宠物左下角可取值的区间），
    /// 再与屏幕可见区求交，保证宠物整体不出屏。
    /// 锚点即宠物最近一次被放置的位置——拖拽松手后它就在这附近活动，不会满屏乱走。
    static func walkRange(
        anchorX: CGFloat,
        radius: CGFloat,
        petSize: CGSize,
        screen: PetScreenGeometry
    ) -> ClosedRange<CGFloat> {
        let frame = screen.visibleFrame
        let minX = frame.minX
        let maxX = max(frame.maxX - petSize.width, minX)
        let lower = max(minX, anchorX - radius)
        let upper = min(maxX, anchorX + radius)
        // 屏幕过窄或半径过小时保证区间合法。
        return lower <= upper ? lower...upper : minX...maxX
    }

    /// 一步行走：抵达活动范围边缘时转身，返回新位置与实际方向。
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - direction: 当前朝向。
    ///   - distance: 期望步长（正数）。
    ///   - walkRange: 允许的 x 区间（宠物左下角）。
    static func stepWalk(
        position: CGPoint,
        direction: PetDirection,
        distance: CGFloat,
        walkRange: ClosedRange<CGFloat>
    ) -> (position: CGPoint, direction: PetDirection) {
        let candidateX = position.x + distance * direction.horizontalSign
        if candidateX < walkRange.lowerBound {
            // 撞左边界：转身并镜像超出量，避免在边界处抖动。
            let overflow = walkRange.lowerBound - candidateX
            return (
                CGPoint(x: min(walkRange.lowerBound + overflow, walkRange.upperBound), y: position.y),
                .right
            )
        }
        if candidateX > walkRange.upperBound {
            let overflow = candidateX - walkRange.upperBound
            return (
                CGPoint(x: max(walkRange.lowerBound, walkRange.upperBound - overflow), y: position.y),
                .left
            )
        }
        return (CGPoint(x: candidateX, y: position.y), direction)
    }

    /// 显示器配置变更后选择宠物应落脚的屏幕。
    /// 优先用记忆的屏幕标识；找不到则退回主屏（或第一个可用屏）。
    static func resolveScreen(
        rememberedIdentifier: String?,
        screens: [PetScreenGeometry],
        mainScreenIdentifier: String?
    ) -> PetScreenGeometry? {
        if let rememberedIdentifier,
           let matched = screens.first(where: { $0.identifier == rememberedIdentifier }) {
            return matched
        }
        if let mainScreenIdentifier,
           let main = screens.first(where: { $0.identifier == mainScreenIdentifier }) {
            return main
        }
        return screens.first
    }

    /// 找出包含指定位置（宠物左下角）的屏幕，用于拖拽跨屏后重定地面。
    /// 无匹配时返回最接近的屏幕。
    static func screenContaining(
        position: CGPoint,
        petSize: CGSize,
        screens: [PetScreenGeometry]
    ) -> PetScreenGeometry? {
        let petCenter = CGPoint(x: position.x + petSize.width / 2, y: position.y + petSize.height / 2)
        if let hit = screens.first(where: { $0.visibleFrame.contains(petCenter) }) {
            return hit
        }
        // 退化情形：按中心点距离取最近屏幕。
        return screens.min { lhs, rhs in
            distanceSquared(from: petCenter, to: lhs.visibleFrame.center)
                < distanceSquared(from: petCenter, to: rhs.visibleFrame.center)
        }
    }

    private static func distanceSquared(from point: CGPoint, to target: CGPoint) -> CGFloat {
        let dx = point.x - target.x
        let dy = point.y - target.y
        return dx * dx + dy * dy
    }
}

extension CGRect {
    /// 矩形中心点。
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
