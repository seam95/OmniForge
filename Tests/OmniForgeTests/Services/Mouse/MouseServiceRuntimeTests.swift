import XCTest
@testable import OmniForge

final class MouseServiceRuntimeTests: XCTestCase {
    func test_scrollInverterUsesSharedFailureAndRetryLifecycle() {
        let fixture = makeFixture(suite: "MouseServiceRuntimeTests_inverter")
        fixture.defaults.set(true, forKey: UserDefaultsKeys.scrollInverterEnabled)
        let service = ScrollInverter(
            userDefaults: fixture.defaults,
            featureAvailable: { true },
            permissionGranted: { true },
            startOverride: fixture.start,
            stopOverride: fixture.stop
        )

        assertFailureThenRetry(
            fixture: fixture,
            sync: service.syncWithPreferences,
            retry: service.retry,
            isRunning: { service.isRunning },
            lastError: { service.lastError },
            runState: { service.runState }
        )
    }

    func test_smoothScrollUsesSharedFailureAndRetryLifecycle() {
        let fixture = makeFixture(suite: "MouseServiceRuntimeTests_smooth")
        fixture.defaults.set(true, forKey: UserDefaultsKeys.smoothScrollEnabled)
        let service = SmoothScrollService(
            userDefaults: fixture.defaults,
            featureAvailable: { true },
            permissionGranted: { true },
            startOverride: fixture.start,
            stopOverride: fixture.stop
        )

        assertFailureThenRetry(
            fixture: fixture,
            sync: service.syncWithPreferences,
            retry: service.retry,
            isRunning: { service.isRunning },
            lastError: { service.lastError },
            runState: { service.runState }
        )
    }

    func test_mouseNavigationUsesSharedFailureAndRetryLifecycle() {
        let fixture = makeFixture(suite: "MouseServiceRuntimeTests_navigation")
        fixture.defaults.set(true, forKey: UserDefaultsKeys.mouseNavigationEnabled)
        let service = MouseNavigationService(
            userDefaults: fixture.defaults,
            featureAvailable: { true },
            permissionGranted: { true },
            startOverride: fixture.start,
            stopOverride: fixture.stop
        )

        assertFailureThenRetry(
            fixture: fixture,
            sync: service.syncWithPreferences,
            retry: service.retry,
            isRunning: { service.isRunning },
            lastError: { service.lastError },
            runState: { service.runState }
        )
    }

    func test_dockClickUsesSharedFailureAndRetryLifecycle() {
        let fixture = makeFixture(suite: "MouseServiceRuntimeTests_dock")
        fixture.defaults.set(true, forKey: UserDefaultsKeys.dockClickMinimize)
        let service = DockClickService(
            userDefaults: fixture.defaults,
            featureAvailable: { true },
            permissionGranted: { true },
            startOverride: fixture.start,
            stopOverride: fixture.stop
        )

        assertFailureThenRetry(
            fixture: fixture,
            sync: service.syncWithPreferences,
            retry: service.retry,
            isRunning: { service.isRunning },
            lastError: { service.lastError },
            runState: { service.runState }
        )
    }

    private func assertFailureThenRetry(
        fixture: Fixture,
        sync: () -> Void,
        retry: () -> Void,
        isRunning: () -> Bool,
        lastError: () -> String?,
        runState: () -> FeatureRunState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        sync()
        XCTAssertFalse(isRunning(), file: file, line: line)
        XCTAssertEqual(lastError(), "injected start failure", file: file, line: line)
        XCTAssertEqual(runState(), .failed("injected start failure"), file: file, line: line)
        XCTAssertEqual(fixture.startCount, 1, file: file, line: line)

        sync()
        XCTAssertEqual(fixture.startCount, 1, "失败后普通同步不得自动重试", file: file, line: line)

        retry()
        XCTAssertTrue(isRunning(), file: file, line: line)
        XCTAssertNil(lastError(), file: file, line: line)
        XCTAssertEqual(runState(), .running, file: file, line: line)
        XCTAssertEqual(fixture.startCount, 2, file: file, line: line)
    }

    private func makeFixture(suite: String) -> Fixture {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Defaults.register(in: defaults)
        return Fixture(defaults: defaults)
    }
}

private final class Fixture {
    let defaults: UserDefaults
    var failFirstStart = true
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    lazy var start: () throws -> Void = { [weak self] in
        guard let self else { return }
        startCount += 1
        if failFirstStart, startCount == 1 {
            throw FixtureError.injectedStartFailure
        }
    }

    lazy var stop: () -> Void = { [weak self] in
        self?.stopCount += 1
    }
}

private enum FixtureError: LocalizedError {
    case injectedStartFailure

    var errorDescription: String? { "injected start failure" }
}
