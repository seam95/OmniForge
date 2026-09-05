import Combine
import SwiftUI

// MARK: - 测量上报通道（PreferenceKey）

/// 页面内容自然高度报告（SPEC §3.2.1：测量 ScrollView 内的内容，
/// 不测量可视高度；含页面自身 padding）。
struct ControlCenterContentHeightReport: Equatable {
    var height: CGFloat
    var isEmptyState: Bool
}

struct ControlCenterNaturalHeightKey: PreferenceKey {
    static let defaultValue: ControlCenterContentHeightReport? = nil

    static func reduce(value: inout ControlCenterContentHeightReport?, nextValue: () -> ControlCenterContentHeightReport?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct ControlCenterTopChromeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

struct ControlCenterBottomChromeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

enum ControlCenterChromePart {
    case top
    case bottom
}

/// 内容自然高度探针：作为 background 不占布局空间；
/// 报告主体内容的实测高度与空态标记。
struct ControlCenterNaturalHeightReportModifier: ViewModifier {
    let isEmptyState: Bool

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ControlCenterNaturalHeightKey.self,
                    value: ControlCenterContentHeightReport(
                        height: geo.size.height,
                        isEmptyState: isEmptyState
                    )
                )
            }
        )
    }
}

// MARK: - 环境注入

/// 控制中心尺寸上下文环境键：仅控制中心容器注入；其他宿主（剪贴板浮窗、
/// 设置窗）保持 nil，PageSwitchHost 屏障不接线、固定尺寸路径不变。
private struct ControlCenterSizingContextKey: EnvironmentKey {
    static let defaultValue: ControlCenterSizingContext? = nil
}

extension EnvironmentValues {
    var controlCenterSizing: ControlCenterSizingContext? {
        get { self[ControlCenterSizingContextKey.self] }
        set { self[ControlCenterSizingContextKey.self] = newValue }
    }
}

// MARK: - 协调器

/// 控制中心尺寸协调器（SPEC §4/§6/§7）：连接页面测量、转场屏障与
/// popover 尺寸适配器。
///
/// 职责边界：
/// - 页面只经 PreferenceKey 上报自然高度与壳层高度（测量）；
/// - 本协调器决定何时采纳测量（latest-wins、防抖合并、超预算降级）；
/// - `ControlCenterPopoverSizer` 负责唯一的外壳几何提交与完成通知；
/// - SwiftUI viewport 状态（`viewportHeight`）在每次 contentSize 步进时
/// 同步更新，防止改高中 footer 被固定高度内容顶出窗口。
@MainActor
final class ControlCenterSizingContext: ObservableObject {
    struct Configuration {
        /// 壳层改高分步动画时长（非弹簧，SPEC §4.2.1 目标区间中值）。
        var resizeAnimationDuration: TimeInterval = 0.15
        /// Reduce Motion：≤80ms 线性/短淡变（SPEC §4.2.7）。
        var reduceMotionResizeDuration: TimeInterval = 0.08
        /// 稳定期结构变化先合并 100ms（SPEC §7.1）。
        var stableChangeDebounce: TimeInterval = 0.1
        /// 透明挂载阶段测量预算；超时保持当前尺寸继续（SPEC §7.2 降级）。
        var mountMeasurementBudget: TimeInterval = 0.3
        /// 稳定变化防抖上限：持续到来时最长 300ms 必须处理一次（SPEC §7.1）。
        var stableChangeMaxDebounce: TimeInterval = 0.3
    }

    @Published private(set) var viewportHeight: CGFloat = ControlCenterContentMetrics.viewportHeight
    /// 稳定期结构变化的同页内容透明度（四阶段流程的内容淡出/淡入，
    /// SPEC §7.1；转场期透明度由 PageSwitchHost 管理）。
    @Published private(set) var contentOpacity = 1.0
    /// 首显测高模式：容器内容以自然高度布局（无 viewport 撑高），供宿主
    /// 在 show 前完成初始尺寸设置（SPEC §7.2.1）。
    @Published private(set) var isMeasuringInitialSize = false

    let configuration: Configuration
    weak var sizer: ControlCenterPopoverSizer?
    /// 当前锚点方向上的可容纳总高（含 chrome）；nil 用保守默认。
    var availableTotalHeightProvider: (() -> CGFloat)?
    var backingScaleProvider: () -> CGFloat

    private(set) var session = 0
    private var mountGeneration = 0
    private var naturalHeight: (value: CGFloat, isEmpty: Bool)?
    private var shellHeight: CGFloat?
    private var pendingProceed: (() -> Void)?
    private var mountBudgetTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var debounceDeadline: Date?
    private var heightCache: [String: CGFloat] = [:]
    private var displayedPath = ""
    private var reduceMotion = false
    /// 稳定结构变化流程进行中（内容已淡出等待改高）。
    private var isRunningStableResize = false

