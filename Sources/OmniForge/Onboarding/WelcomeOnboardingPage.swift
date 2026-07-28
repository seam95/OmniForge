import AppKit
import SwiftUI

/// Onboarding 第一步：欢迎页 — 展示应用图标、名称和简介。
struct WelcomeOnboardingPage: View {
    let strings: Strings

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)

            VStack(spacing: 10) {
                Text(strings.onboardingWelcomeTitle)
                    .font(.system(size: 26, weight: .bold))

                Text(strings.onboardingWelcomeBody)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 48)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
