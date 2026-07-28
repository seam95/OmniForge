import Foundation
import Combine

/// 基于 DispatchSourceTimer 的重复调度器
final class TimerRepeatingScheduler: RepeatingScheduling {
    private var timers: [UUID: DispatchSourceTimer] = [:]

    func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable {
        let id = UUID()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { action() }
        timer.resume()
        timers[id] = timer
        return AnyCancellable { [weak self] in
            timer.cancel()
            self?.timers.removeValue(forKey: id)
        }
    }
}
