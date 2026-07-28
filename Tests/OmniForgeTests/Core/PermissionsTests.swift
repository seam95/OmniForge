import ApplicationServices
import Combine
import XCTest
@testable import OmniForge

@MainActor
final class PermissionsTests: XCTestCase {
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
        Permissions.shared.resetForTesting()
    }

    override func tearDown() {
        cancellables = nil
        Permissions.shared.resetForTesting()
        super.tearDown()
    }

    func test_initialState_allFalse() {
        XCTAssertFalse(Permissions.shared.accessibility)
        XCTAssertFalse(Permissions.shared.inputMonitoring)
    }

    func test_refresh_updatesAccessibilityState() {
        Permissions.shared.refresh()
        // 断言与系统真实 Accessibility 状态一致，避免开发机已授权时误失败
        XCTAssertEqual(Permissions.shared.accessibility, AXIsProcessTrusted())
    }

    func test_refreshPublishesInjectedPermissionStatesAndSignature() {
        let probe = FakePermissionProbe(accessibility: false, inputMonitoring: true)
        let permissions = Permissions(probe: probe, observeActivation: false)

        permissions.refresh()

        XCTAssertFalse(permissions.accessibility)
        XCTAssertTrue(permissions.inputMonitoring)
        XCTAssertEqual(probe.inputMonitoringChecks, 2)
        XCTAssertEqual(
            permissions.signatureSummary,
            PermissionSignatureSummary(
                kind: .stable,
                identifier: "app.omniforge",
                teamIdentifier: "TEAM123"
            )
        )
    }

    func test_featuresByPermission_accessibility() {
        let accessibilityFeatures = AppFeature.allCases.filter {
            $0.permissions.contains(.accessibility)
        }
        XCTAssertTrue(accessibilityFeatures.contains(.inputLock))
        XCTAssertFalse(accessibilityFeatures.contains(.clipboardHistory))
    }

    func test_featuresByPermission_notifications() {
        let notificationFeatures = AppFeature.allCases.filter {
            $0.permissions.contains(.notifications)
        }
        XCTAssertTrue(notificationFeatures.contains(.systemMonitor))
        XCTAssertTrue(notificationFeatures.contains(.keepAwake))
    }

    func test_featuresByPermission_accessibility_includesKeepAwakeAsPossible() {
        let accessibilityFeatures = AppFeature.allCases.filter {
            $0.possiblePermissions.contains(.accessibility)
        }
        XCTAssertTrue(accessibilityFeatures.contains(.keepAwake))
        // 普通会话不把 accessibility 标为 required
        XCTAssertNotEqual(
            AppFeature.keepAwake.permissionUsage(for: .accessibility, mouseJiggleEnabled: false),
            .required
        )
    }

    func test_featureRequiringPermission_listedWhenNotGranted() {
        let features = AppFeature.featuresRequiring(.accessibility,
                                                     isAvailable: { _ in true },
                                                     isPermissionGranted: { _ in false })
        XCTAssertTrue(features.contains(.inputLock))
    }

    func test_featureNotRequiringPermission_notListed() {
        let features = AppFeature.featuresRequiring(.accessibility,
                                                     isAvailable: { _ in true },
                                                     isPermissionGranted: { _ in true })
        XCTAssertFalse(features.contains(.clipboardHistory))
    }
}

private final class FakePermissionProbe: PermissionProbing {
    let accessibilityGranted: Bool
    private let storedInputMonitoringGranted: Bool
    let screenRecordingGranted: Bool
    let signatureSummary = PermissionSignatureSummary(
        kind: .stable,
        identifier: "app.omniforge",
        teamIdentifier: "TEAM123"
    )
    private(set) var inputMonitoringChecks = 0

    var inputMonitoringGranted: Bool {
        inputMonitoringChecks += 1
        return storedInputMonitoringGranted
    }

    init(accessibility: Bool, inputMonitoring: Bool, screenRecording: Bool = false) {
        accessibilityGranted = accessibility
        storedInputMonitoringGranted = inputMonitoring
        screenRecordingGranted = screenRecording
    }
}
