import AppKit
@testable import OmniForge

/// 测试用帧时钟：不挂 `CADisplayLink`，由测试显式 `emit(delta:)` 驱动帧推进。
/// 生产用 `DisplayLinkFrameClock` 需要真实屏幕与 runloop，测试中时序不可控，故以此替身替代。
@MainActor
final class ManualFrameClock: PetFrameClock {
    var onTick: ((TimeInterval) -> Void)?

    /// 是否处于运行态（start 后为 true，stop 后为 false）。
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(in view: NSView) {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// 模拟一帧回调；未运行时忽略（对齐真实时钟的挂起语义）。
    func emit(delta: TimeInterval) {
        guard isRunning else { return }
        onTick?(delta)
    }
}
