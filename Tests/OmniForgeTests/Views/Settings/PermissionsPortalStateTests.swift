import XCTest
@testable import OmniForge

final class PermissionsPortalStateTests: XCTestCase {
    func test_signatureDiagnosticContainsOnlyKindBundleAndTeam() {
        let summary = PermissionSignatureSummary(
            kind: .stable,
            identifier: "app.omniforge",
            teamIdentifier: "TEAM123"
        )

        XCTAssertEqual(
            PermissionsPortalState.signatureDiagnostic(summary),
            "stable · app.omniforge · TEAM123"
        )
    }

    func test_usageEntries_keepAwakeAccessibilityReflectsJigglePreference() {
        let inactive = PermissionsPortalState.usageEntries(
            for: .accessibility,
            isAvailable: { $0 == .keepAwake },
            mouseJiggleEnabled: false
        )
        XCTAssertEqual(inactive.map(\.feature), [.keepAwake])
        XCTAssertEqual(inactive.map(\.usage), [.inactive])

        let configured = PermissionsPortalState.usageEntries(
            for: .accessibility,
            isAvailable: { $0 == .keepAwake },
            mouseJiggleEnabled: true
        )
        XCTAssertEqual(configured.map(\.usage), [.configured])
    }

    func test_usageEntries_keepAwakeNotificationsAlwaysOptional() {
        let entries = PermissionsPortalState.usageEntries(
            for: .notifications,
            isAvailable: { $0 == .keepAwake || $0 == .systemMonitor },
            mouseJiggleEnabled: false
        )
        let keepAwake = entries.first { $0.feature == .keepAwake }
        let monitor = entries.first { $0.feature == .systemMonitor }
        XCTAssertEqual(keepAwake?.usage, .optional)
        XCTAssertEqual(monitor?.usage, .optional)
    }

    func test_usageEntries_requiredFeaturesStayRequired() {
        let entries = PermissionsPortalState.usageEntries(
            for: .accessibility,
            isAvailable: { $0 == .inputLock },
            mouseJiggleEnabled: false
        )
        XCTAssertEqual(entries.map(\.usage), [.required])
    }

    func test_usageEntries_unavailableFeaturesAreOmitted() {
        let entries = PermissionsPortalState.usageEntries(
            for: .accessibility,
            isAvailable: { _ in false },
            mouseJiggleEnabled: true
        )
        XCTAssertTrue(entries.isEmpty)
    }

    func test_usageLabel_coversAllFourStates() {
        XCTAssertFalse(PermissionsPortalState.usageLabel(.required, strings: .en).isEmpty)
        XCTAssertFalse(PermissionsPortalState.usageLabel(.configured, strings: .en).isEmpty)
        XCTAssertFalse(PermissionsPortalState.usageLabel(.optional, strings: .en).isEmpty)
        XCTAssertFalse(PermissionsPortalState.usageLabel(.inactive, strings: .en).isEmpty)
        XCTAssertFalse(PermissionsPortalState.usageLabel(.required, strings: .zhHans).isEmpty)
    }

    func test_grantAction_mapsEveryPermission() {
        XCTAssertEqual(
            Permissions.grantAction(for: .accessibility),
            .promptAccessibility
        )
        XCTAssertEqual(
            Permissions.grantAction(for: .inputMonitoring),
            .openInputMonitoringSettings
        )
        XCTAssertEqual(
            Permissions.grantAction(for: .notifications),
            .requestNotifications
        )
        XCTAssertEqual(
            Permissions.grantAction(for: .fullDiskAccess),
            .requestFullDiskAccess
        )
        XCTAssertEqual(
            Permissions.grantAction(for: .screenRecording),
            .requestScreenRecording
        )
    }

    func test_grantAction_coversAllCases() {
        // 新增 AppPermission 时若未更新 grantAction，此处会因 switch 不完整编译失败；
        // 运行时再保证 allCases 均有映射。
        for permission in AppPermission.allCases {
            _ = Permissions.grantAction(for: permission)
        }
        XCTAssertEqual(AppPermission.allCases.count, 5)
    }
}
