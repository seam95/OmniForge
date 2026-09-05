import AppKit
import Foundation

/// 控制中心 popover 尺寸适配器（SPEC §5：外壳几何唯一写入者）。
///
/// 阶段 0 实验结论（docs/active/2026-09-05-控制中心自适应高度与稳定转场/
/// VALIDATION.md）：
/// - 公开 API 一次赋值（contentSize / preferredContentSize / 自动追踪 +
///   SwiftUI 动画）在可见状态下全部瞬跳，无平台动画可用；
/// - popover 几何写入必须发生在 run loop 事件上下文，Swift Task
///   continuation 中直接写入会触发 WindowManagement 断言崩溃。
///
/// 因此本适配器以 run loop Timer 分步提交目标高度（stair-step），每步
/// 均为公开 API 调用，整体呈现为连续单调改高（非弹簧、无过冲）。
@MainActor
final class ControlCenterPopoverSizer {
    /// 分步节奏：对齐 60Hz 显示帧间隔。
    private static let stepInterval: TimeInterval = 1.0 / 60.0
    /// 完成确认：最后一步提交后 hostingView bounds 到达终值的确认预算。
    private static let settleBudget: TimeInterval = 0.2

    private let popover: NSPopover
    private var stepTimer: Timer?
    private var settleTimer: Timer?
    /// 单调递增提交代次：取消后旧序列回调全部失效（latest-wins）。
    private var generation = 0
    private var pendingCompletion: ((Bool) -> Void)?

    init(popover: NSPopover) {
        self.popover = popover
    }

    /// 当前已提交总高（= popover.contentSize.height）。
    var currentTotalHeight: CGFloat {
        popover.contentSize.height
    }

    /// 是否存在在途分步序列。
    var hasActiveSubmit: Bool {
        stepTimer != nil || settleTimer != nil
    }

    /// 分步提交目标总高。
    ///
    /// - 等高（≤1 物理像素）：单次提交立即完成。
    /// - 不等高：`animationDuration` 内按 60Hz 步进、easeInOut 非弹簧插值；
    ///   每步在 run loop Timer 上下文写入 contentSize 并回调 `onStep`
    ///   （SwiftUI viewport 需同步跟随防 footer 被压缩）。
    /// - 完成：最后一步提交且内容视图 bounds 到达终值后回调
    ///   `completion(true)`（呈现状态确认，SPEC §4.2.4）；取消或确认超预算
    ///   回调 `completion(false)`。
    /// - 新提交隐含取消旧序列（旧 completion 收到 false，不反向追逐，
    ///   SPEC §6.3：每个尺寸段内部连续单调）。
    func submit(
        targetTotalHeight: CGFloat,
        animationDuration: TimeInterval,
        onStep: @escaping (_ totalHeight: CGFloat) -> Void,
        completion: @escaping (_ reached: Bool) -> Void
    ) {
        cancelActiveSubmits(interrupted: true)
        generation += 1
        let gen = generation
        // 登记等待者：步进期间被取消也能收到 false（一次性）。
        pendingCompletion = completion

        let from = popover.contentSize.height
        let to = targetTotalHeight
        guard to.isFinite, to > 0 else {
            pendingCompletion = nil
            completion(false)
            return
        }

        // 等高：一步到位。
        if abs(to - from) <= pixelTolerance {
            commitStep(to, onStep: onStep)
            confirmSettled(gen, target: to, onStep: onStep, completion: completion)
            return
        }

        let duration = max(animationDuration, Self.stepInterval * 2)
        let stepCount = max(2, Int((duration / Self.stepInterval).rounded()))
        var step = 0
        let timer = Timer(timeInterval: Self.stepInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.generation == gen else {
                    timer.invalidate()
                    return
                }
                step += 1
                let progress = CGFloat(step) / CGFloat(stepCount)
                let height = Self.interpolatedHeight(from: from, to: to, progress: progress)
                self.commitStep(height, onStep: onStep)
                if step >= stepCount {
                    timer.invalidate()
                    self.stepTimer = nil
                    self.confirmSettled(gen, target: to, onStep: onStep, completion: completion)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    /// 取消在途序列；`interrupted` 为 true 时向等待者报告未到达。
    func cancelActiveSubmits(interrupted: Bool = true) {
        stepTimer?.invalidate()
        stepTimer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        if interrupted, let pending = pendingCompletion {
            pendingCompletion = nil
            pending(false)
        } else {
            pendingCompletion = nil
        }
    }

    // MARK: - 内部

    private var pixelTolerance: CGFloat {
        // 1 物理像素（backing scale 由窗口所在屏幕决定，取保守 3x 上限仍为亚点级）。
        1.0 / 2.0
    }

    private func commitStep(_ height: CGFloat, onStep: (CGFloat) -> Void) {
        // Timer 回调即 run loop 事件上下文（阶段 0 E2 约束），可直接写入。
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height)
        onStep(height)
    }

    /// 最后一步提交后的呈现确认：内容视图 bounds 到达终值（+预算内静默）
    /// 才算完成；popover 未显示（测试/预装配）时直接确认。
    private func confirmSettled(
        _ gen: Int,
        target: CGFloat,
        onStep: @escaping (CGFloat) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        guard popover.isShown else {
            pendingCompletion = nil
            completion(true)
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.generation == gen else {
                    timer.invalidate()
                    self.settleTimer = nil
                    return
                }
                let boundsHeight = self.popover.contentViewController?.view.bounds.height ?? target
                if abs(boundsHeight - target) <= self.pixelTolerance {
                    timer.invalidate()
                    self.settleTimer = nil
                    if let pending = self.pendingCompletion {
                        self.pendingCompletion = nil
                        pending(true)
                    }
                    return
                }
                if CFAbsoluteTimeGetCurrent() - started > Self.settleBudget {
                    // 预算内未确认就绪：停止发起新尺寸段并如实报告失败
                    //（SPEC §7.2，不强制瞬移）。
                    timer.invalidate()
                    self.settleTimer = nil
                    if let pending = self.pendingCompletion {
                        self.pendingCompletion = nil
                        pending(false)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// easeInOut（非弹簧、无过冲）分步插值。曲线为纯函数以便单测断言单调性。
    static func interpolatedHeight(from: CGFloat, to: CGFloat, progress: CGFloat) -> CGFloat {
        let p = min(max(progress, 0), 1)
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        return from + (to - from) * eased
    }
}
