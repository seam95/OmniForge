import SwiftUI

/// Onboarding 第三步：特性概览页 — 展示所有特性的名称、图标和简短描述。
struct FeatureShowcaseOnboardingPage: View {
    let strings: Strings
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(strings.onboardingFeaturesTitle)
                    .font(.system(size: 19, weight: .bold))
                Text(strings.onboardingFeaturesBody)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 48)
            }
            .padding(.top, 30)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(AppFeature.allCases, id: \.rawValue) { feature in
                        OnboardingFeatureRow(
                            feature: feature,
                            strings: strings,
                            isAvailable: runtime.isAvailable(feature)
                        )
                    }
                }
                .padding(.horizontal, 28)
            }

            Spacer()
        }
        .id(runtime.revision)
    }
}

/// 单个特性展示行（onboarding 专用，避免与 FeatureHub 的 FeatureRow 冲突）
private struct OnboardingFeatureRow: View {
    let feature: AppFeature
    let strings: Strings
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: feature.displayIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayTitle(in: strings))
                    .font(.system(size: 13, weight: .semibold))
                Text(feature.displayDescription(in: strings))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isAvailable ? .green : .secondary)
                .font(.system(size: 14))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - AppFeature 展示信息扩展

extension AppFeature {
    /// 用于 onboarding 展示的 SF Symbol 图标名
    var displayIcon: String {
        switch self {
        case .inputLock: return "keyboard"
        case .clipboardHistory: return "doc.on.clipboard"
        case .quickPhrase: return "text.bubble"
        case .systemMonitor: return "chart.bar"
        case .shelf: return "tray.full"
        case .launchAtLogin: return "power"
        case .cleaner, .uninstaller, .colorPicker, .networkDiagnostics, .dshWeb: return symbolName
        // 鼠标与触控板特性复用 Hub 图标
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick:
            return symbolName
        case .keepAwake, .screenshot, .tokenUsage, .providerSwitch, .stickyNotes, .cleaningMode:
            return symbolName
        }
    }

    func displayTitle(in strings: Strings) -> String {
        switch self {
        case .inputLock: return strings.onboardingFeatureInputLockTitle
        case .clipboardHistory: return strings.onboardingFeatureClipboardHistoryTitle
        case .quickPhrase: return strings.onboardingFeatureQuickPhraseTitle
        case .systemMonitor: return strings.onboardingFeatureSystemMonitorTitle
        case .shelf: return strings.onboardingFeatureShelfTitle
        case .launchAtLogin: return strings.onboardingFeatureLaunchAtLoginTitle
        case .cleaner, .uninstaller, .colorPicker, .networkDiagnostics, .dshWeb: return hubName(in: strings)
        // 鼠标与触控板特性复用 Hub 名称
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick:
            return hubName(in: strings)
        case .keepAwake, .screenshot, .tokenUsage, .providerSwitch, .stickyNotes, .cleaningMode:
            return hubName(in: strings)
        }
    }

    func displayDescription(in strings: Strings) -> String {
        switch self {
        case .inputLock: return strings.onboardingFeatureInputLockDescription
        case .clipboardHistory: return strings.onboardingFeatureClipboardHistoryDescription
        case .quickPhrase: return strings.onboardingFeatureQuickPhraseDescription
        case .systemMonitor: return strings.onboardingFeatureSystemMonitorDescription
        case .shelf: return strings.onboardingFeatureShelfDescription
        case .launchAtLogin: return strings.onboardingFeatureLaunchAtLoginDescription
        case .cleaner, .uninstaller, .colorPicker, .networkDiagnostics, .dshWeb: return hubDescription(in: strings)
        // 鼠标与触控板特性复用 Hub 描述
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick:
            return hubDescription(in: strings)
        case .keepAwake, .screenshot, .tokenUsage, .providerSwitch, .stickyNotes, .cleaningMode:
            return hubDescription(in: strings)
        }
    }
}
