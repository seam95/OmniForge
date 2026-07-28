import Combine
import CoreGraphics
import Foundation

/// 可选指针微动服务。权限缺失时不弹系统授权；仅显式申请路径触发权限 API。
@MainActor
final class PointerActivityService {
    private let poster: PointerActivityPosting
    private let scheduler: KeepAwakeScheduling
    private let clock: KeepAwakeClock
    private let isAccessibilityTrusted: () -> Bool

    private var generation: UInt64 = 0
    private var repeatingTask: AnyCancellable?
    private var returnTask: AnyCancellable?
    private(set) var lastError: KeepAwakeError?

    /// 程序移动后的期望点；返回前若位置不同则视为用户移动。
    private var expectedPointAfterNudge: CGPoint?
    private var originPoint: CGPoint?

    init(
        poster: PointerActivityPosting,
        scheduler: KeepAwakeScheduling,
        clock: KeepAwakeClock = SystemKeepAwakeClock(),
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.poster = poster
        self.scheduler = scheduler
        self.clock = clock
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    /// 启动或同步微动；权限缺失时零事件并记录错误。
    func start(intervalMinutes: KeepAwakePointerInterval) {
        stop()
        generation &+= 1
        let gen = generation
        lastError = nil

        guard isAccessibilityTrusted() else {
            lastError = .accessibilityPermissionMissing
            return
        }

        let interval = TimeInterval(intervalMinutes.minutes * 60)
        repeatingTask = scheduler.scheduleRepeating(every: interval, tolerance: 1) { [weak self] in
            self?.performNudge(generation: gen)
        }
        // 立即执行一次，便于测试与启动后立刻生效。
        performNudge(generation: gen)
    }

    func stop() {
        generation &+= 1
        repeatingTask?.cancel()
        repeatingTask = nil
        returnTask?.cancel()
        returnTask = nil
        expectedPointAfterNudge = nil
        originPoint = nil
    }

    private func performNudge(generation gen: UInt64) {
        guard gen == generation else { return }
        guard isAccessibilityTrusted() else {
            lastError = .accessibilityPermissionMissing
            stopRepeatingOnly()
            return
        }

        let origin = poster.currentLocation()
        let bounds = poster.displayBounds(containing: origin)
        let target = PointerActivityGeometry.nudgeTarget(from: origin, bounds: bounds)
        guard target != origin else { return }

        do {
            try poster.postMouseMoved(to: target)
            originPoint = origin
            expectedPointAfterNudge = target
            scheduleReturn(generation: gen)
        } catch {
            lastError = .pointerEventFailed
            stopRepeatingOnly()
        }
    }

    private func scheduleReturn(generation gen: UInt64) {
        returnTask?.cancel()
        let fireAt = clock.now.addingTimeInterval(0.08)
        returnTask = scheduler.scheduleOnce(at: fireAt) { [weak self] in
            self?.performReturn(generation: gen)
        }
    }

    private func performReturn(generation gen: UInt64) {
        guard gen == generation else { return }
        guard let expected = expectedPointAfterNudge, let origin = originPoint else { return }
        let current = poster.currentLocation()
        // 用户主动移动：不抢回。
        if hypot(current.x - expected.x, current.y - expected.y) > 0.5 {
            expectedPointAfterNudge = nil
            originPoint = nil
            return
        }
        do {
            try poster.postMouseMoved(to: origin)
        } catch {
            lastError = .pointerEventFailed
            stopRepeatingOnly()
        }
        expectedPointAfterNudge = nil
        originPoint = nil
    }

    private func stopRepeatingOnly() {
        repeatingTask?.cancel()
        repeatingTask = nil
        returnTask?.cancel()
        returnTask = nil
    }
}

#if canImport(ApplicationServices)
import ApplicationServices
#endif
