import XCTest
@testable import OmniForge

final class FeatureCatalogTests: XCTestCase {
    func test_allFeaturesHaveUniqueRawValues() {
        let rawValues = AppFeature.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "AppFeature raw values must be unique")
    }

    func test_availabilityKeyUsesFeatureAvailablePrefix() {
        for feature in AppFeature.allCases {
            XCTAssertTrue(feature.availabilityKey.hasPrefix("featureAvailable."),
                         "availabilityKey must use 'featureAvailable.' prefix, got: \(feature.availabilityKey)")
        }
    }

    func test_availabilityStore_readsFromInjectedDefaults() {
        let suiteName = "FeatureCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsFeatureAvailabilityStore(defaults: defaults)
        let feature = AppFeature.inputLock

        // 未写入时默认 true（与 Runtime store 语义一致）。
        XCTAssertTrue(store.isAvailable(feature))

        try? store.setAvailable(feature, false)
        XCTAssertFalse(store.isAvailable(feature))

        try? store.setAvailable(feature, true)
        XCTAssertTrue(store.isAvailable(feature))
    }

    func test_availabilityDefaults_allTrue() {
        let defaults = AppFeature.availabilityDefaults
        for feature in AppFeature.allCases {
            let key = feature.availabilityKey
            let value = defaults[key] as? Bool
            XCTAssertEqual(value, true, "Feature \(feature.rawValue) should default to available")
        }
    }

    func test_inputLockPermissions() {
        XCTAssertEqual(AppFeature.inputLock.permissions, [.accessibility])
    }

    func test_clipboardHistoryPermissions_empty() {
        XCTAssertEqual(AppFeature.clipboardHistory.permissions, [])
    }

    func test_systemMonitorPermissions_notifications() {
        XCTAssertEqual(AppFeature.systemMonitor.permissions, [.notifications])
    }

    func test_tokenUsage_catalogContract() {
        XCTAssertEqual(AppFeature.tokenUsage.rawValue, "tokenUsage")
        XCTAssertEqual(AppFeature.tokenUsage.group, .monitor)
        XCTAssertTrue(AppFeature.tokenUsage.enabledKeys.isEmpty)
        XCTAssertEqual(AppFeature.tokenUsage.possiblePermissions, [.notifications])
        XCTAssertEqual(AppFeature.tokenUsage.permissions, [.notifications])
        XCTAssertEqual(AppFeature.tokenUsage.permissionUsage(for: .notifications), .optional)
        XCTAssertNil(AppFeature.tokenUsage.permissionUsage(for: .accessibility))
        XCTAssertEqual(AppFeature.tokenUsage.symbolName, "chart.line.uptrend.xyaxis")
        XCTAssertEqual(AppFeature.tokenUsage.hubName(in: .en), "Token Usage")
        XCTAssertEqual(AppFeature.tokenUsage.hubName(in: .zhHans), "Token 用量")
        XCTAssertFalse(AppFeature.tokenUsage.hubDescription(in: .en).isEmpty)
        XCTAssertFalse(AppFeature.tokenUsage.hubDescription(in: .zhHans).isEmpty)
        XCTAssertEqual(FeatureGroup.features(in: .monitor), [.systemMonitor, .tokenUsage])
    }

    func test_featureGroupAssignment() {
        XCTAssertEqual(AppFeature.inputLock.group, .input)
        XCTAssertEqual(AppFeature.clipboardHistory.group, .clipboard)
        XCTAssertEqual(AppFeature.quickPhrase.group, .clipboard)
        XCTAssertEqual(AppFeature.systemMonitor.group, .monitor)
        XCTAssertEqual(AppFeature.networkDiagnostics.group, .productivity)
        XCTAssertEqual(AppFeature.launchAtLogin.group, .system)
        XCTAssertEqual(AppFeature.scrollInverter.group, .mouse)
        XCTAssertEqual(AppFeature.smoothScroll.group, .mouse)
        XCTAssertEqual(AppFeature.mouseNavigation.group, .mouse)
        XCTAssertEqual(AppFeature.dockClick.group, .mouse)
    }

    func test_enabledKeys_inputLock() {
        XCTAssertEqual(AppFeature.inputLock.enabledKeys, [UserDefaultsKeys.isLocked])
    }

    func test_enabledKeys_clipboardHistory() {
        XCTAssertEqual(AppFeature.clipboardHistory.enabledKeys, [UserDefaultsKeys.clipboardFeatureEnabled])
    }

    func test_enabledKeys_onDemandFeatures_empty() {
        XCTAssertTrue(AppFeature.quickPhrase.enabledKeys.isEmpty)
        XCTAssertTrue(AppFeature.systemMonitor.enabledKeys.isEmpty)
        XCTAssertTrue(AppFeature.networkDiagnostics.enabledKeys.isEmpty)
        XCTAssertTrue(AppFeature.launchAtLogin.enabledKeys.isEmpty)
    }

    // MARK: - UI 属性测试

    func test_allFeaturesHaveNonEmptySymbolName() {
        for feature in AppFeature.allCases {
            XCTAssertFalse(feature.symbolName.isEmpty,
                         "AppFeature.\(feature.rawValue) 必须有非空 symbolName")
        }
    }

    func test_allFeaturesHaveNonEmptyHubName() {
        for feature in AppFeature.allCases {
            XCTAssertFalse(feature.hubName(in: .en).isEmpty,
                         "AppFeature.\(feature.rawValue) 必须有非空 hubName")
        }
    }

    func test_allFeaturesHaveNonEmptyHubDescription() {
        for feature in AppFeature.allCases {
            XCTAssertFalse(feature.hubDescription(in: .en).isEmpty,
                         "AppFeature.\(feature.rawValue) 必须有非空 hubDescription")
        }
    }

    func test_allGroupsHaveNonEmptyHubTitle() {
        for group in FeatureGroup.allCases {
            XCTAssertFalse(group.hubTitle(in: .en).isEmpty,
                         "FeatureGroup.\(group.rawValue) 必须有非空 hubTitle")
        }
    }

    func test_allPermissionsHaveNonEmptySymbolName() {
        for perm in AppPermission.allCases {
            XCTAssertFalse(perm.symbolName.isEmpty,
                         "AppPermission.\(perm.rawValue) 必须有非空 symbolName")
        }
    }

    func test_allPermissionsHaveNonEmptyHubName() {
        for perm in AppPermission.allCases {
            XCTAssertFalse(perm.hubName(in: .en).isEmpty,
                         "AppPermission.\(perm.rawValue) 必须有非空 hubName")
        }
    }

    func test_allPermissionsHaveNonEmptyHubDescription() {
        for perm in AppPermission.allCases {
            XCTAssertFalse(perm.hubDescription(in: .en).isEmpty,
                         "AppPermission.\(perm.rawValue) 必须有非空 hubDescription")
        }
    }

    func test_inputLockSymbolName() {
        XCTAssertEqual(AppFeature.inputLock.symbolName, "lock.fill")
    }

    func test_clipboardHistorySymbolName() {
        XCTAssertEqual(AppFeature.clipboardHistory.symbolName, "doc.on.clipboard")
    }

    func test_quickPhraseSymbolName() {
        XCTAssertEqual(AppFeature.quickPhrase.symbolName, "text.bubble")
    }

    func test_systemMonitorSymbolName() {
        XCTAssertEqual(AppFeature.systemMonitor.symbolName, "chart.bar")
    }

    func test_networkDiagnosticsSymbolName() {
        XCTAssertEqual(AppFeature.networkDiagnostics.symbolName, "network")
    }

    // MARK: - Network Diagnostics

    func test_networkDiagnostics_catalogContract() {
        XCTAssertEqual(AppFeature.networkDiagnostics.rawValue, "networkDiagnostics")
        XCTAssertEqual(AppFeature.networkDiagnostics.group, .productivity)
        XCTAssertTrue(AppFeature.networkDiagnostics.enabledKeys.isEmpty)
        XCTAssertEqual(AppFeature.networkDiagnostics.possiblePermissions, [])
        XCTAssertEqual(AppFeature.networkDiagnostics.permissions, [])
        XCTAssertEqual(AppFeature.networkDiagnostics.symbolName, "network")
        XCTAssertNil(AppFeature.networkDiagnostics.permissionUsage(for: .accessibility))
        XCTAssertNil(AppFeature.networkDiagnostics.permissionUsage(for: .notifications))
        XCTAssertNil(AppFeature.networkDiagnostics.permissionUsage(for: .fullDiskAccess))
        XCTAssertNil(AppFeature.networkDiagnostics.permissionUsage(for: .inputMonitoring))
        XCTAssertNil(AppFeature.networkDiagnostics.permissionUsage(for: .screenRecording))
        XCTAssertEqual(AppFeature.networkDiagnostics.hubName(in: .en), "Network Diagnostics")
        XCTAssertEqual(AppFeature.networkDiagnostics.hubName(in: .zhHans), "网络诊断")
        XCTAssertFalse(AppFeature.networkDiagnostics.hubDescription(in: .en).isEmpty)
        XCTAssertFalse(AppFeature.networkDiagnostics.hubDescription(in: .zhHans).isEmpty)
        XCTAssertEqual(
            AppFeature.availabilityDefaults[AppFeature.networkDiagnostics.availabilityKey] as? Bool,
            true
        )
    }

    func test_launchAtLoginSymbolName() {
        XCTAssertEqual(AppFeature.launchAtLogin.symbolName, "power")
    }

    func test_featureGroupFeaturesStaticMethod() {
        XCTAssertEqual(FeatureGroup.features(in: .input), [.inputLock])
        XCTAssertEqual(FeatureGroup.features(in: .clipboard), [.clipboardHistory, .quickPhrase])
        XCTAssertEqual(FeatureGroup.features(in: .monitor), [.systemMonitor, .tokenUsage])
        XCTAssertEqual(FeatureGroup.features(in: .system), [.launchAtLogin])
        XCTAssertEqual(FeatureGroup.features(in: .mouse),
                       [.scrollInverter, .smoothScroll, .mouseNavigation, .dockClick])
        XCTAssertEqual(FeatureGroup.features(in: .energy), [.keepAwake])
    }

    // MARK: - Keep Awake

    func test_keepAwake_catalogContract() {
        XCTAssertEqual(AppFeature.keepAwake.rawValue, "keepAwake")
        XCTAssertEqual(AppFeature.keepAwake.group, .energy)
        XCTAssertTrue(AppFeature.keepAwake.enabledKeys.isEmpty)
        XCTAssertEqual(AppFeature.keepAwake.possiblePermissions, [.accessibility, .notifications])
        XCTAssertEqual(AppFeature.keepAwake.permissions, [.accessibility, .notifications])
        XCTAssertEqual(AppFeature.keepAwake.symbolName, "moon.zzz.fill")
        XCTAssertFalse(AppFeature.keepAwake.hubName(in: .en).isEmpty)
        XCTAssertFalse(AppFeature.keepAwake.hubDescription(in: .en).isEmpty)
        XCTAssertFalse(FeatureGroup.energy.hubTitle(in: .en).isEmpty)
        XCTAssertFalse(FeatureGroup.energy.hubTitle(in: .zhHans).isEmpty)
    }

    func test_keepAwake_permissionUsage_isNotRequiredForCoreSession() {
        XCTAssertEqual(
            AppFeature.keepAwake.permissionUsage(for: .accessibility, mouseJiggleEnabled: false),
            .inactive
        )
        XCTAssertEqual(
            AppFeature.keepAwake.permissionUsage(for: .accessibility, mouseJiggleEnabled: true),
            .configured
        )
        XCTAssertEqual(
            AppFeature.keepAwake.permissionUsage(for: .notifications, mouseJiggleEnabled: false),
            .optional
        )
        XCTAssertNil(AppFeature.keepAwake.permissionUsage(for: .fullDiskAccess))
    }

    // MARK: - 鼠标与触控板特性

    func test_mouseFeaturesRequireAccessibility() {
        XCTAssertEqual(AppFeature.scrollInverter.permissions, [.accessibility])
        XCTAssertEqual(AppFeature.smoothScroll.permissions, [.accessibility])
        XCTAssertEqual(AppFeature.mouseNavigation.permissions, [.accessibility])
        XCTAssertEqual(AppFeature.dockClick.permissions, [.accessibility])
    }

    func test_mouseFeaturesEnabledKeys() {
        XCTAssertEqual(AppFeature.scrollInverter.enabledKeys, [UserDefaultsKeys.scrollInverterEnabled])
        XCTAssertEqual(AppFeature.smoothScroll.enabledKeys, [UserDefaultsKeys.smoothScrollEnabled])
        XCTAssertEqual(AppFeature.mouseNavigation.enabledKeys, [UserDefaultsKeys.mouseNavigationEnabled])
        XCTAssertEqual(AppFeature.dockClick.enabledKeys,
                       [UserDefaultsKeys.dockClickMinimize, UserDefaultsKeys.dockClickCycleWindows])
    }

    func test_mouseFeatureSymbolNames() {
        XCTAssertEqual(AppFeature.scrollInverter.symbolName, "arrow.up.arrow.down")
        XCTAssertEqual(AppFeature.smoothScroll.symbolName, "cursorarrow.motionlines")
        XCTAssertEqual(AppFeature.mouseNavigation.symbolName, "arrow.left.arrow.right")
        XCTAssertEqual(AppFeature.dockClick.symbolName, "dock.arrow.down.rectangle")
    }

    func test_mouseGroupTitle() {
        XCTAssertEqual(FeatureGroup.mouse.hubTitle(in: .en), "Mouse & Trackpad")
        XCTAssertEqual(FeatureGroup.mouse.hubTitle(in: .zhHans), "鼠标与触控板")
    }

    func test_shelfFeatureContract() {
        XCTAssertEqual(AppFeature.shelf.group, .productivity)
        XCTAssertEqual(AppFeature.shelf.enabledKeys, [UserDefaultsKeys.shelfEnabled])
        XCTAssertEqual(AppFeature.shelf.permissions, [])
        XCTAssertEqual(AppFeature.shelf.symbolName, "tray.full")
    }

    func test_cleanerFeatureContract() {
        XCTAssertEqual(AppFeature.cleaner.group, .productivity)
        XCTAssertTrue(AppFeature.cleaner.enabledKeys.isEmpty, "工具型特性无 enable 键")
        XCTAssertEqual(AppFeature.cleaner.permissions, [.fullDiskAccess])
        XCTAssertEqual(AppFeature.cleaner.symbolName, "sparkles")
    }

    func test_uninstallerFeatureContract() {
        XCTAssertEqual(AppFeature.uninstaller.group, .productivity)
        XCTAssertTrue(AppFeature.uninstaller.enabledKeys.isEmpty, "工具型特性无 enable 键")
        XCTAssertEqual(AppFeature.uninstaller.permissions, [.fullDiskAccess])
        XCTAssertEqual(AppFeature.uninstaller.symbolName, "trash")
    }

    func test_fullDiskAccessPermissionMetadata() {
        XCTAssertEqual(AppPermission.fullDiskAccess.symbolName, "externaldrive.fill.badge.checkmark")
        // 名称/描述在各语言 Strings 中有对应值
        XCTAssertFalse(AppPermission.fullDiskAccess.hubName(in: .en).isEmpty)
        XCTAssertFalse(AppPermission.fullDiskAccess.hubName(in: .zhHans).isEmpty)
    }

    func test_productivityGroupContainsTools() {
        // productivity 组含 networkDiagnostics、shelf、工具型特性 cleaner/uninstaller/colorPicker/dshWeb、stickyNotes、cleaningMode 与 desktopPet
        XCTAssertEqual(
            FeatureGroup.features(in: .productivity),
            [.networkDiagnostics, .dshWeb, .shelf, .cleaner, .uninstaller, .colorPicker, .stickyNotes, .cleaningMode, .desktopPet]
        )
        XCTAssertTrue(FeatureGroup.features(in: .productivity).contains(.networkDiagnostics))
    }

    func test_providerSwitch_catalogContract() {
        // 独立一级功能，归新 FeatureGroup.ai，不归 .monitor（SPEC 2.1）
        XCTAssertEqual(AppFeature.providerSwitch.group, .ai)
        XCTAssertEqual(
            FeatureGroup.features(in: .ai),
            [.providerSwitch, .promptOptimizer]
        )
        XCTAssertTrue(AppFeature.providerSwitch.enabledKeys.isEmpty)
        XCTAssertTrue(AppFeature.providerSwitch.possiblePermissions.isEmpty)
        XCTAssertEqual(AppFeature.providerSwitch.symbolName, "arrow.triangle.swap")
        XCTAssertEqual(
            AppFeature.providerSwitch.hubName(in: .zhHans),
            Strings.zhHans.featureHubNameProviderSwitch
        )
        XCTAssertFalse(AppFeature.providerSwitch.hubName(in: .zhHans).isEmpty)
        XCTAssertFalse(AppFeature.providerSwitch.hubDescription(in: .zhHans).isEmpty)
        XCTAssertEqual(FeatureGroup.ai.hubTitle(in: .zhHans), Strings.zhHans.featureHubGroupAI)
        XCTAssertEqual(AppFeature.providerSwitch.availabilityKey, "featureAvailable.providerSwitch")
    }

}