    init(
        configuration: Configuration = Configuration(),
        backingScaleProvider: @escaping () -> CGFloat = { 2 }
    ) {
        self.configuration = configuration
        self.backingScaleProvider = backingScaleProvider
    }

    // MARK: - 会话

    /// popover 打开：绑定适配器并复位会话状态。
    func beginSession(sizer: ControlCenterPopoverSizer) {
        session += 1
        self.sizer = sizer
        pendingProceed = nil
        mountBudgetTask?.cancel()
        mountBudgetTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        isRunningStableResize = false
        contentOpacity = 1
    }

    /// popover 关闭：立即取消全部动画、准备与回调（SPEC §7.2）。
    /// 重开会话携带新 session，旧回调全部失效。
    func endSession() {
        session += 1
        mountGeneration += 1
        sizer?.cancelActiveSubmits(interrupted: false)
        sizer = nil
        pendingProceed = nil
        mountBudgetTask?.cancel()
        mountBudgetTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        isRunningStableResize = false
        naturalHeight = nil
        shellHeight = nil
        contentOpacity = 1
        isMeasuringInitialSize = false
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
    }

    // MARK: - 首显测高

    /// 进入首显测高模式（show 之前）。
    func beginInitialMeasurement() {
        isMeasuringInitialSize = true
        naturalHeight = nil
    }

    /// 仅退出测高布局模式（viewport 恢复当前状态值），保留测量值，
    /// 供宿主完成第二遍布局（chrome 差分）后再提交初始尺寸。
    func endInitialMeasurementLayout() {
        isMeasuringInitialSize = false
    }

    /// 首显测高完成：以测量结果解析初始尺寸并退出测高模式。
    /// 返回提交给 popover.contentSize 的总高。
    func commitInitialMeasurement() -> CGFloat {
        defer { isMeasuringInitialSize = false }
        guard let natural = naturalHeight,
              let target = resolveTarget(natural: natural) else {
            // 无可靠尺寸：安全上限打开（SPEC §7.2.3）。
            let fallback = ControlCenterContentMetrics.viewportHeight
            viewportHeight = fallback
            return fallback + (shellHeight ?? defaultChromeFallback)
        }
        viewportHeight = target.viewportHeight
        return target.totalHeight
    }

    /// 会话内高度缓存（初始布局估计，SPEC §6.7；经实际测量校验后采纳）。
    func cachedNaturalHeight(for path: String) -> CGFloat? {
        heightCache[path]
    }

    private var defaultChromeFallback: CGFloat {
        // 导航 + footer 常规几何（仅测量缺失时的兜底估计）。
        110
    }

    // MARK: - 转场屏障

