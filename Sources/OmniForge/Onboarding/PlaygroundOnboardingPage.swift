import AppKit
import SwiftUI

/// Onboarding 第二步：动手演练场 — 交互式测试快捷键与体验即时正反馈
struct PlaygroundOnboardingPage: View {
    let strings: Strings

    @State private var hasTriggeredShortcut: Bool = false
    @State private var localKeyMonitor: Any?

    var body: some View {
        VStack(spacing: 22) {
            // 头部标题
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "command")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Text(strings.onboardingPlaygroundTitle)
                    .font(.system(size: 20, weight: .bold))

                Text(strings.onboardingPlaygroundSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 16)

            // 核心交互体验卡片
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 16, weight: .semibold))
                    Text(strings.onboardingPlaygroundCardTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if hasTriggeredShortcut {
                        Label(strings.onboardingPlaygroundSuccess, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text(strings.onboardingPlaygroundWaiting)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                // 快捷键按键可视化
                HStack(spacing: 10) {
                    keyBadge("⌘", "Command")
                    Text("+").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    keyBadge("⇧", "Shift")
                    Text("+").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    keyBadge("V", "Key")
                }
                .padding(.vertical, 4)

                Text(strings.onboardingPlaygroundTip)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                // 模拟试按按钮（方便触控板操作或无外接键盘时的辅助选项）
                if !hasTriggeredShortcut {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            hasTriggeredShortcut = true
                        }
                    } label: {
                        Text("测试按键效果")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hasTriggeredShortcut ? Color.green.opacity(0.06) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hasTriggeredShortcut ? Color.green.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 44)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    @ViewBuilder
    private func keyBadge(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(symbol)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 54, minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 检测是否按下 Cmd + Shift + V (KeyCode 9 是 'v')
            let isCmd = event.modifierFlags.contains(.command)
            let isShift = event.modifierFlags.contains(.shift)
            if isCmd && isShift && event.keyCode == 9 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    hasTriggeredShortcut = true
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }
}
