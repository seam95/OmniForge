import Foundation

protocol Scheduler {
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void)
}

final class MainQueueScheduler: Scheduler {
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

final class ImmediateScheduler: Scheduler {
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        block()
    }
}
