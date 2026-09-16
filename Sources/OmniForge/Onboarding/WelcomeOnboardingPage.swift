import AppKit
import SwiftUI

/// Onboarding 第一步：欢迎与场景预设选择
struct WelcomeOnboardingPage: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let strings: Strings

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 20) {
            // 头部：品牌与定位
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)

                Text(strings.onboardingWelcomeTitle)
                    .font(.system(size: 22, weight: .bold))

                Text(strings.onboardingPersonaSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 16)

            // 场景预设卡片矩阵 (2x2)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(OnboardingPersona.allCases) { persona in
                    personaCard(persona)
                }
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func personaCard(_ persona: OnboardingPersona) -> some View {
        let isSelected = coordinator.selectedPersona == persona

        Button {
            coordinator.selectedPersona = persona
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(persona.accentColor.opacity(isSelected ? 0.2 : 0.08))
                        .frame(width: 38, height: 38)
                    Image(systemName: persona.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(persona.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(persona.title(in: strings))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Text(persona.description(in: strings))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
