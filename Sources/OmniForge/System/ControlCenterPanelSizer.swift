import AppKit
import Foundation

/// 控制中心面板尺寸适配器（自管窗口版，SPEC §5：外壳几何唯一写入者）。
///
/// 分步提交架构承袭 popover 时代（阶段 0 实验结论，docs/active/
/// 2026-09-05-控制中心自适应高度与稳定转场/VALIDATION.md）：
/// - 公开 API 一次赋值在可见状态下瞬跳，无平台动画可用；
/// - 几何写入发生在 run loop 事件上下文（60Hz Timer 步进）。
///
/// 窗口版差异：写入目标为 `window.setFrame`，且每步**顶边钉死**
/// （origin.y = pinnedTopY - height）——改高时面板顶缘贴锚点不动、
/// 仅下缘伸缩，与 popover 顶部锚定语义一致；borderless 无 chrome
/// 差，frame.height 即内容总高。
@MainActor
final class ControlCenterPanelSizer {
    /// 分步节奏：对齐 60Hz 显示帧间隔。
    private static let stepInterval: TimeInterval = 1.0 / 60.0
    /// 完成确认：最后一步提交后 hostingView bounds 到达终值的确认预算。
    private static let settleBudget: TimeInterval = 0.2

    private let window: NSWindow
    private var stepTimer: Timer?
    private var settleTimer: Timer?
    /// 单调递增提交代次：取消后旧序列回调全部失效（latest-wins）。
    private var generation = 0
    private var pendingCompletion: ((Bool) -> Void)?
    /// 顶边钉死 Y（屏幕坐标）；未设置时保持窗口当前顶缘。
    private var pinnedTopY: CGFloat?

    init(window: NSWindow) {
        self.window = window
    }

    /// 面板每次 show 后设置：分步改高期间顶缘固定贴锚点下沿。
    func pinTopEdge(_ y: CGFloat) {
        pinnedTopY = y
    }

    /// 当前已提交总高（borderless 窗口 frame 高即内容总高）。
    var currentTotalHeight: CGFloat {
        window.frame.height
    }

    /// 是否存在在途分步序列。
    var hasActiveSubmit: Bool {
        stepTimer != nil || settleTimer != nil
    }

    /// 分步提交目标总高。
    ///
    /// - 等高（≤1 物理像素）：单次提交立即完成。
    /// - 不等高：`animationDuration` 内按 60Hz 步进、easeInOut 非弹簧插值；
    ///   每步在 run loop Timer 上下文写入 frame 并回调 `onStep`
    ///   （SwiftUI viewport 需同步跟随防 footer 被压缩）。
    /// - 完成：最后一步提交且内容视图 bounds 到达终值后回调
    ///   `completion(true)`；取消或确认超预算回调 `completion(false)`。
    /// - 新提交隐含取消旧序列（旧 completion 收到 false，不反向追逐）。
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

        let from = window.frame.height
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
        ControlCenterSizingLog.log("sizer.submit from=\(from) to=\(to) steps=\(stepCount) duration=\(duration)")
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
                    ControlCenterSizingLog.log("sizer 步进完成 step=\(step) end=\(self.window.frame.height)")
                    self.confirmSettled(gen, target: to, onStep: onStep, completion: completion)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    /// 取消在途序列；`interrupted` 为 true 时向等待者报告未到达。
    func cancelActiveSubmits(interrupted: Bool = true) {
        if stepTimer != nil || settleTimer != nil {
            ControlCenterSizingLog.log("sizer.cancelActiveSubmits interrupted=\(interrupted)")
        }
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
        // 顶边钉死：每步重算 origin，仅下缘伸缩。
        let frame = window.frame
        let topY = pinnedTopY ?? frame.maxY
        window.setFrame(
            NSRect(x: frame.minX, y: topY - height, width: frame.width, height: height),
            display: true
        )
        onStep(height)
    }

    /// 最后一步提交后的呈现确认：内容视图 bounds 到达终值（+预算内静默）
    /// 才算完成；窗口不可见（测试/预装配）时直接确认。
    private func confirmSettled(
        _ gen: Int,
        target: CGFloat,
        onStep: @escaping (CGFloat) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        guard window.isVisible else {
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
                let boundsHeight = self.window.contentView?.bounds.height ?? target
                if abs(boundsHeight - target) <= self.pixelTolerance {
                    timer.invalidate()
                    self.settleTimer = nil
                    ControlCenterSizingLog.log("sizer 呈现确认 OK bounds=\(boundsHeight)")
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
                    ControlCenterSizingLog.log("sizer 呈现确认超时 bounds=\(boundsHeight) target=\(target)")
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
