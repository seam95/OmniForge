import CoreGraphics
import Foundation

enum DockClickAction: Equatable {
    case minimize
    case restore
    case cycleWindows
    case passThrough
}

/// 给定该 App 上一次处理的点击，本次点击应执行的动作。
enum DockClickRepeatDecision: Equatable {
    /// 处于双击间隔内：什么都不做，否则误触的双击会来回切换两次，
    /// 看起来像点击弹跳。
    case swallow
    /// 与上一次动作相反，取自自身记录：动画收尾期间 AX 最小化状态
    /// 是模糊的，据此推导会再次触发同一动作而不是切回。
    case toggle(DockClickAction)
    /// 无近期动作：从 App 实际窗口状态推导。
    case deriveFromState
}

enum DockClickSupport {
    /// Option-Command-M 组合并非 Minimize All 专属。只有标准的菜单
    /// 动作标识符才能证明按下它是安全的。
    static func isVerifiedMinimizeAll(commandCharacter: String?,
                                      modifiers: Int?,
                                      identifier: String?) -> Bool {
        commandCharacter?.uppercased() == "M"
            && modifiers == 2
            && identifier == "miniaturizeAll:"
    }

    /// 间隔小于此值的点击算作同一意图。
    static let repeatClickGap: TimeInterval = 0.25

    /// 一次已处理点击之后，后续点击在多长时间内仍从自身记录切换，
    /// 而不是相信尚未收尾的 AX 状态。
    static let toggleIntentWindow: TimeInterval = 1.5

    /// 按下期间光标可漂移且仍算作点击的距离。超过此值则这次按下是
    /// Dock 图标拖拽：down 会回放给 Dock，不执行任何动作。点击会有
    /// 一两像素抖动，真正的拖拽在前几帧就会越过此值。
    static let dragSlop: CGFloat = 6

    /// 起始于 origin 的按下，在 point 处是否已移动到足以判定为拖拽。
    static func isDragMovement(from origin: CGPoint, to point: CGPoint) -> Bool {
        let dx = point.x - origin.x, dy = point.y - origin.y
        return (dx * dx + dy * dy).squareRoot() > dragSlop
    }

    /// 扫描被 Minimize All 快捷键遗留的窗口（缺少标准绑定的 App）前的
    /// 延迟。长到足以让批量动画结束，使扫描看到收尾状态。
    static let minimizeSweepDelay: TimeInterval = 0.9

    /// 在最小化仍在进行时切入的恢复，重新断言这些窗口前的延迟。
    static let restoreSweepDelay: TimeInterval = 0.6

    static func repeatDecision(lastAction: DockClickAction?,
                               elapsed: TimeInterval?) -> DockClickRepeatDecision {
        guard let lastAction, let elapsed, elapsed < toggleIntentWindow else { return .deriveFromState }
        if elapsed < repeatClickGap { return .swallow }
        switch lastAction {
        case .minimize: return .toggle(.restore)
        case .restore: return .toggle(.minimize)
        case .cycleWindows: return .deriveFromState
        case .passThrough: return .deriveFromState
        }
    }

    /// 任务栏式 Dock 点击。被点击的 App 在前台且有窗口在屏幕上时最小化；
    /// 当其所有窗口都已最小化时恢复（Dock 原生点击只会激活而不会取消
    /// 最小化——Finder 甚至会打开一个全新窗口）。修饰键点击始终保留
    /// Dock 原生行为（⌘ 在 Finder 中定位，⌥ 隐藏上一个 App，⌃ 打开菜单）。
    /// 全屏窗口无法最小化，从全屏 Space 内恢复兄弟窗口会把用户拽到
    /// 另一个 Space，因此只要有任何全屏窗口就放手。
    /// 该点击是否应将此 App 视为有窗口可最小化。
    /// 辅助功能服务繁忙或无响应的 App（如 DBeaver 等 Java/Eclipse
    /// 应用）的 AX 窗口列表会返回空，而窗口服务器却清楚地显示其窗口
    /// 在屏幕上。在这个盲区里最小化路径仍须介入——它走 App 自身的
    /// Minimize All 菜单项，完全不需要逐窗口的 AX。
    static func effectiveHasUnminimized(unminimizedCount: Int,
                                        minimizedCount: Int,
                                        windowServerSeesWindows: Bool) -> Bool {
        unminimizedCount > 0 || (minimizedCount == 0 && windowServerSeesWindows)
    }

    static func action(appIsFrontmost: Bool,
                       hasUnminimizedWindows: Bool,
                       hasMinimizedWindows: Bool,
                       hasFullscreenWindows: Bool,
                       hasModifiers: Bool,
                       minimizeEnabled: Bool = true,
                       cycleWindowsEnabled: Bool = false,
                       unminimizedWindowCount: Int = 0) -> DockClickAction {
        guard !hasModifiers, !hasFullscreenWindows else { return .passThrough }
        if cycleWindowsEnabled, appIsFrontmost, unminimizedWindowCount > 1 { return .cycleWindows }
        if minimizeEnabled, appIsFrontmost, hasUnminimizedWindows { return .minimize }
        if minimizeEnabled, !hasUnminimizedWindows, hasMinimizedWindows { return .restore }
        return .passThrough
    }

    /// 廉价的几何门控，在任何辅助功能命中测试之前运行，使用事件的
    /// 左上原点坐标。当 Dock 保留了屏幕空间（visibleFrame 在底部、
    /// 左侧或右侧内缩）时，点击必须落在该保留条带内——这将悬停在
    /// Dock 正上方的窗口或面板的点击排除在外，因为随后的 AX 项匹配
    /// 只能信任 Dock 的长轴。无保留条带（自动隐藏，或 Dock 在另一台
    /// 显示器）时回退到一个宽裕的边缘带。
    ///
    /// 截图吸附侧的精确条带几何已提炼到 `EdgeStripGeometry`（含顶部菜单栏、
    /// 无 fallback）。本方法保留 Dock 点击专用的 fallback 宽裕判定语义，
    /// 两者策略不同，不强行合并。
    static func dockStripContains(_ point: CGPoint,
                                  screenFrame: CGRect,
                                  visibleFrame: CGRect,
                                  fallbackMargin: CGFloat = 120) -> Bool {
        // 轻微负内缩：指针会钳制在屏幕内，但边缘上的事件坐标可能
        // 落在小数级的屏幕之外。
        guard screenFrame.insetBy(dx: -8, dy: -8).contains(point) else { return false }

        let bottomGap = screenFrame.maxY - visibleFrame.maxY
        let leftGap = visibleFrame.minX - screenFrame.minX
        let rightGap = screenFrame.maxX - visibleFrame.maxX
        let reserved: CGFloat = 8

        if bottomGap > reserved || leftGap > reserved || rightGap > reserved {
            if bottomGap > reserved, point.y >= visibleFrame.maxY - 2 { return true }
            if leftGap > reserved, point.x <= visibleFrame.minX + 2 { return true }
            if rightGap > reserved, point.x >= visibleFrame.maxX - 2 { return true }
            return false
        }

        return point.y >= screenFrame.maxY - fallbackMargin
            || point.x <= screenFrame.minX + fallbackMargin
            || point.x >= screenFrame.maxX - fallbackMargin
    }
}