    /// PageSwitchHost 挂载屏障入口：新 route 已透明挂载，等待该内容的
    /// 有效测量后决策（等高直接淡入 / 不等高分步改高后淡入，SPEC §4.1）。
    func mountStarted(path: String, proceed: @escaping () -> Void) {
        guard !isMeasuringInitialSize else {
            proceed()
            return
        }
        displayedPath = path
        mountGeneration += 1
        let gen = mountGeneration
        naturalHeight = nil
        pendingProceed = proceed
        mountBudgetTask?.cancel()
        mountBudgetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.configuration.mountMeasurementBudget ?? 0.3 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, gen == self.mountGeneration else { return }
            // 超预算仍无有效布局：终止自适应尝试，保持当前尺寸继续
            //（SPEC §7.2，不卡死转场）。
            self.finishMount(gen)
        }
    }

    /// 页面内容自然高度上报（ScrollView 内容测量，SPEC §3.2.1）。
    func reportNaturalHeight(_ height: CGFloat, isEmptyState: Bool) {
        guard height.isFinite, height > 0 else { return }
        let previous = naturalHeight?.value
        naturalHeight = (height, isEmptyState)
        if !displayedPath.isEmpty {
            heightCache[displayedPath] = height
        }
        guard !isMeasuringInitialSize else { return }
        if pendingProceed != nil {
            adoptMeasurementForMount()
        } else if previous != height {
            scheduleStableChange()
        }
    }

    /// 壳层（导航 + 恢复 Banner + footer）实测高度上报。
    func reportShellHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        shellHeight = height
    }

    /// 当前目标解析（纯计算出口，测试可注入后直接断言）。
    func resolveTarget(natural: (value: CGFloat, isEmpty: Bool)) -> ControlCenterSizingTarget? {
        let available = availableTotalHeightProvider?() ?? defaultAvailableHeight
        return ControlCenterSizingPolicy.resolve(
            ControlCenterSizingInput(
                width: ControlCenterContentMetrics.panelWidth,
                naturalContentHeight: natural.value,
                chromeHeight: shellHeight ?? defaultChromeFallback,
                availableTotalHeight: available,
                isEmptyState: natural.isEmpty,
                backingScale: backingScaleProvider()
            )
        )
    }

    private var defaultAvailableHeight: CGFloat {
        // 保守默认：1080p 屏幕的可见高度。
        1055
    }

    /// 当前已提交总高（适配器缺位时按 SwiftUI 侧状态估计）。
    var currentTotalHeight: CGFloat {
        sizer?.currentTotalHeight ?? (shellHeight ?? defaultChromeFallback) + viewportHeight
    }

    // MARK: - 稳定期结构变化（SPEC §7.1）

    private func scheduleStableChange() {
        let now = Date()
        if debounceDeadline == nil {
            debounceDeadline = now.addingTimeInterval(configuration.stableChangeMaxDebounce)
        }
        let deadline = debounceDeadline!
        debounceTask?.cancel()
        let delay = min(configuration.stableChangeDebounce, max(0, deadline.timeIntervalSince(now)))
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.debounceDeadline = nil
            self?.runStableChangeIfNeeded()
        }
    }

    private func runStableChangeIfNeeded() {
        guard !isRunningStableResize, pendingProceed == nil,
              let natural = naturalHeight else { return }
        guard let target = resolveTarget(natural: natural) else { return }
        let scale = backingScaleProvider()
        guard !ControlCenterSizingPolicy.isEffectivelyEqual(
            currentTotalHeight, target.totalHeight, scale: scale
        ) else { return } // 测量相等不触发整页淡变（SPEC §7.1.5）

        isRunningStableResize = true
        let exitDuration: TimeInterval = reduceMotion ? 0.06 : 0.06
        withAnimation(.easeOut(duration: exitDuration)) {
            contentOpacity = 0
        }
        let gen = mountGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(exitDuration * 1_000_000_000))
            guard let self else { return }
            guard gen == self.mountGeneration else {
                self.isRunningStableResize = false
                self.contentOpacity = 1
                return
            }
            self.applyTarget(target) { [weak self] _ in
                guard let self else { return }
                self.isRunningStableResize = false
                withAnimation(.easeOut(duration: 0.12)) {
                    self.contentOpacity = 1
                }
            }
        }
    }

    // MARK: - 目标应用

    /// 采纳挂载测量：等高直接完成；不等高分步改高（resizing 阶段）。
    private func adoptMeasurementForMount() {
        guard let natural = naturalHeight else { return }
        guard let target = resolveTarget(natural: natural) else {
            finishMount(mountGeneration)
            return
        }
        let scale = backingScaleProvider()
        if ControlCenterSizingPolicy.isEffectivelyEqual(
            currentTotalHeight, target.totalHeight, scale: scale
        ) {
            finishMount(mountGeneration)
            return
        }
        let gen = mountGeneration
        applyTarget(target) { [weak self] _ in
            guard let self else { return }
            self.finishMount(gen)
        }
    }

    /// 提交目标高度：唯一经适配器写外壳几何的出口。等高（含适配器缺位
    /// 测试场景）直接同步 viewport。
    func applyTarget(
        _ target: ControlCenterSizingTarget,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let sizer else {
            viewportHeight = target.viewportHeight
            completion?(true)
            return
        }
        let duration = reduceMotion
            ? configuration.reduceMotionResizeDuration
            : configuration.resizeAnimationDuration
        let chrome = shellHeight ?? defaultChromeFallback
        let scale = backingScaleProvider()
        if ControlCenterSizingPolicy.isEffectivelyEqual(
            sizer.currentTotalHeight, target.totalHeight, scale: scale
        ) {
            viewportHeight = target.viewportHeight
            completion?(true)
            return
        }
        sizer.submit(
            targetTotalHeight: target.totalHeight,
            animationDuration: duration,
            onStep: { [weak self] totalHeight in
                guard let self else { return }
                // viewport 与窗口高度同步：内容永不溢出，footer 恒可见。
                self.setViewportHeight(max(0, totalHeight - chrome))
            },
            completion: { [weak self] reached in
                guard let self else { return }
                if !reached {
                    // 失败/中断：以当前实际高度夹紧 viewport，保证内容可达。
                    self.setViewportHeight(max(0, sizer.currentTotalHeight - chrome))
                }
                completion?(reached)
            }
        )
    }

    private func setViewportHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        viewportHeight = height
    }

    private func finishMount(_ gen: Int) {
        guard gen == mountGeneration else { return }
        mountBudgetTask?.cancel()
        mountBudgetTask = nil
        guard let proceed = pendingProceed else { return }
        pendingProceed = nil
        proceed()
    }
}
