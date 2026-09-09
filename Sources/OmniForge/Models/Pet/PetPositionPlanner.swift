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

    /// 吸附到地面（可见区底边）。
    static func snapToGround(_ position: CGPoint, to screen: PetScreenGeometry) -> CGPoint {
        CGPoint(x: position.x, y: screen.groundY)
    }

    /// 是否站在地面上。
    static func isOnGround(_ position: CGPoint, to screen: PetScreenGeometry) -> Bool {
        abs(position.y - screen.groundY) < 0.5
    }

    /// 一步重力下落：返回新位置与是否已落地。
    /// - Parameters:
    ///   - velocity: 当前下落速度（点/秒，向下为负）。
    ///   - dt: 时间步长（秒）。
    ///   - acceleration: 重力加速度（点/秒²，向下为负）。
    static func applyGravity(
        position: CGPoint,
        velocity: CGFloat,
        dt: TimeInterval,
        acceleration: CGFloat,
        screen: PetScreenGeometry
    ) -> (position: CGPoint, velocity: CGFloat, landed: Bool) {
        let newVelocity = velocity + acceleration * CGFloat(dt)
        let candidate = CGPoint(x: position.x, y: position.y + newVelocity * CGFloat(dt))
        if candidate.y <= screen.groundY {
            return (CGPoint(x: position.x, y: screen.groundY), 0, true)
        }
        return (candidate, newVelocity, false)
    }

    /// 行走一步：抵达屏幕边缘时转身，返回新位置与实际方向。
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - direction: 当前朝向。
    ///   - distance: 期望步长（正数）。
    static func stepWalk(
        position: CGPoint,
        direction: PetDirection,
        distance: CGFloat,
        petSize: CGSize,
        screen: PetScreenGeometry
    ) -> (position: CGPoint, direction: PetDirection) {
        let frame = screen.visibleFrame
        let maxX = max(frame.maxX - petSize.width, frame.minX)
        let candidateX = position.x + distance * direction.horizontalSign
        if candidateX < frame.minX {
            // 撞左边缘：转身并镜像超出量，避免在边界处抖动。
            let overflow = frame.minX - candidateX
            return (CGPoint(x: min(frame.minX + overflow, maxX), y: position.y), .right)
        }
        if candidateX > maxX {
            let overflow = candidateX - maxX
            return (CGPoint(x: max(frame.minX, maxX - overflow), y: position.y), .left)
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
