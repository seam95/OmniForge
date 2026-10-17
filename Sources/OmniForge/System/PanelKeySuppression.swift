import Foundation

/// 剪贴板面板关闭瞬间的「窗口持焦抑制」：短时间内让本 app 内其他可成为 key 的
/// 面板（便签）拒绝承接 key window，使系统键盘焦点归还原前台应用。
///
/// 背景：剪贴板面板（nonactivating）orderOut 后，AppKit 会在本 app 内解析新的
/// key window——桌面上有便签时便由便签承接，系统焦点滞留本 app，随后注入的
/// Cmd+V 落入便签。抑制窗口自愈（默认 0.5s），任何路径遗漏释放都不会永久失效。
@MainActor
enum PanelKeySuppression {
    private static var suppressUntil: Date?

    /// 开启抑制；`interval` 到期自动失效（测试可传短值）。
    static func begin(interval: TimeInterval = 0.5) {
        suppressUntil = Date().addingTimeInterval(interval)
    }

    /// 立即结束抑制（粘贴链路注入完成后调用，尽快恢复便签可聚焦）。
    static func end() {
        suppressUntil = nil
    }

    static var isActive: Bool {
        guard let suppressUntil else { return false }
        return Date() < suppressUntil
    }
}
