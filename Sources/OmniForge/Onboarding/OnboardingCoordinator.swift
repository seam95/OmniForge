import Combine
import Foundation

/// Onboarding 流程状态管理器 — 控制步骤导航、持久化和中断恢复。
/// macOS 在用户去 System Settings 授予权限后可能强制重启应用，
/// 因此 currentStep 被持久化，重启后从上次位置继续。
@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let shared = OnboardingCoordinator()

    /// Onboarding 总步骤数：欢迎 → 权限 → 特性概览 → 完成
    static let totalSteps = 4

    @Published var currentStep: Int = 0
    @Published var isWindowVisible: Bool = false
    @Published var isWhatsNewVisible: Bool = false

    private let userDefaults: UserDefaults

    /// 当前应用版本号（来自 Bundle）
    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 是否需要首次 onboarding
    var needsOnboarding: Bool {
        !userDefaults.bool(forKey: UserDefaultsKeys.hasOnboarded)
    }

    /// 是否需要显示 What's New（已完成 onboarding 但版本不同）
    var needsWhatsNew: Bool {
        guard !needsOnboarding else { return false }
        let completed = userDefaults.string(forKey: UserDefaultsKeys.onboardingCompletedVersion) ?? ""
        return completed != currentAppVersion
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        restoreStepIfNeeded()
    }

    // MARK: - 启动检查

    /// 应用启动时调用：根据状态显示 onboarding 或 What's New
    func startIfNeeded() {
        if needsOnboarding {
            showOnboarding()
        } else if needsWhatsNew {
            showWhatsNew()
        }
    }

    // MARK: - 步骤导航

    func advanceStep() {
        guard currentStep < Self.totalSteps - 1 else { return }
        currentStep += 1
        userDefaults.set(currentStep, forKey: UserDefaultsKeys.onboardingCurrentStep)
    }

    func goBack() {
        guard currentStep > 0 else { return }
        currentStep -= 1
        userDefaults.set(currentStep, forKey: UserDefaultsKeys.onboardingCurrentStep)
    }

    /// 是否在最后一步（完成页）
    var isLastStep: Bool {
        currentStep >= Self.totalSteps - 1
    }

    // MARK: - 完成

    func complete() {
        userDefaults.set(true, forKey: UserDefaultsKeys.hasOnboarded)
        userDefaults.set(currentAppVersion, forKey: UserDefaultsKeys.onboardingCompletedVersion)
        userDefaults.removeObject(forKey: UserDefaultsKeys.onboardingCurrentStep)
        currentStep = 0
        isWindowVisible = false
    }

    // MARK: - What's New

    func skipWhatsNew() {
        userDefaults.set(currentAppVersion, forKey: UserDefaultsKeys.onboardingCompletedVersion)
        isWhatsNewVisible = false
    }

    // MARK: - 窗口控制

    func showOnboarding() {
        isWindowVisible = true
    }

    func showWhatsNew() {
        isWhatsNewVisible = true
    }

    // MARK: - 中断恢复

    /// 从持久化恢复步骤——仅在未完成 onboarding 时生效
    private func restoreStepIfNeeded() {
        guard needsOnboarding else {
            currentStep = 0
            return
        }
        let saved = userDefaults.integer(forKey: UserDefaultsKeys.onboardingCurrentStep)
        currentStep = min(max(0, saved), Self.totalSteps - 1)
    }

    // MARK: - 测试支持

    func resetForTesting() {
        currentStep = 0
        isWindowVisible = false
        isWhatsNewVisible = false
    }
}
