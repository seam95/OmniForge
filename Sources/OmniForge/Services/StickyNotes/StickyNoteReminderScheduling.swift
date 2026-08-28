import Foundation
import UserNotifications

/// 提醒双通道调度（SPEC D10）：内部定时器驱动窗口唤起 + 系统通知投递横幅。
/// 协议化以便测试注入；通知 request id 统一为 `stickyNote.<uuid>`。
@MainActor
protocol StickyNoteReminderScheduling: AnyObject {
    /// 挂内部唤起定时器；到点在主线程回调。重复挂载同 id 自动替换旧定时器。
    func scheduleTimer(id: UUID, at date: Date, fire: @escaping () -> Void)
    func cancelTimer(id: UUID)
    /// 排系统日历通知；权限被拒 / 非 .app 宿主时静默跳过（提醒设置本身不受影响）。
    func scheduleNotification(id: UUID, title: String, body: String, at date: Date)
    func cancelNotification(id: UUID)
    /// 撤销本功能全部 pending 通知请求（teardown / 退出，验收「无残留通知请求」）。
    func cancelAllNotifications()
    /// 首次设置提醒时懒申请通知权限；重复调用无副作用。
    func requestAuthorizationIfNeeded()
}

/// 通知 request id 约定。
enum StickyNoteReminderRequestID {
    static func make(for id: UUID) -> String {
        "stickyNote.\(id.uuidString)"
    }
}

@MainActor
final class SystemStickyNoteReminderScheduler: StickyNoteReminderScheduling {
    private var timers: [UUID: Timer] = [:]
    private var hasRequestedAuthorization = false

    deinit {
        for timer in timers.values {
            timer.invalidate()
        }
    }

    func scheduleTimer(id: UUID, at date: Date, fire: @escaping () -> Void) {
        cancelTimer(id: id)
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            // 已到期的提醒由调用方走恢复扫描路径，这里不补触发。
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timers[id] = nil
                fire()
            }
        }
        timers[id] = timer
    }

    func cancelTimer(id: UUID) {
        timers[id]?.invalidate()
        timers[id] = nil
    }

    func scheduleNotification(id: UUID, title: String, body: String, at date: Date) {
        // 非 .app 宿主（单测 / CLI）调用通知中心会崩溃，与 Permissions 的守卫策略一致。
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: StickyNoteReminderRequestID.make(for: id),
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    func cancelNotification(id: UUID) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [StickyNoteReminderRequestID.make(for: id)])
    }

    func cancelAllNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("stickyNote.") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        Permissions.shared.requestNotifications()
    }
}
