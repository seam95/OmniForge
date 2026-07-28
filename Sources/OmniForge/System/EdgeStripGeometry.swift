import CoreGraphics

/// 系统边缘条带（菜单栏 / Dock）的几何纯函数。
///
/// 统一坐标约定：**CG 全局坐标系（左上原点，Y 向下）**，与 `kCGWindowBounds`、
/// `SCWindow.frame`、`DockClickSupport` 一致。NSScreen 的 AppKit 坐标（左下原点）
/// 需调用方先用 `DisplayCoordinate.cgGlobalRectToAppKitGlobal` 的反向翻转转换为
/// CG 全局坐标后再传入。
///
/// 条带高度一律由 `screenFrame - visibleFrame` 差值推算，**不硬编码 24pt**：
/// notch / 缩放 / 外接屏 / 自动隐藏都会改变条带尺寸。
enum EdgeStrip: Equatable, Sendable {
    /// 屏幕顶部菜单栏条带（`screenFrame.maxY` 与 `visibleFrame.maxY` 之间）。
    case menuBar
    /// 屏幕底部 Dock 条带（`screenFrame.minY` 与 `visibleFrame.minY` 之间）。
    case dockBottom
    /// 屏幕左侧 Dock 条带。
    case dockLeft
    /// 屏幕右侧 Dock 条带。
    case dockRight
}

/// 边缘条带几何计算（CG 左上原点坐标）。
///
/// 从 `Services/Mouse/DockClickSupport.dockStripContains` 提炼为共享纯函数，
/// 供 Mouse 服务 Dock 点击与截图吸附共同复用（DRY）。
enum EdgeStripGeometry {
    /// 判定点与保留条带的最小内缩阈值（pt）。
    /// 低于此差值视为该方向无系统保留条带（自动隐藏 / Dock 在其他屏）。
    static let reservedThreshold: CGFloat = 8

    /// 判断 CG 全局点落在哪个系统边缘条带内；不在任何条带返回 nil。
    ///
    /// - Parameters:
    ///   - cgPoint: CG 全局坐标点（左上原点）。
    ///   - screenFrame: 目标屏 CG 全局 frame。
    ///   - visibleFrame: 目标屏 CG 全局 visibleFrame（已扣除菜单栏/Dock）。
    /// - Returns: 命中的条带；点在屏外或屏中央非边缘区返回 nil。
    static func strip(
        at cgPoint: CGPoint,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> EdgeStrip? {
        // 轻微外扩：指针钳制在屏内时，事件坐标可能落在小数级屏外。
        guard screenFrame.insetBy(dx: -8, dy: -8).contains(cgPoint) else { return nil }

        // CG 坐标下，菜单栏在顶部（大 Y），Dock 在底部（小 Y）。
        // screenFrame 与 visibleFrame 的差值即各方向系统保留区高度。
        let topGap = screenFrame.maxY - visibleFrame.maxY      // 菜单栏（顶部）
        let bottomGap = visibleFrame.minY - screenFrame.minY   // Dock（底部）
        let leftGap = visibleFrame.minX - screenFrame.minX     // Dock（左侧）
        let rightGap = screenFrame.maxX - visibleFrame.maxX    // Dock（右侧）
        let reserved = reservedThreshold

        // 顶部菜单栏条带：优先判定（菜单栏在带主屏的显示器上一定存在）。
        if topGap > reserved, cgPoint.y >= visibleFrame.maxY {
            return .menuBar
        }
        if bottomGap > reserved, cgPoint.y <= visibleFrame.minY {
            return .dockBottom
        }
        if leftGap > reserved, cgPoint.x <= visibleFrame.minX {
            return .dockLeft
        }
        if rightGap > reserved, cgPoint.x >= visibleFrame.maxX {
            return .dockRight
        }
        return nil
    }

    /// 返回条带在 CG 全局坐标下的矩形。
    ///
    /// - Parameters:
    ///   - strip: 条带类型。
    ///   - screenFrame: 目标屏 CG 全局 frame。
    ///   - visibleFrame: 目标屏 CG 全局 visibleFrame。
    /// - Returns: 条带完整矩形（CG 全局）；若该方向无保留区（差值 ≤ 阈值）返回 nil。
    static func cgRect(
        of strip: EdgeStrip,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect? {
        let reserved = reservedThreshold
        switch strip {
        case .menuBar:
            let height = screenFrame.maxY - visibleFrame.maxY
            guard height > reserved else { return nil }
            return CGRect(x: screenFrame.minX, y: visibleFrame.maxY,
                          width: screenFrame.width, height: height)
        case .dockBottom:
            let height = visibleFrame.minY - screenFrame.minY
            guard height > reserved else { return nil }
            return CGRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: screenFrame.width, height: height)
        case .dockLeft:
            let width = visibleFrame.minX - screenFrame.minX
            guard width > reserved else { return nil }
            return CGRect(x: screenFrame.minX, y: screenFrame.minY,
                          width: width, height: screenFrame.height)
        case .dockRight:
            let width = screenFrame.maxX - visibleFrame.maxX
            guard width > reserved else { return nil }
            return CGRect(x: visibleFrame.maxX, y: screenFrame.minY,
                          width: width, height: screenFrame.height)
        }
    }
}
