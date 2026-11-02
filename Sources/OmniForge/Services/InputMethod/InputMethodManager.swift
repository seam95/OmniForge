import Carbon
import Foundation

final class InputMethodManager {
    private let tis: TISClient
    private let scheduler: Scheduler
    private let notifications: NotificationCenterClient
    private var inputSourceObserver: AnyObject?

    /// 标记是否正在纠正中，避免响应自己触发的通知
    private var isCorrecting = false

    /// 纠正窗口（秒）：约等于一条重试链的总时长（4 次尝试 × 0.05s）。
    /// 只用于覆盖“切换已下发但尚未生效”的竞态，不再吞掉窗口内的真实用户切换。
    private let correctionWindow: TimeInterval = 0.2

    /// 最近一次纠正重试耗尽后的错误描述；
    /// 纠正成功或当前已恢复与锁定一致时清除，供 UI 暴露锁定失效。
    private(set) var lastCorrectionError: String?

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
        guard tis.currentInputSourceID() != lockedID else {
            // 前置守卫：当前与锁定一致（含自身纠正触发的通知）时不动作，防止回环；
            // 同时清除陈旧错误（例如用户已手动切回锁定输入法）
            lastCorrectionError = nil
            return
        }

        // 防抖：仅挡纠正链进行中的重入，窗口缩短为一条链的长度，
        // 不再按时间吞掉窗口内的真实用户切换
        if isCorrecting {
            return
        }

        // 标记开始纠正；从链启动起覆盖一个链长的窗口后重置，
        // 链提前成功结束时，剩余窗口继续兜住“切换尚未生效”的竞态
        isCorrecting = true
        scheduler.after(correctionWindow) { [weak self] in
            self?.isCorrecting = false
        }

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
                self.finishCorrection(error: nil)
                return
            }

            guard remaining > 0 else {
                // 重试耗尽：暴露失败原因，UI 不再恒显示运行中
                self.finishCorrection(error: "多次尝试后仍无法切回锁定的输入法")
                return
            }

            self.attemptSelect(targetID: targetID, remaining: remaining - 1)
        }
    }

    private func finishCorrection(error: String?) {
        // 成功清除错误，耗尽时置位；isCorrecting 的重置
        // 由纠正链启动时安排的 correctionWindow 定时器负责
        lastCorrectionError = error
    }
}
