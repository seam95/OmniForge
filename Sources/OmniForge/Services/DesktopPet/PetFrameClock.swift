import AppKit
import QuartzCore

/// 帧时钟抽象：把「何时推进一帧」从行为循环中解耦，便于测试注入确定性时钟。
@MainActor
protocol PetFrameClock: AnyObject {
    /// 每帧回调；参数为该帧与上一帧的真实间隔（秒）。
    var onTick: ((TimeInterval) -> Void)? { get set }

    /// 在指定视图上启动时钟。视图离屏 / 隐藏时，底层实现可自行挂起。
    func start(in view: NSView)

    /// 停止时钟，并解除对视图与回调的持有。
    func stop()
}

/// 基于 `CADisplayLink` 的帧时钟（macOS 14+）。
///
/// 相比自建 `Task.sleep` 循环的三点原生优势：
/// 1. **刷新对齐**：回调由帧事件驱动而非定时器，动画切帧不撕裂；
/// 2. **跨屏自动跟随**：经 `NSView.displayLink(target:selector:)` 创建，视图所在显示器变化时自动切换；
/// 3. **离屏自动挂起**：视图隐藏或不在任何显示器上时，系统不再回调（零空转功耗）。
///
/// 注册到 `.common` 模式是关键：拖拽 / 滚动等事件跟踪期间 runloop 会切到 `.eventTracking`，
/// 只注册 `.default` 的时钟会被暂停，`.common` 覆盖两者，保证推进不中断。
final class DisplayLinkFrameClock: PetFrameClock {
    var onTick: ((TimeInterval) -> Void)?

    /// 帧率偏好（30fps）：维持原自建循环的节奏与功耗画像。
    /// 注意：macOS 上 `CADisplayLink.preferredFramesPerSecond` 被标记为不可用，须改用 `preferredFrameRateRange`。
    private static let frameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)

    /// 单帧最大步长（秒）：离屏恢复或系统卡顿后可能出现巨大时间差，夹紧以防位移跳变。
    private static let maxFrameDelta: TimeInterval = 0.1

    private var displayLink: CADisplayLink?
    /// 上一帧时间戳（`CADisplayLink.timestamp`），用于推导真实帧间隔；nil 表示尚无基准。
    private var lastTimestamp: CFTimeInterval?

    func start(in view: NSView) {
        // 先清理旧链接，避免重复注册导致回调叠加。
        stop()

        let link = view.displayLink(target: self, selector: #selector(handleFrame(_:)))
        link.preferredFrameRateRange = Self.frameRateRange
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    func stop() {
        // `CADisplayLink` 会强持有 target，必须显式 invalidate 才能断开。
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    deinit {
        // 兜底：正常路径由 stop() 断开；此处防御遗漏调用造成的持有泄漏。
        // invalidate() 线程安全，可在任意线程执行。
        displayLink?.invalidate()
    }

    /// 帧回调：以真实时间差作为 delta；首帧无基准，只记录时间戳。
    @objc private func handleFrame(_ link: CADisplayLink) {
        let previous = lastTimestamp
        lastTimestamp = link.timestamp
        guard let previous else { return }
        let delta = min(max(link.timestamp - previous, 0), Self.maxFrameDelta)
        onTick?(delta)
    }
}
