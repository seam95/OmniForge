import CoreGraphics

/// SC 整窗吸附的 layer 资格判定。
///
/// 标准窗口(layer 0)以及 Dock / 菜单栏 / 状态栏等系统 UI 可吸附;
/// 屏保等高层窗口排除,避免命中截图遮罩同类层级。
enum SCWindowSnapEligibility {
    static func isEligible(windowLayer: Int) -> Bool {
        if windowLayer == 0 { return true }
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        let menu = Int(CGWindowLevelForKey(.mainMenuWindow))
        let status = Int(CGWindowLevelForKey(.statusWindow))
        return windowLayer == dock || windowLayer == menu || windowLayer == status
    }
}
