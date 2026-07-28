import Combine
import Foundation

/// 可注入时钟；业务状态机不得直接使用 Date()。
protocol KeepAwakeClock: AnyObject {
    var now: Date { get }
}

/// 生产时钟。
final class SystemKeepAwakeClock: KeepAwakeClock {
    var now: Date { Date() }
}

/// 保持唤醒调度边界：一次性截止与带容差的重复任务。
protocol KeepAwakeScheduling: AnyObject {
    @discardableResult
    func scheduleOnce(
        at date: Date,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable

    @discardableResult
    func scheduleRepeating(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable
}

/// 基于 DispatchSourceTimer 的生产调度器。
final class KeepAwakeScheduler: KeepAwakeScheduling {
    private let clock: KeepAwakeClock
    private let queue: DispatchQueue
    private var timers: [UUID: DispatchSourceTimer] = [:]
    private let lock = NSLock()

    init(clock: KeepAwakeClock = SystemKeepAwakeClock(), queue: DispatchQueue = .main) {
        self.clock = clock
        self.queue = queue
        KeepAwakeDiagnostics.info(
            "scheduler.init queue=\(queue.label.isEmpty ? "(main-or-unnamed)" : queue.label) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
    }

    func scheduleOnce(
        at date: Date,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let now = clock.now
        let delay = max(0, date.timeIntervalSince(now))
        let idPreview = UUID()
        KeepAwakeDiagnostics.info(
            "scheduler.scheduleOnce id=\(idPreview.uuidString.prefix(8)) wallTarget=\(date.timeIntervalSince1970) delay=\(String(format: "%.3f", delay))s note=DispatchTime(uptime-based) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: now))"
        )
        return makeTimer(
            id: idPreview,
            kind: "once",
            deadline: .now() + delay,
            repeating: .never,
            leeway: .milliseconds(50)
        ) {
            KeepAwakeDiagnostics.info(
                "scheduler.fire once id=\(idPreview.uuidString.prefix(8)) wallTarget=\(date.timeIntervalSince1970) \(KeepAwakeDiagnostics.timeSnapshot())"
            )
            action()
        }
    }

    func scheduleRepeating(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let leewayMs = max(0, Int(tolerance * 1000))
        let intervalNs = max(0, Int(interval * 1_000_000_000))
        let idPreview = UUID()
        KeepAwakeDiagnostics.info(
            "scheduler.scheduleRepeating id=\(idPreview.uuidString.prefix(8)) interval=\(interval)s tolerance=\(tolerance)s \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
        return makeTimer(
            id: idPreview,
            kind: "repeating",
            deadline: .now() + interval,
            repeating: .nanoseconds(intervalNs),
            leeway: .milliseconds(leewayMs)
        ) {
            action()
        }
    }

    private func makeTimer(
        id: UUID,
        kind: String,
        deadline: DispatchTime,
        repeating: DispatchTimeInterval,
        leeway: DispatchTimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline, repeating: repeating, leeway: leeway)
        timer.setEventHandler {
            Task { @MainActor in
                action()
            }
        }
        lock.lock()
        timers[id] = timer
        lock.unlock()
        timer.resume()
        KeepAwakeDiagnostics.info(
            "scheduler.timerArmed id=\(id.uuidString.prefix(8)) kind=\(kind) activeTimers=\(timersCount())"
        )
        return AnyCancellable { [weak self] in
            KeepAwakeDiagnostics.info(
                "scheduler.cancel id=\(id.uuidString.prefix(8)) kind=\(kind) \(KeepAwakeDiagnostics.timeSnapshot())"
            )
            timer.cancel()
            self?.lock.lock()
            self?.timers.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }

    private func timersCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return timers.count
    }
}
