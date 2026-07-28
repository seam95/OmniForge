import AppKit
import Combine

/// 按用户选择的计划运行安全部分的清理：每日或每周在选定时刻。仅清理手动扫描会默认勾选的内容
/// （安全组），一切仍进废纸篓，可选通知报告结果。计划关闭时什么都不存在：无定时器、无观察者、无开销。
final class CleanerScheduler: ObservableObject {
    static let shared = CleanerScheduler()

    /// 下次自动清理触发时刻；界面显示此行，让启用计划当场给出可见确认。
    @Published private(set) var nextFire: Date?

    /// 通知客户端；默认为生产实现，测试可注入假实现。
    var notificationClient: MonitorNotificationClient = UserNotificationMonitorClient()

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var clockObservers: [NSObjectProtocol] = []
    private var runObserver: AnyCancellable?

    private init() {}

    func syncWithPreferences() {
        let frequency = CleanerSchedule.Frequency.sanitized(
            UserDefaults.standard.string(forKey: UserDefaultsKeys.cleanerScheduleFrequency) ?? "off")
        let cleanerAvailable = MainActor.assumeIsolated {
            FeatureRuntime.shared.isAvailable(.cleaner)
        }
        guard cleanerAvailable, frequency != .off else {
            stop()
            return
        }
        installWakeObserver()
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers = []
        runObserver = nil
        if nextFire != nil { nextFire = nil }
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                // 睡眠期间错过的触发时刻不会触发其定时器；重新计算可在几分钟内捕获错过。
                self?.scheduleNext()
            }
        // 选定时刻意味着用户的挂钟：时区或系统时钟变化时，已武装的触发时刻过期，计划按新的本地时间重算。
        clockObservers = [NSNotification.Name.NSSystemTimeZoneDidChange,
                          NSNotification.Name.NSSystemClockDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil,
                                                   queue: .main) { [weak self] _ in
                self?.scheduleNext()
            }
        }
    }

    private var settings: (frequency: CleanerSchedule.Frequency, hour: Int, minute: Int, weekday: Int) {
        let defaults = UserDefaults.standard
        return (CleanerSchedule.Frequency.sanitized(
                    defaults.string(forKey: UserDefaultsKeys.cleanerScheduleFrequency) ?? "off"),
                defaults.integer(forKey: UserDefaultsKeys.cleanerScheduleHour),
                defaults.integer(forKey: UserDefaultsKeys.cleanerScheduleMinute),
                defaults.integer(forKey: UserDefaultsKeys.cleanerScheduleWeekday))
    }

    private func scheduleNext() {
        let current = settings
        guard current.frequency != .off else { return }

        let defaults = UserDefaults.standard
        let lastRunStamp = defaults.double(forKey: UserDefaultsKeys.cleanerLastAutoRun)
        let lastRun = lastRunStamp > 0 ? Date(timeIntervalSince1970: lastRunStamp) : nil

        let fireDate: Date
        if CleanerSchedule.missedRun(now: Date(), lastRun: lastRun,
                                     frequency: current.frequency,
                                     hour: current.hour, minute: current.minute,
                                     weekday: current.weekday) {
            // 关机期间错过：稍后运行，而非 app 起来的瞬间，保持启动利落。
            fireDate = Date().addingTimeInterval(120)
        } else if let next = CleanerSchedule.nextFireDate(after: Date(),
                                                          frequency: current.frequency,
                                                          hour: current.hour, minute: current.minute,
                                                          weekday: current.weekday) {
            fireDate = next
        } else {
            return
        }
        schedule(at: fireDate)
    }

    private func schedule(at fireDate: Date) {
        timer?.invalidate()
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            self?.runAutomaticCleanup()
        }
        // 紧容差：每天一次的触发毫无开销，且晚一分钟触发的计划对任何测试者都读起来像坏的。
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if nextFire != fireDate { nextFire = fireDate }
    }

    /// 一次自动清理：扫描、清理扫描预选的内容（安全组）、记录结果、让工具回到 idle。
    private func runAutomaticCleanup() {
        let cleaner = JunkCleaner.shared
        guard cleaner.phase == .idle, runObserver == nil else {
            // 用户正处于手动会话中：他们的审查优先。改为十分钟后重试而非丢失这一天。
            schedule(at: Date().addingTimeInterval(600))
            return
        }

        // dropFirst：published 属性会向每个新订阅者重放其当前值（.idle），
        // 那个回声不得在清理开始前被读作"用户中断了本次清理"。
        runObserver = cleaner.$phase
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .results:
                    // 扫描预选的恰好是安全组；自动运行原样采用该选择。
                    if cleaner.selectedCount > 0 {
                        cleaner.cleanSelected()
                    } else {
                        self.finishRun(freed: 0)
                    }
                case let .done(freed, _):
                    self.finishRun(freed: freed)
                case .idle:
                    // 用户（或 reset）中断了自动清理。
                    self.runObserver = nil
                    self.scheduleNext()
                default:
                    break
                }
            }
        cleaner.scan()
    }

    private func finishRun(freed: Int64) {
        runObserver = nil
        JunkCleaner.shared.reset()
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.cleanerLastAutoRun)
        defaults.set(freed, forKey: UserDefaultsKeys.cleanerLastAutoFreed)
        notifyIfWanted(freed: freed)
        scheduleNext()
    }

    /// 用户要求被告知时通过 app 常规通知客户端报告结果（macOS 通知不被允许时静默丢弃）。
    /// 即便什么都没找到的运行也发送，让新计划在首次清理时给出生命迹象。
    private func notifyIfWanted(freed: Int64) {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.cleanerScheduleNotify) else { return }
        let strings = L10n(userDefaults: .standard).s
        let body: String
        if freed > 0 {
            body = String(format: strings.cleanerAutoNotificationFormat,
                          ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))
        } else {
            body = strings.cleanerNothingFound
        }
        notificationClient.post(title: strings.cleanerScheduleTitle, body: body) { _ in }
    }
}
