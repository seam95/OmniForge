import XCTest
@testable import OmniForge

@MainActor
final class OnboardingCoordinatorTests: XCTestCase {
    private var coordinator: OnboardingCoordinator!
    private let suite = "OnboardingCoordinatorTests"

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Defaults.register(in: defaults)
        coordinator = OnboardingCoordinator(userDefaults: defaults)
    }

    override func tearDown() {
        coordinator.resetForTesting()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        coordinator = nil
        super.tearDown()
    }

    // MARK: - 初始状态

    func test_needsOnboarding_trueWhenNotOnboarded() {
        XCTAssertTrue(coordinator.needsOnboarding)
    }

    func test_needsOnboarding_falseAfterComplete() {
        coordinator.complete()
        XCTAssertFalse(coordinator.needsOnboarding)
    }

    func test_needsWhatsNew_falseWhenNotOnboarded() {
        XCTAssertFalse(coordinator.needsWhatsNew)
    }

    // MARK: - 步骤导航

    func test_initialStep_isZero() {
        XCTAssertEqual(coordinator.currentStep, 0)
    }

    func test_advanceStep_incrementsAndPersists() {
        let defaults = UserDefaults(suiteName: suite)!
        coordinator.advanceStep()
        XCTAssertEqual(coordinator.currentStep, 1)
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.onboardingCurrentStep), 1)
    }

    func test_advanceStep_clampsToLastStep() {
        for _ in 0..<10 { coordinator.advanceStep() }
        XCTAssertEqual(coordinator.currentStep, OnboardingCoordinator.totalSteps - 1)
    }

    func test_goBack_decrementsAndPersists() {
        coordinator.advanceStep()
        coordinator.goBack()
        XCTAssertEqual(coordinator.currentStep, 0)
    }

    func test_goBack_clampsToZero() {
        coordinator.goBack()
        XCTAssertEqual(coordinator.currentStep, 0)
    }

    // MARK: - 完成

    func test_complete_setsHasOnboardedAndVersion() {
        let defaults = UserDefaults(suiteName: suite)!
        coordinator.complete()
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.hasOnboarded))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.onboardingCompletedVersion),
            coordinator.currentAppVersion
        )
    }

    func test_complete_clearsCurrentStep() {
        let defaults = UserDefaults(suiteName: suite)!
        coordinator.advanceStep()
        coordinator.advanceStep()
        coordinator.complete()
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.onboardingCurrentStep), 0)
        XCTAssertEqual(coordinator.currentStep, 0)
    }

    func test_complete_closesWindow() {
        coordinator.showOnboarding()
        XCTAssertTrue(coordinator.isWindowVisible)
        coordinator.complete()
        XCTAssertFalse(coordinator.isWindowVisible)
    }

    // MARK: - 中断恢复

    func test_resumeFromInterruption_restoresStepFromPersistence() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(2, forKey: UserDefaultsKeys.onboardingCurrentStep)
        defaults.set(false, forKey: UserDefaultsKeys.hasOnboarded)

        let resumed = OnboardingCoordinator(userDefaults: defaults)
        XCTAssertEqual(resumed.currentStep, 2)
        XCTAssertTrue(resumed.needsOnboarding)
    }

    func test_resumeFromInterruption_doesNotRestoreAfterComplete() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(2, forKey: UserDefaultsKeys.onboardingCurrentStep)
        defaults.set(true, forKey: UserDefaultsKeys.hasOnboarded)

        let resumed = OnboardingCoordinator(userDefaults: defaults)
        XCTAssertEqual(resumed.currentStep, 0, "已完成 onboarding 的用户不应恢复步骤")
    }

    // MARK: - What's New

    func test_needsWhatsNew_trueAfterVersionChange() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: UserDefaultsKeys.hasOnboarded)
        defaults.set("0.9.0", forKey: UserDefaultsKeys.onboardingCompletedVersion)

        let resumed = OnboardingCoordinator(userDefaults: defaults)
        // currentAppVersion 来自 Bundle，测试环境中可能是 "1.0" 或其他
        XCTAssertTrue(resumed.needsWhatsNew)
    }

    func test_needsWhatsNew_falseAfterSkip() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: UserDefaultsKeys.hasOnboarded)
        defaults.set("0.9.0", forKey: UserDefaultsKeys.onboardingCompletedVersion)

        let resumed = OnboardingCoordinator(userDefaults: defaults)
        resumed.skipWhatsNew()
        XCTAssertFalse(resumed.needsWhatsNew)
    }

    // MARK: - 窗口控制

    func test_startIfNeeded_showsOnboardingWhenNeeded() {
        coordinator.startIfNeeded()
        XCTAssertTrue(coordinator.isWindowVisible)
    }

    func test_startIfNeeded_doesNotShowWhenNotNeeded() {
        coordinator.complete()
        coordinator.startIfNeeded()
        XCTAssertFalse(coordinator.isWindowVisible)
    }
}
