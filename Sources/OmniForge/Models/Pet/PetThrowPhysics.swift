import CoreGraphics
import Foundation

/// 投掷物理（纯逻辑）：松手后的惯性步进与多屏可通行区域碰撞。
///
/// 步进顺序固定为：总历时检查 → 位置积分（连续路径碰撞）→ 摩擦衰减 → 停速判定。
/// 可通行区域为各屏 `visibleFrame` 的并集；宠物**整个矩形**必须被并集覆盖：
/// 相邻屏共享边（横截面被两侧完全覆盖且无缝衔接）可自由通过，
/// 开口不足、屏间空隙或高速一步越界都在可通行带边界处反弹，不会穿越外缘。
enum PetThrowPhysics {
    /// 摩擦系数：每 16ms 速度保留 88%。
    static let dampingPer16ms: Double = 0.88
    /// 停止速度阈值（pt/s）：速度模低于该值即结束。
    static let stopSpeed: CGFloat = 65
    /// 投掷总时长上限（秒）：按真实单调历时计算，不累加被钳制的 dt。
    static let maxDuration: TimeInterval = 0.9
    /// 单步 dt 上限（秒）：离屏恢复或卡顿后的巨大时间差不产生瞬移。
    static let maxStepDelta: TimeInterval = 0.032
    /// 外缘反弹法向速度系数。
    static let bounceFactor: CGFloat = -0.7
    /// 屏间共享边衔接容差（pt）：相邻屏外缘间距 ≤ 该值视为无缝可通行。
    static let seamTolerance: CGFloat = 0.5

    /// 单步步进结果。
    struct StepResult: Equatable {
        /// 步进后的位置（宠物左下角）。
        let position: CGPoint
        /// 步进后的速度。
        let velocity: CGVector
        /// 投掷是否已结束（历时到限 / 停速 / 无可用屏幕）。
        let finished: Bool
    }

    /// 推进一步。
    /// - Parameters:
    ///   - position: 当前位置（宠物左下角）。
    ///   - velocity: 当前速度（pt/s）。
    ///   - elapsed: 投掷开始至今的**真实**单调历时（秒）。
    ///   - delta: 本帧时间差（秒）；积分前钳制到 `maxStepDelta`。
    ///   - petSize: 宠物窗口尺寸。
    ///   - screens: 全部屏幕几何（空集时取消运动并保留安全状态）。
    static func step(
        position: CGPoint,
        velocity: CGVector,
        elapsed: TimeInterval,
        delta: TimeInterval,
        petSize: CGSize,
        screens: [PetScreenGeometry]
    ) -> StepResult {
        // 恢复离屏 / 系统暂停后的第一 tick 若超时：先结束，不再移动一步。
        guard elapsed < maxDuration else {
            return StepResult(position: position, velocity: velocity, finished: true)
        }
        guard !screens.isEmpty else {
            return StepResult(position: position, velocity: velocity, finished: true)
        }

        // 恢复后的巨大 delta 只贡献真实历时（elapsed 已含），位移被钳制。
        let dt = CGFloat(min(max(delta, 0), maxStepDelta))
        var newPosition = position
        var newVelocity = velocity

        // 轴分解积分：先水平后垂直，各自沿连续路径求首次越界（未越界即完整位移）。
        let horizontal = sweep(
            from: newPosition.x, distance: newVelocity.dx * dt,
            extent: petSize.width,
            crossSpan: newPosition.y...newPosition.y + petSize.height,
            screens: screens, horizontal: true
        )
        newPosition.x = horizontal.position
        if horizontal.bounced { newVelocity.dx *= bounceFactor }

        let vertical = sweep(
            from: newPosition.y, distance: newVelocity.dy * dt,
            extent: petSize.height,
            crossSpan: newPosition.x...newPosition.x + petSize.width,
            screens: screens, horizontal: false
        )
        newPosition.y = vertical.position
        if vertical.bounced { newVelocity.dy *= bounceFactor }

        // 摩擦：v *= 0.88^(dt/16ms)。
        let damping = CGFloat(pow(dampingPer16ms, Double(dt) / 0.016))
        newVelocity.dx *= damping
        newVelocity.dy *= damping

        let finished = hypot(newVelocity.dx, newVelocity.dy) < stopSpeed
        return StepResult(position: newPosition, velocity: newVelocity, finished: finished)
    }

    // MARK: - 连续路径碰撞

    /// 单轴扫掠结果。
    private struct Sweep {
        let position: CGFloat
        let bounced: Bool
    }

    /// 单轴扫掠：宠物矩形沿指定轴移动 `distance`，在与可通行带边界首次相交处停下
    /// （该步剩余位移丢弃）。当前不在任何带内（几何突变 / 初始越界）时不移动。
    private static func sweep(
        from: CGFloat,
        distance: CGFloat,
        extent: CGFloat,
        crossSpan: ClosedRange<CGFloat>,
        screens: [PetScreenGeometry],
        horizontal: Bool
    ) -> Sweep {
        guard distance != 0 else { return Sweep(position: from, bounced: false) }
        let target = from + distance
        let bands = passableBands(
            crossSpan: crossSpan, extent: extent, screens: screens, horizontal: horizontal
        )
        for band in bands
        where from >= band.lowerBound - seamTolerance && from <= band.upperBound + seamTolerance {
            let clamped = min(max(target, band.lowerBound), band.upperBound)
            return Sweep(position: clamped, bounced: clamped != target)
        }
        return Sweep(position: from, bounced: false)
    }

    /// 求单轴可通行带（矩形最小坐标可取值的区间集合）：
    /// 完全覆盖横截面的屏参与，沿轴相邻无缝的屏合并成连通带（并集区域），
    /// 最后整体扣除矩形边长。开口不足（带比宠物还窄）的带退化为空区间由边界表达。
    private static func passableBands(
        crossSpan: ClosedRange<CGFloat>,
        extent: CGFloat,
        screens: [PetScreenGeometry],
        horizontal: Bool
    ) -> [ClosedRange<CGFloat>] {
        // 参与屏：矩形横截面区间完全落入该屏的另一轴范围。
        let participants = screens.compactMap { screen -> (min: CGFloat, max: CGFloat)? in
            let frame = screen.visibleFrame
            let crossMin = horizontal ? frame.minY : frame.minX
            let crossMax = horizontal ? frame.maxY : frame.maxX
            guard crossMin <= crossSpan.lowerBound, crossSpan.upperBound <= crossMax else {
                return nil
            }
            return (horizontal ? frame.minX : frame.minY, horizontal ? frame.maxX : frame.maxY)
        }
        .sorted { $0.min < $1.min }
        guard !participants.isEmpty else { return [] }

        // 相邻无缝衔接的合并为连通带（区域并集，开口不足时空隙自然把带断开）。
        var unions: [(min: CGFloat, max: CGFloat)] = []
        for participant in participants {
            if let lastIndex = unions.indices.last,
               participant.min - unions[lastIndex].max <= seamTolerance {
                unions[lastIndex].max = max(unions[lastIndex].max, participant.max)
            } else {
                unions.append(participant)
            }
        }

        // 转成「矩形最小坐标」可取区间：整体扣除边长（带比宠物窄时给退化点区间）。
        return unions.map { union in
            let upper = max(union.min, union.max - extent)
            return union.min...upper
        }
    }
}
