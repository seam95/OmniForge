import AppKit
import Foundation

/// 系统收回输入的事件观察抽象：锁屏、屏幕睡眠、系统睡眠、会话切走。
/// 只在清洁会话存续期间订阅，命中即退出清洁，保证失败方向是「放开输入」而不是「锁住输入」。
@MainActor
protocol CleaningSystemEventObserving: AnyObject {
    /// 开始观察；任一系统中断发生时在主线程回调。重复调用应先清掉旧监听。
    func start(onInterrupt: @escaping @MainActor () -> Void)
    /// 停止观察并移除全部监听。
    func stop()
}

/// 生产实现：锁屏与屏幕睡眠走分布式通知，系统睡眠与会话切走走 NSWorkspace。
///
/// 锁屏通知 `com.apple.screenIsLocked` 未见于 Apple 文档，但 loginwindow 稳定发布；
/// 即使它丢失，拦截器在 tap 被系统收回时也会上报中断（见 `CGCleaningInputInterceptor`）。
@MainActor
final class CleaningSystemEventObserver: CleaningSystemEventObserving {
    /// 锁屏：覆盖电源键锁屏、⌃⌘Q、屏保要求密码、睡眠后锁屏等路径。
    private static let lockNotification = Notification.Name("com.apple.screenIsLocked")

    private var distributedTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    func start(onInterrupt: @escaping @MainActor () -> Void) {
        stop()

        let distributed = DistributedNotificationCenter.default()
        distributedTokens.append(
            distributed.addObserver(forName: Self.lockNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in onInterrupt() }
            }
        )

        // 睡眠侧兜底：合盖与空闲睡眠都会先灭屏；会话切走（快速用户切换/注销）同样应放开输入。
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in workspaceNames {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onInterrupt() }
            }
            workspaceTokens.append(token)
        }
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        for token in distributedTokens {
            distributed.removeObserver(token)
        }
        distributedTokens.removeAll()

        let workspace = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            workspace.removeObserver(token)
        }
        workspaceTokens.removeAll()
    }
}
