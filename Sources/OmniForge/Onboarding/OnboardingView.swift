import SwiftUI

/// Onboarding 主容器 — 用 TabView 管理四个步骤页面，
/// 底部自定义导航栏控制前进/后退。
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @ObservedObject var l10n: L10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // 顶部步骤指示器条 — 清晰指引当前步骤，彻底消除 TabView 产生的空白胶囊框
            topStepBar

            Divider()

            // 页面内容区 — 原生平级切换转场
            ZStack {
                switch coordinator.currentStep {
                case 0:
                    WelcomeOnboardingPage(coordinator: coordinator, strings: l10n.s)
                case 1:
                    PlaygroundOnboardingPage(strings: l10n.s)
                case 2:
                    PermissionOnboardingPage(strings: l10n.s)
                case 3:
                    MenubarAnchoringOnboardingPage(coordinator: coordinator, strings: l10n.s)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(
                PageSwitchMotionToken.peerContent(reduceMotion: reduceMotion),
                value: coordinator.currentStep
            )

            Divider()

            navigationBar
        }
        .frame(width: 660, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .omniNoFocusRing()
    }

    /// 顶部步骤导览条：展示 1~4 步当前进度与标题
    private var topStepBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<OnboardingCoordinator.totalSteps, id: \.self) { step in
                stepBadge(for: step)
                if step < OnboardingCoordinator.totalSteps - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.04))
        )
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: 50)
    }

    @ViewBuilder
    private func stepBadge(for step: Int) -> some View {
        let isCurrent = step == coordinator.currentStep
        let isCompleted = step < coordinator.currentStep

        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : (isCompleted ? Color.green : Color.secondary.opacity(0.25)))
                    .frame(width: 14, height: 14)

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }

            Text(stepTitle(for: step))
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private func stepTitle(for step: Int) -> String {
        switch step {
        case 0: return l10n.s.onboardingStepPersona
        case 1: return l10n.s.onboardingStepPlayground
        case 2: return l10n.s.onboardingStepPermissions
        case 3: return l10n.s.onboardingStepLaunch
        default: return ""
        }
    }

    /// 底部导航栏：ZStack 分层确保中心指示点恒定绝对居中，左侧上一步与右侧下一步位置恒定不晃动
    private var navigationBar: some View {
        ZStack {
            // 1. 中间指示圆点（绝对居中，完全不受左右按钮文字长度影响）
            HStack(spacing: 6) {
                ForEach(0..<OnboardingCoordinator.totalSteps, id: \.self) { step in
                    Capsule()
                        .fill(step == coordinator.currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: step == coordinator.currentStep ? 14 : 5, height: 5)
                        .animation(.easeInOut(duration: 0.2), value: coordinator.currentStep)
                }
            }

            // 2. 左右操作按钮
            HStack {
                // 左侧按钮：Step 0 时透明并禁用但保持占位，位置永远锁定在最左侧
                Button(l10n.s.onboardingBack) {
                    coordinator.goBack()
                }
                .controlSize(.large)
                .opacity(coordinator.currentStep > 0 ? 1 : 0)
                .disabled(coordinator.currentStep == 0)

                Spacer()

                // 右侧按钮：始终锁定在最右侧
                Button(coordinator.isLastStep ? l10n.s.onboardingStartTourButton : l10n.s.onboardingNext) {
                    if coordinator.isLastStep {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            coordinator.complete()
                        }
                    } else {
                        coordinator.advanceStep()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }
}

/// Onboarding 最后一步：完成页
struct DoneOnboardingPage: View {
    let strings: Strings

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                    Text(strings.onboardingDoneTitle)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 260)

            VStack(spacing: 12) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)

                Text(strings.onboardingDoneHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }
            .padding(.top, 32)

            Spacer()
        }
    }
}
