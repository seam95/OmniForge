import AppKit
import Combine
import Foundation

/// 外观管理器：设置页「跟随系统 / 浅色 / 深色」三态切换的单一数据源。
///
/// 注入走窗口层 `window.appearance`，不设 `NSApp.appearance`：
/// 菜单栏指标离屏绘制依赖 `NSColor.labelColor` 按系统外观动态取色，
/// 全局覆盖会让强制亮色时菜单栏文字在深色桌面下不可读；截图遮罩等
/// 业务固定外观窗口也不应被用户偏好波及。`window.appearance` 经
/// `NSHostingController` 自动传导为 SwiftUI `colorScheme` 环境值，
/// 既有消费侧暗色分支全部自动生效。
@MainActor
final class AppearanceSettings: ObservableObject {
    @Published private(set) var mode: AppearanceMode
    private let userDefaults: UserDefaults
    /// 已登记窗口的弱引用表；窗口释放后由应用路径清理，不累积。
    private var windows: [WeakWindowBox] = []

    /// 弱引用包装：AppearanceSettings 常驻，窗口随各自生命周期销毁。
    private final class WeakWindowBox {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.string(forKey: UserDefaultsKeys.appearanceMode),
           let saved = AppearanceMode(rawValue: raw) {
            mode = saved
        } else {
            mode = .system
        }
    }

    /// 登记窗口并立即应用当前外观；重复登记去重。
    func attach(_ window: NSWindow) {
        windows.removeAll { $0.window == nil }
        guard !windows.contains(where: { $0.window === window }) else { return }
        windows.append(WeakWindowBox(window))
        window.appearance = mode.nsAppearance
    }

    /// 设置外观：持久化并批量应用到已登记窗口。
    func setMode(_ newMode: AppearanceMode) {
        mode = newMode
        userDefaults.set(newMode.rawValue, forKey: UserDefaultsKeys.appearanceMode)
        applyToWindows()
    }

    /// 批量应用当前外观到全部存活窗口，并清理已释放的弱引用。
    func applyToWindows() {
        windows.removeAll { $0.window == nil }
        for box in windows {
            box.window?.appearance = mode.nsAppearance
        }
    }
}
