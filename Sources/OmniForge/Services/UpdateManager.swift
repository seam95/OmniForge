import AppKit
import Sparkle

/// 自动更新管理器（Sparkle 2 接线）。
///
/// 契约：
/// - 非沙盒应用，用 `SPUStandardUpdaterController` 编程式接入标准更新 UI；
///   更新校验仅依赖 EdDSA 签名与代码签名一致性，与是否公证无关。
/// - 首次接触 `shared` 时启动 updater；`start()` 幂等，用于启动完成后再触发周期检查，
///   避免对 LSUIElement 菜单栏应用抢占焦点。
/// - 检查更新入口（菜单）经 `checkForUpdates()` 转发，`canCheckForUpdates` 供菜单项启用校验。
@MainActor
final class UpdateManager: NSObject {

    /// 共享实例。`static let` 首次访问即构造 controller，并在此刻启动 updater。
    static let shared = UpdateManager()

    /// 更新控制器；持有即驱动 Sparkle 生命周期。delegate 均为 nil（非沙盒、标准 UI）。
    private let controller: SPUStandardUpdaterController

    /// updater 快捷访问（测试与内部使用）。
    var updater: SPUUpdater { controller.updater }

    /// 是否可发起检查（供菜单项 `validateMenuItem` 使用）。
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    private override init() {
        // startingUpdater: true —— 构造即启动 updater。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        let updater = controller.updater
        // 后台周期检查（24 小时一次）；发现新版本时按 Sparkle 标准 UI 提示。
        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = 86400
        // 下载到本地后弹窗询问是否安装；不做完全静默安装，避免未公证场景下跳过用户确认。
        updater.automaticallyDownloadsUpdates = true
    }

    /// 启动 updater（幂等）。`shared` 已启动，此处用于在 `applicationDidFinishLaunching`
    /// 之后再确认一次调度，保证周期检查不早于应用就绪。
    func start() {
        // 幂等：重复 startUpdater 对已启动的 updater 无副作用。
        _ = try? updater.start()
    }

    /// 菜单「检查更新…」入口。`canCheckForUpdates` 为 false 时直接返回（无会话/启动失败）。
    func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}
