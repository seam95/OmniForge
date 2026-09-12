import CoreGraphics
import Foundation

/// 拖动方向与速度采样：消费统一指针采样流的全局屏幕位置，输出手势朝向与松手速度。
/// 纯值类型，时间由调用方传入（Manager 显示时钟域，单调推进），便于单测确定性。
///
/// 原生窗口拖动会话（`performDrag`）期间 `mouseDragged` 不再分发，
/// 方向与速度都从 30Hz 指针采样流推导——拖动中指针位移即窗口位移（会话锚点固定）。
struct PetDragMotionTracker {
    /// 朝向更新阈值（pt）：距本方向候选起点达到该值才更新朝向。
    static let facingThreshold: CGFloat = 4
    /// 速度样本窗口（秒）：只用相对松手时刻最近这么久的样本。
    static let velocityWindow: TimeInterval = 0.08
    /// 松手速度放大系数（采样速度 → 投掷初速）。
    static let velocityMultiplier: CGFloat = 3

    /// 当前朝向（初始右；首个样本前不输出变化）。
    private(set) var facing: PetDirection = .right
    /// 当前候选方向符号（+1 右 / -1 左；0 = 尚无候选）。
    private var candidateSign: CGFloat = 0
    /// 候选方向的累计位移（绝对值）。
    private var candidateDistance: CGFloat = 0
    /// 上一次采样的指针位置（nil = 尚未建立）。
    private var lastPointer: CGPoint?
    /// 指针样本缓冲（时间 + 全局位置），只保留速度窗口内的最新样本。
    private var samples: [(time: TimeInterval, location: CGPoint)] = []

    /// 是否已有足够方向基线（首个样本建立后为 true）。
    var hasBaseline: Bool { lastPointer != nil }

    /// 供给一次指针采样；返回朝向是否在本次更新中改变。
    /// - Parameters:
    ///   - pointer: 全局屏幕坐标指针位置。
    ///   - time: 单调时间（秒；Manager 显示时钟域）。
    mutating func update(pointer: CGPoint, at time: TimeInterval) -> Bool {
        // 速度样本：无条件记录（过期样本在求速度时过滤，静止拖住的旧样本自然失效）。
        samples.append((time, pointer))
        trimSamples(now: time)

        guard let last = lastPointer else {
            lastPointer = pointer
            return false
        }
        defer { lastPointer = pointer }

        let dx = pointer.x - last.x
        guard dx != 0 else { return false }
        let sign: CGFloat = dx > 0 ? 1 : -1
        if sign == candidateSign {
            // 同向继续累计。
            candidateDistance += abs(dx)
        } else {
            // 反向增量：开始新候选累计（微小回摆不立即反向）。
            candidateSign = sign
            candidateDistance = abs(dx)
        }
        let facingSign: CGFloat = facing == .right ? 1 : -1
        if candidateDistance >= Self.facingThreshold, candidateSign != facingSign {
            facing = candidateSign > 0 ? .right : .left
            return true
        }
        return false
    }

    /// 松手时求投掷初速：补录最终样本后，取窗口内首末位移 / 时间差 × 系数。
    /// 样本不足两条不同时间、时间差为零或出现非有限值时一律返回零速
    /// （按住静止超过窗口再松手即零速——过期样本已被裁剪，不会被沿用）。
    mutating func velocity(at time: TimeInterval, location: CGPoint) -> CGVector {
        samples.append((time, location))
        trimSamples(now: time)
        guard samples.count >= 2 else { return .zero }
        // trimSamples 后按时间取首末（缓冲本就按时间有序）。
        let first = samples.first!
        let last = samples.last!
        let dt = last.time - first.time
        guard dt > 0 else { return .zero }
        let vx = (last.location.x - first.location.x) / dt * Self.velocityMultiplier
        let vy = (last.location.y - first.location.y) / dt * Self.velocityMultiplier
        guard vx.isFinite, vy.isFinite else { return .zero }
        return CGVector(dx: vx, dy: vy)
    }

    /// 清空全部状态（拖动开始时重建基线）。
    mutating func reset() {
        candidateSign = 0
        candidateDistance = 0
        lastPointer = nil
        samples.removeAll()
    }

    /// 裁剪速度窗口外的过期样本。
    private mutating func trimSamples(now: TimeInterval) {
        let cutoff = now - Self.velocityWindow
        if let firstIndex = samples.firstIndex(where: { $0.time >= cutoff }) {
            if firstIndex > 0 {
                samples.removeFirst(firstIndex)
            }
        } else {
            samples.removeAll()
        }
    }
}
