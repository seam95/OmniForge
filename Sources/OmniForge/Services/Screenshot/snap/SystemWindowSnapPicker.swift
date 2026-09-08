import CoreGraphics

/// 系统 UI 窗口（菜单栏 / 状态项）直选纯函数。
///
/// 这些窗口的 owner 是系统进程（菜单栏=WindowServer、状态项=各 app），
/// AX hit-test 永久失败（`-25204`/`-25211`）。但它们的 CGWindowList bounds 本身
/// 就是合法的吸附候选，无需 AX。
///
/// Dock（layer 20）不在本选择器范围——Dock 窗口的 bounds 是整个屏幕，
/// 直接用作候选会误伤，其吸附由 AX/SC 路径另行处理。
enum SystemWindowSnapPicker {
    /// 菜单栏 layer（`CGWindowLevelForKey(.mainMenuWindow)` = 24）。
    private static let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    /// 状态项 layer（`CGWindowLevelForKey(.statusWindow)` = 25）。
    private static let statusItemLayer = Int(CGWindowLevelForKey(.statusWindow))

    /// 从窗口列表里挑出含点的系统 UI 窗口（菜单栏 / 状态项）。
    ///
    /// - 优先 layer 25（状态项）中**面积最小**的含点窗口：鼠标在状态项图标上时
    ///   细化到单个图标，而非整条菜单栏。
    /// - 无状态项命中时，用 layer 24（整条菜单栏）。
    /// - layer 20（Dock）不在范围。
    /// - Parameters:
    ///   - cgPoint: CG 全局坐标点（左上原点）。
    ///   - windows: 已排除遮罩面板（窗口 ID 粒度）的窗口列表；
    ///     含本 app 的状态项窗口，悬停自家图标会细化到图标本身。
    /// - Returns: 命中的系统窗口；无则 nil（交回 AX/元素级路径）。
    static func pick(at cgPoint: CGPoint, in windows: [SnapWindowInfo]) -> SnapWindowInfo? {
        // 状态项优先：取面积最小的含点窗口（细化到单图标）。
        let statusItems = windows.filter {
            $0.layer == statusItemLayer && $0.bounds.contains(cgPoint)
        }
        if let smallest = statusItems.min(by: { area($0) < area($1) }) {
            return smallest
        }

        // 整条菜单栏兜底。
        if let menuBar = windows.first(where: {
            $0.layer == menuBarLayer && $0.bounds.contains(cgPoint)
        }) {
            return menuBar
        }
        return nil
    }

    private static func area(_ window: SnapWindowInfo) -> CGFloat {
        window.bounds.width * window.bounds.height
    }
}
