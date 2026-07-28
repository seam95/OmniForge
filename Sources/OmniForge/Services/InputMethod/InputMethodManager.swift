import Carbon
import Foundation

final class InputMethodManager {
    private let tis: TISClient
    private let scheduler: Scheduler
    private let notifications: NotificationCenterClient
    private var inputSourceObserver: AnyObject?

    /// 标记是否正在纠正中，避免响应自己触发的通知
    private var isCorrecting = false

    /// 上次纠正的时间戳，用于防抖
    private var lastCorrectionTime: Date?

    /// 防抖间隔（秒）
    private let debounceInterval: TimeInterval = 0.5

    init(
        tis: TISClient,
        scheduler: Scheduler = MainQueueScheduler(),
        notifications: NotificationCenterClient = DistributedNotificationCenterAdapter()
    ) {
        self.tis = tis
        self.scheduler = scheduler
        self.notifications = notifications
    }

    func enumerateInputSources() -> [InputSource] {
        tis.listInputSources()
    }

    func currentInputSourceID() -> String? {
        tis.currentInputSourceID()
    }

    func getCurrentInputSource() -> InputSource? {
        guard let id = tis.currentInputSourceID() else { return nil }
        return tis.listInputSources().first(where: { $0.id == id })
    }

    @discardableResult
    func selectInputSource(_ id: String) -> Bool {
        tis.selectInputSource(id: id)
    }

    var isObservingInputSourceChanges: Bool {
        inputSourceObserver != nil
    }

    func startObservingInputSourceChanges(onChange: @escaping () -> Void) {
        stopObservingInputSourceChanges()
        inputSourceObserver = notifications.addObserver(forName: .tisSelectedKeyboardInputSourceChanged) {
            onChange()
        }
    }

    func stopObservingInputSourceChanges() {
        if let inputSourceObserver {
            notifications.removeObserver(inputSourceObserver)
        }
        inputSourceObserver = nil
    }

    func correctIfNeeded(isLocked: Bool, lockedID: String?) {
        guard isLocked, let lockedID else { return }
        guard tis.currentInputSourceID() != lockedID else { return }

        // 防抖：如果正在纠正中或刚刚纠正过，忽略此次调用
        if isCorrecting {
            return
        }

        if let lastTime = lastCorrectionTime,
           Date().timeIntervalSince(lastTime) < debounceInterval {
            return
        }

        // 标记开始纠正
        isCorrecting = true
        lastCorrectionTime = Date()

        print("[InputMethodManager] 检测到输入法变化，尝试切换回锁定的输入法")

        // 只使用 TIS API 纠正，避免依赖辅助功能权限/键盘事件注入。
        performCorrection(to: lockedID)
    }

    private func performCorrection(to targetID: String) {
        // 少量重试以应对系统切换的短暂竞态。
        attemptSelect(targetID: targetID, remaining: 3)
    }

    private func attemptSelect(targetID: String, remaining: Int) {
        _ = tis.selectInputSource(id: targetID)

        scheduler.after(0.05) { [weak self] in
            guard let self else { return }

            if self.tis.currentInputSourceID() == targetID {
                self.finishCorrection()
                return
            }

            guard remaining > 0 else {
                self.finishCorrection()
                return
            }

            self.attemptSelect(targetID: targetID, remaining: remaining - 1)
        }
    }

    private func finishCorrection() {
        // 延迟重置标志
        scheduler.after(debounceInterval) { [weak self] in
            self?.isCorrecting = false
        }
    }
}
