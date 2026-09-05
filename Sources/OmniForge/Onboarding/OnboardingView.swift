import SwiftUI

/// Onboarding 主容器 — 用 TabView 管理四个步骤页面，
/// 底部自定义导航栏控制前进/后退。
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @ObservedObject var l10n: L10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $coordinator.currentStep) {
                WelcomeOnboardingPage(strings: l10n.s)
                    .tag(0)
                PermissionOnboardingPage(strings: l10n.s)
                    .tag(1)
                FeatureShowcaseOnboardingPage(strings: l10n.s)
                    .tag(2)
                DoneOnboardingPage(strings: l10n.s)
                    .tag(3)
            }
            .tabViewStyle(.automatic)
            // 步骤切换复用统一 Motion Policy（SPEC §5.1）：平级内容过渡，
            // Reduce Motion 下降级为 80ms 淡切。
            .animation(
                PageSwitchMotionToken.peerContent(reduceMotion: reduceMotion),
                value: coordinator.currentStep
            )

            Divider()

            navigationBar
        }
        .frame(width: 640, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .omniNoFocusRing()
    }

    private var navigationBar: some View {
        HStack {
            if coordinator.currentStep > 0 {
                Button(l10n.s.onboardingBack) {
                    coordinator.goBack()
                }
                .controlSize(.large)
            }

            Spacer()

            // 步骤指示器
            HStack(spacing: 6) {
                ForEach(0..<OnboardingCoordinator.totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step == coordinator.currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            Button(coordinator.isLastStep ? l10n.s.onboardingFinish : l10n.s.onboardingNext) {
                if coordinator.isLastStep {
                    coordinator.complete()
                } else {
                    coordinator.advanceStep()
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
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
