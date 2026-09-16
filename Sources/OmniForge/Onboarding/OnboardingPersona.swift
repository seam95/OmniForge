import Foundation
import SwiftUI

/// 新手引导场景预设 — 帮助首次启动的用户根据实际场景快速初始化特性集合
enum OnboardingPersona: String, CaseIterable, Identifiable {
    case aiDeveloper
    case productivity
    case macGeek
    case allInOne

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .aiDeveloper:
            return "brain.head.profile"
        case .productivity:
            return "bolt.square.fill"
        case .macGeek:
            return "wrench.and.screwdriver.fill"
        case .allInOne:
            return "sparkles"
        }
    }

    var accentColor: Color {
        switch self {
        case .aiDeveloper:
            return .purple
        case .productivity:
            return .orange
        case .macGeek:
            return .blue
        case .allInOne:
            return .green
        }
    }

    func title(in strings: Strings) -> String {
        switch self {
        case .aiDeveloper:
            return strings.onboardingPersonaAIDeveloperTitle
        case .productivity:
            return strings.onboardingPersonaProductivityTitle
        case .macGeek:
            return strings.onboardingPersonaMacGeekTitle
        case .allInOne:
            return strings.onboardingPersonaAllInOneTitle
        }
    }

    func description(in strings: Strings) -> String {
        switch self {
        case .aiDeveloper:
            return strings.onboardingPersonaAIDeveloperDesc
        case .productivity:
            return strings.onboardingPersonaProductivityDesc
        case .macGeek:
            return strings.onboardingPersonaMacGeekDesc
        case .allInOne:
            return strings.onboardingPersonaAllInOneDesc
        }
    }

    /// 预设重点启用的特性集合
    var features: Set<AppFeature> {
        switch self {
        case .aiDeveloper:
            return [
                .tokenUsage,
                .providerSwitch,
                .promptOptimizer,
                .systemMonitor,
                .clipboardHistory,
                .quickPhrase,
                .launchAtLogin
            ]
        case .productivity:
            return [
                .clipboardHistory,
                .quickPhrase,
                .shelf,
                .stickyNotes,
                .screenshot,
                .colorPicker,
                .launchAtLogin
            ]
        case .macGeek:
            return [
                .systemMonitor,
                .keepAwake,
                .cleaner,
                .uninstaller,
                .networkDiagnostics,
                .scrollInverter,
                .smoothScroll,
                .mouseNavigation,
                .dockClick,
                .cleaningMode,
                .launchAtLogin
            ]
        case .allInOne:
            return Set(AppFeature.allCases)
        }
    }

    /// 将选定场景的特性集合应用到 FeatureRuntime
    @MainActor
    func apply(to runtime: FeatureRuntime) async {
        let desired = features
        for feature in AppFeature.allCases {
            let shouldEnable = desired.contains(feature)
            if runtime.isAvailable(feature) != shouldEnable {
                _ = await runtime.setAvailableAsync(feature, shouldEnable)
            }
        }
    }
}
