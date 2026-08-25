import AppKit
import SwiftUI

/// 全屏重置庆祝：额度窗口 rollover 后播撒花（原生 CAEmitterLayer，不引入粒子库）+ 可选 toast 横幅。
/// 对齐 TokenTracker `ScreenConfettiOverlayController`：每屏一个 borderless、点击穿透的
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
    /// `showsConfetti` 时全屏撒花。两者均关（或已在庆祝中）时直接忽略。
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
    /// 同时避免 CAEmitterLayer 在唤醒后按整个睡眠时长推进粒子模拟。
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

/// 撒花（CAEmitterLayer）+ 可选顶部 toast 横幅。
private struct TokenResetCelebrationOverlayView: View {
    let message: String?
    let provider: TokenUsageProvider?
    let showsToast: Bool
    let showsConfetti: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastShown = false
    @State private var confettiShown = true
    private let confettiDuration: TimeInterval = 4.5
    private let toastFadeDelay: TimeInterval = 7.5

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            if showsConfetti && confettiShown {
                ConfettiEmitterView()
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + confettiDuration) {
                            withAnimation(.easeOut(duration: 0.5)) { confettiShown = false }
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

// MARK: - CAEmitterLayer 撒花

/// 顶部一条发射线持续撒多彩纸屑：重力下落 + 旋转 + 横向飘散，数秒后由宿主视图淡出。
private struct ConfettiEmitterView: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfettiEmitterNSView {
        ConfettiEmitterNSView()
    }

    func updateNSView(_ nsView: ConfettiEmitterNSView, context: Context) {}
}

private final class ConfettiEmitterNSView: NSView {
    private let emitter = CAEmitterLayer()
    private static let shapeContents: [CGImage?] = [
        makeShapeImage(size: NSSize(width: 8, height: 12), cornerRadius: 1),
        makeShapeImage(size: NSSize(width: 10, height: 10), cornerRadius: 5),
        makeShapeImage(size: NSSize(width: 6, height: 14), cornerRadius: 1),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(emitter)

        let palette: [NSColor] = [
            .systemPink, .systemBlue, .systemGreen, .systemOrange,
            .systemPurple, .systemTeal, .systemRed, .systemYellow,
        ]
        let cells: [CAEmitterCell] = palette.enumerated().map { index, color in
            let cell = CAEmitterCell()
            cell.birthRate = 5
            cell.lifetime = 6
            cell.velocity = 130
            cell.velocityRange = 45
            cell.emissionLongitude = .pi / 2          // 向下发射
            cell.emissionRange = 0.5
            cell.spin = .pi / 4
            cell.spinRange = .pi
            cell.scale = 0.5
            cell.scaleRange = 0.35
            cell.contents = Self.shapeContents[index % Self.shapeContents.count]
            cell.color = color.cgColor
            return cell
        }
        emitter.emitterCells = cells
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: 0, y: -20)
        emitter.emitterSize = CGSize(width: 1, height: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        emitter.emitterPosition = CGPoint(x: width / 2, y: -20)
        emitter.emitterSize = CGSize(width: max(width, 1), height: 0)
    }

    /// 纯白形状图（圆角矩形/圆形/长条），由 cell.color 染色。
    private static func makeShapeImage(size: NSSize, cornerRadius: CGFloat) -> CGImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
