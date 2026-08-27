import AppKit
import SwiftUI
import Vortex

/// 全屏重置庆祝：额度窗口 rollover 后放烟花（Vortex 两段式：火箭上升 → 死亡时爆裂，
/// 带 sparkle 尾迹）+ 可选 toast 横幅。每屏一个 borderless、点击穿透的
/// `NSPanel` 悬浮在 status-bar 层级、跨所有 Space；不抢焦点、不拦截鼠标，用户可继续工作；
/// 展示数秒后自动拆除，机器睡眠/息屏时立即结束。
@MainActor
final class TokenResetCelebrationController {

    private var panels: [NSPanel] = []
    private var dismissTask: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []
    private let lifetime: TimeInterval = 9.0

    init() {
        registerSleepTeardownObservers()
    }

    deinit {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// 展示庆祝的任一部分：`message` 存在且 `showsToast` 时显示顶部 toast；
    /// `showsConfetti` 时全屏烟花。两者均关（或已在庆祝中）时直接忽略。
    func play(
        message: String?,
        provider: TokenUsageProvider?,
        showsToast: Bool,
        showsConfetti: Bool
    ) {
        guard showsToast || showsConfetti else { return }
        guard panels.isEmpty else { return }            // 已在庆祝 — 忽略重入
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        for screen in screens {
            let panel = makePanel(for: screen)
            // 庆祝横跨每块屏，所以每块屏都要能看见「是哪家/哪个窗口重置了」。
            let host = NSHostingView(rootView: TokenResetCelebrationOverlayView(
                message: message,
                provider: provider,
                showsToast: showsToast,
                showsConfetti: showsConfetti
            ))
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = host
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        dismissTask = Task { [weak self, lifetime] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = ClickThroughPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setFrame(screen.frame, display: false)
        return panel
    }

    /// 庆祝是 ~9 秒的瞬时效果，睡眠/息屏时没人看它 — 立即结束。
    /// 同时保证粒子模拟有界：睡眠期间 `TimelineView` 停止走帧，而 Vortex 的每帧
    /// delta 取自墙钟，唤醒后第一帧会把整个睡眠时长灌进模拟，代价见
    /// `makeFireworksSystem()` 中对大 delta 的说明。
    private func registerSleepTeardownObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
            sleepObservers.append(observer)
        }
    }
}

/// 永不抢焦点/主窗口、不接受第一响应者的无边框透明面板 — 纯覆盖层。
private final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

/// 烟花（Vortex）+ 可选顶部 toast 横幅。
private struct TokenResetCelebrationOverlayView: View {
    let message: String?
    let provider: TokenUsageProvider?
    let showsToast: Bool
    let showsConfetti: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastShown = false
    @State private var fireworksShown = true
    /// 由本视图私有持有，绝不共享：见 `makeFireworksSystem()`。
    @State private var fireworks: VortexSystem = makeFireworksSystem()
    private let fireworksDuration: TimeInterval = 5.0
    private let toastFadeDelay: TimeInterval = 7.5

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            if showsConfetti && fireworksShown {
                VortexView(fireworks)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + fireworksDuration) {
                            withAnimation(.easeOut(duration: 0.5)) { fireworksShown = false }
                        }
                    }
            }

            if showsToast, let message {
                HStack(spacing: 10) {
                    if let provider {
                        TokenUsageProviderIconView(provider: provider, size: 24, cornerRadius: 6)
                    }
                    Text(message)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .opacity(toastShown ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (toastShown ? 1 : 0.96))
                .offset(y: reduceMotion ? 0 : (toastShown ? 0 : -10))
                .blur(radius: reduceMotion ? 0 : (toastShown ? 0 : 3))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message)
                .onAppear {
                    let entrance: Animation = reduceMotion
                        ? .easeOut(duration: 0.2)
                        : .spring(response: 0.48, dampingFraction: 0.86)
                    withAnimation(entrance) { toastShown = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + toastFadeDelay) {
                        withAnimation(.easeInOut(duration: 0.45)) { toastShown = false }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Vortex 烟花

/// 为单个覆盖层视图构建**全新、私有**的烟花系统。
///
/// Vortex 自带的 `VortexSystem.fireworks` 是 class 上的 `static let`，即全进程共享的
/// 可变模拟对象。把它直接交给 `VortexView` 会复现 TokenTracker 的 issue #432：
///
/// * 庆祝结束时视图被移除，但单例仍保留 `particles`、活跃的
///   `activeSecondarySystems` 和 `lastUpdate` 时间戳。
/// * 下次庆祝重新挂载同一对象，首次 `update()` 会让残留子系统以两次庆祝
///   之间的**完整间隔**作为 `delta` 续跑。
/// * `createParticles()` 会循环 `birthRate * delta` 次 — 发射上限只在循环体内
///   检查，并不约束循环次数。泄露的爆炸系统按 100_000 粒子/秒、几小时的间隔，
///   就是 `Canvas` 内主线程数十亿次迭代，对应报告的数秒级卡死。
/// * 额外问题：共享 `emissionCount` 从不重置，累计发射满 1000 发火箭后烟花
///   彻底不再渲染，直到重启应用。
///
/// 每视图私有系统让每次庆祝互相独立，也避免多屏场景（每屏一个 `VortexView`）
/// 在同一帧内驱动同一模拟对象多次。
func makeFireworksSystem() -> VortexSystem {
    let sparkles = VortexSystem(
        tags: ["circle"],
        spawnOccasion: .onUpdate,
        emissionLimit: 1,
        lifespan: 0.5,
        speed: 0.05,
        angleRange: .degrees(90),
        size: 0.05
    )

    let explosion = VortexSystem(
        tags: ["circle"],
        spawnOccasion: .onDeath,
        position: [0.5, 1],
        // Vortex 预设在这里用 100_000 仅为表达「瞬间」。由于 `createParticles()`
        // 不论 `emissionLimit` 如何都会迭代 `birthRate * delta` 次，该数值同时是
        // 任何长帧 delta 的乘数。每帧（`VortexView` 以 60fps 渲染）发射一个上限
        // 的量同样瞬间，且把最坏情况约束低约三个数量级。
        birthRate: Double(fireworksExplosionEmissionLimit * 60),
        emissionLimit: fireworksExplosionEmissionLimit,
        speed: 0.5,
        speedVariation: 1,
        angleRange: .degrees(360),
        acceleration: [0, 1.5],
        dampingFactor: 4,
        colors: .randomRamp(
            [.white, .pink, .pink],
            [.white, .blue, .blue],
            [.white, .green, .green],
            [.white, .orange, .orange],
            [.white, .cyan, .cyan]
        ),
        size: 0.15,
        sizeVariation: 0.1,
        sizeMultiplierAtDeath: 0
    )

    return VortexSystem(
        tags: ["circle"],
        secondarySystems: [sparkles, explosion],
        position: [0.5, 1],
        birthRate: 2,
        emissionLimit: 1000,
        speed: 1.5,
        speedVariation: 0.75,
        angleRange: .degrees(60),
        dampingFactor: 2,
        size: 0.15,
        stretchFactor: 4
    )
}

/// 单发火箭爆裂出的粒子数上限。
let fireworksExplosionEmissionLimit = 500
