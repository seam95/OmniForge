import Foundation

/// 所有 UI 字符串的类型安全容器。
/// 通过 per-language extension（Strings+English.swift 等）提供各语言翻译。
/// View 通过 `l10n.s.propertyName` 访问，语言切换时自动重渲染。
struct Strings: Equatable {
    // MARK: - App
    let appTitle: String
    let actionUnlock: String
    let actionLock: String
    let actionQuit: String
    let panelSelectSource: String
    // MARK: - Settings
    let settingsLanguage: String
    let settingsSystem: String
    let settingsLaunchAtLogin: String
    let settingsHideDockIcon: String
    let settingsAccessibility: String
    let settingsAccessibilityDescription: String
    let settingsGrantAccess: String
    let settingsDetectedHotkeys: String
    let settingsNoHotkeysDetected: String
    let settingsHotkeysNote: String
    let settingsGeneralSection: String
    let settingsClipboardSection: String
    let settingsClipboardHotkey: String
    let settingsClipboardHotkeyRecording: String
    let settingsClipboardRetentionDays: String
    let settingsClipboardMaxEntries: String
    let settingsDays: String
    let settingsEntries: String
    let settingsTabGeneral: String
    let settingsTabInputMethod: String
    let settingsTabClipboard: String
    let settingsTabMonitor: String
    let settingsTabMenuBar: String
    let settingsTabAlerts: String
    let settingsTabPerformance: String
    let settingsTabShelf: String
    let settingsTabScreenshot: String
    let settingsTabMouse: String
    let settingsTitle: String
    // MARK: - Clipboard
    let clipboardTitle: String
    let clipboardActionPaste: String
    let clipboardSearch: String
    let clipboardEmpty: String
    let clipboardPasteHint: String
    let clipboardPasteUnknown: String
    let clipboardSectionToday: String
    let clipboardSectionYesterday: String
    let clipboardSectionThisWeek: String
    let clipboardSectionLastWeek: String
    let clipboardSectionThisMonth: String
    let clipboardSectionThisYear: String
    let clipboardDetail: String
    let clipboardDetailSource: String
    let clipboardDetailInformation: String
    let clipboardDetailType: String
    let clipboardDetailDimensions: String
    let clipboardDetailSize: String
    let clipboardDetailCharacters: String
    let clipboardDetailCharactersCount: String
    let clipboardDetailWordsCount: String
    let clipboardDetailImageUnknown: String
    let clipboardDetailTime: String
    let clipboardDetailUnavailable: String
    let clipboardDetailRtf: String
    let clipboardFilterAll: String
    let clipboardFilterText: String
    let clipboardFilterImage: String
    let clipboardFilterFile: String
    let clipboardFilterUrl: String
    let clipboardFilterRtf: String
    let clipboardFilterUnknown: String
    // MARK: - Control Center
    let controlcenterTabDashboard: String
    let controlcenterTabSettings: String
    let controlcenterTabAccessibility: String
    let controlcenterTabSystemMonitor: String
    let controlcenterInputLockDescription: String
    let controlcenterInputLockNoSource: String
    let controlcenterClipboardTitle: String
    let controlcenterClipboardEnabled: String
    let controlcenterClipboardDisabled: String
    let controlcenterOpenSettings: String
    let controlcenterTabUtilities: String
    let controlcenterNavMonitor: String
    let controlcenterNavKeepAwake: String
    let controlcenterNavUtilities: String
    let controlcenterEmpty: String
    let runStateStopped: String
    let runStateRunning: String
    let runStateEnabled: String
    let runStateWaitingPermission: String
    let runStateFailed: String
    let actionRetry: String
    let permissionOpenSettings: String
    let utilityCleaner: String
    let utilityUninstaller: String
    let utilityUninstallBusy: String
    let utilityCleanerSubtitle: String
    let utilityUninstallerSubtitle: String
    let utilityColorPickerSubtitle: String
    let utilityNetworkDiagnosticsSubtitle: String
    let utilityDSHWebSubtitle: String
    let toolRetryFailures: String
    let toolSucceeded: String
    let toolFailed: String
    let toolScanFailure: String
    // MARK: - Monitor
    let monitorSettingsTitle: String
    let monitorSettingsEnable: String
    let monitorSettingsRefreshInterval: String
    let monitorSettingsTemperatureUnit: String
    let monitorSettingsCelsius: String
    let monitorSettingsFahrenheit: String
    let monitorPanelSectionsTitle: String
    let monitorSectionSystem: String
    let monitorSectionNetwork: String
    let monitorSectionDisk: String
    let monitorSectionPower: String
    /// 分区配置上移/下移
    let settingsMoveUp: String
    let settingsMoveDown: String
    // 监控面板指标标签
    let monitorMetricCpu: String
    let monitorMetricGpu: String
    let monitorMetricMemory: String
    let monitorMetricCpuTemp: String
    let monitorMetricGpuTemp: String
    let monitorMetricDown: String
    let monitorMetricUp: String
    let monitorMetricTotalDown: String
    let monitorMetricTotalUp: String
    let monitorMetricRead: String
    let monitorMetricWrite: String
    let monitorMetricFree: String
    let monitorMetricBattery: String
    let monitorMetricCharging: String
    let monitorValueYes: String
    let monitorValueNo: String
    let monitorMetricHealth: String
    let monitorMetricCycles: String
    let monitorMetricRemaining: String
    let monitorMetricSystemPower: String
    let monitorMetricBatteryPower: String
    // 监控面板状态文案
    let monitorIssueUnsupported: String
    let monitorIssueFailed: String
    let monitorNoDiskData: String
    let monitorNoPowerData: String
    let monitorProcessLoading: String
    let monitorProcessUsage: String
    let monitorProcessEmpty: String
    // 网速测试
    let monitorSpeedTestStart: String
    let monitorSpeedTestRunning: String
    let monitorSpeedTestFailed: String
    // 监控面板卡片/排行榜文案
    let monitorDeviceFallbackName: String
    let monitorStatusNormal: String
    let monitorStatusIssue: String
    let monitorPreferences: String
    let monitorRefreshAll: String
    let monitorCardStorage: String
    let monitorCardDisk: String
    let monitorCardNetworkTraffic: String
    let monitorCardDiskIO: String
    let monitorCardEnergy: String
    let monitorLiveBadge: String
    let monitorProcessNameHeader: String
    let monitorProcessShareHeader: String
    let monitorRankingTitleCPU: String
    let monitorRankingTitleGPU: String
    let monitorRankingTitleMemory: String
    let monitorRankingTitleNetwork: String
    let monitorRankingTitleEnergy: String
    let monitorFreeLabel: String
    /// Storage card secondary: "of %@" / "共 %@" with total capacity.
    let monitorOfTotal: String
    let monitorSubtitleSeparator: String
    let monitorPressureNormal: String
    let monitorPressureWarning: String
    let monitorPressureCritical: String
    // 重构后卡片 caption/徽章文案
    let monitorCPUSystem: String
    let monitorCPUUser: String
    let monitorUptimePrefix: String
    let monitorPowerSourceAdapter: String
    let monitorPowerSourceOnBattery: String
    let monitorDiskUsed: String
    let monitorCumulativeTotal: String
    let monitorMetricHealthShort: String
    // MARK: - Disk Detail
    let diskSectionTitle: String
    let diskSelect: String
    let diskUsed: String
    let diskFree: String
    let diskInternal: String
    let diskExternal: String
    let diskRead: String
    let diskWrite: String
    let diskThisSession: String
    let diskMeasuring: String
    let diskSMART: String
    let diskSMARTStatus: String
    let diskTotalWritten: String
    let diskTotalRead: String
    let diskTemperature: String
    let diskHealth: String
    let diskPowerCycles: String
    let diskPowerOnHours: String
    let diskSMARTUnavailable: String
    let diskUnsupported: String
    let diskProtection: String
    let diskEject: String
    let diskEjectAll: String
    let diskEjecting: String
    let diskReadyToRemove: String
    let diskEjectFailed: String
    let diskNoExternal: String
    let diskProtectionCaption: String
    let diskTools: String
    let diskOpenInFinder: String
    let diskStorageSettings: String
    let diskUsage: String
    let diskActivity: String
    let diskNoDisks: String
    let diskFileSystemUnsupported: String
    // MARK: - Menu Bar
    let menubarSettingsEnable: String
    let menubarSettingsTitle: String
    let menubarSettingsPreview: String
    let menubarSettingsSpacing: String
    let menubarSettingsCompact: String
    let menubarSettingsStandard: String
    let menubarSettingsMemoryStyle: String
    let menubarSettingsMemoryPercent: String
    let menubarSettingsMemoryUsed: String
    let menubarSettingsMemoryPressure: String
    let menubarSettingsNetworkUploadFirst: String
    let menubarSettingsCombineTemperatures: String
    let menubarSettingsSeparateStatusItems: String
    let menubarSettingsHideMainIcon: String
    let menubarMetricCPU: String
    let menubarMetricGPU: String
    let menubarMetricMemory: String
    let menubarMetricNetwork: String
    let menubarMetricDisk: String
    let menubarMetricPower: String
    let menubarMetricBattery: String
    let menubarMetricCPUTemperature: String
    let menubarMetricGPUTemperature: String
    let menubarMetricBatteryTemperature: String
    let menubarMetricPeripheralBattery: String
    let menubarMetricDate: String
    let settingsInputMethodSection: String
    // MARK: - Alerts
    let alertsSettingsTitle: String
    let alertsCpu: String
    let alertsCpuTemperature: String
    let alertsMemory: String
    let alertsDisk: String
    let alertsBattery: String
    let alertsNotificationTitle: String
    let alertsBodyCpu: String
    let alertsBodyCpuTemperature: String
    let alertsBodyMemory: String
    let alertsBodyDisk: String
    let alertsBodyBattery: String
    // MARK: - Quick Phrase
    let quickphraseSearchPlaceholder: String
    // MARK: - Menu
    let menuAbout: String
    let menuSettings: String
    let menuHide: String
    let menuHideOthers: String
    let menuShowAll: String
    let menuQuit: String
    let menuEdit: String
    let menuUndo: String
    let menuRedo: String
    let menuCut: String
    let menuCopy: String
    let menuPaste: String
    let menuSelectAll: String
    let menuWindow: String
    let menuMinimize: String
    let menuZoom: String
    let menuClose: String

    // MARK: - Feature Hub
    let settingsTabFeatures: String
    let settingsFeatureEnabled: String
    let settingsFeatureDisabled: String
    let featureHubIntro: String
    let featureHubTabFeatures: String
    let featureHubTabPermissions: String
    let featureHubActiveCount: String
    let featureHubInstallAll: String
    let featureHubUninstallAll: String
    let featureHubInstall: String
    let featureHubUninstall: String
    let featureHubRestartNote: String
    let featureHubRestartButton: String
    let featureHubNameInputLock: String
    let featureHubNameClipboardHistory: String
    let featureHubNameQuickPhrase: String
    let featureHubNameSystemMonitor: String
    let featureHubNameNetworkDiagnostics: String
    let featureHubNameShelf: String
    let featureHubNameLaunchAtLogin: String
    let featureHubNameScrollInverter: String
    let featureHubNameSmoothScroll: String
    let featureHubNameMouseNavigation: String
    let featureHubNameDockClick: String
    let featureHubNameKeepAwake: String
    let featureHubNameScreenshot: String
    let featureHubNameDSHWeb: String
    let featureHubDescInputLock: String
    let featureHubDescClipboardHistory: String
    let featureHubDescQuickPhrase: String
    let featureHubDescSystemMonitor: String
    let featureHubDescNetworkDiagnostics: String
    let featureHubDescShelf: String
    let featureHubDescLaunchAtLogin: String
    let featureHubDescScrollInverter: String
    let featureHubDescSmoothScroll: String
    let featureHubDescMouseNavigation: String
    let featureHubDescDockClick: String
    let featureHubDescKeepAwake: String
    let featureHubDescScreenshot: String
    let featureHubDescDSHWeb: String
    let featureHubGroupInput: String
    let featureHubGroupClipboard: String
    let featureHubGroupMonitor: String
    let featureHubGroupProductivity: String
    let featureHubGroupSystem: String
    let featureHubGroupMouse: String
    let featureHubGroupEnergy: String
    let featureHubGroupCapture: String
    let featureHubPermissionsIntro: String
    let featureHubPermStatusGranted: String
    let featureHubPermStatusMissing: String
    let featureHubPermUsedBy: String
    let featureHubPermUsedByNone: String
    let featureHubPermUsageRequired: String
    let featureHubPermUsageConfigured: String
    let featureHubPermUsageOptional: String
    let featureHubPermUsageInactive: String
    let featureHubPermOpenSettings: String
    let featureHubPermRefresh: String
    let featureHubPermRecoveryHint: String
    let featureHubPermSignature: String
    let featureHubPermNameAccessibility: String
    let featureHubPermNameInputMonitoring: String
    let featureHubPermNameNotifications: String
    let featureHubPermDescAccessibility: String
    let featureHubPermDescInputMonitoring: String
    let featureHubPermDescNotifications: String
    let featureHubPermNameFullDiskAccess: String
    let featureHubPermDescFullDiskAccess: String
    let featureHubPermNameScreenRecording: String
    let featureHubPermDescScreenRecording: String

    // MARK: - Onboarding
    let onboardingWelcomeTitle: String
    let onboardingWelcomeBody: String
    let onboardingNext: String
    let onboardingBack: String
    let onboardingFinish: String
    let onboardingSkip: String
    let onboardingPermissionsTitle: String
    let onboardingPermissionsBody: String
    let onboardingPermissionAccessibility: String
    let onboardingPermissionAccessibilityDescription: String
    let onboardingPermissionNotifications: String
    let onboardingPermissionNotificationsDescription: String
    let onboardingGrantPermission: String
    let onboardingPermissionGranted: String
    let onboardingRecheck: String
    let onboardingPermissionHint: String
    let onboardingFeaturesTitle: String
    let onboardingFeaturesBody: String
    let onboardingFeatureInputLockTitle: String
    let onboardingFeatureInputLockDescription: String
    let onboardingFeatureClipboardHistoryTitle: String
    let onboardingFeatureClipboardHistoryDescription: String
    let onboardingFeatureQuickPhraseTitle: String
    let onboardingFeatureQuickPhraseDescription: String
    let onboardingFeatureSystemMonitorTitle: String
    let onboardingFeatureSystemMonitorDescription: String
    let onboardingFeatureShelfTitle: String
    let onboardingFeatureShelfDescription: String
    let onboardingFeatureLaunchAtLoginTitle: String
    let onboardingFeatureLaunchAtLoginDescription: String
    let onboardingDoneTitle: String
    let onboardingDoneHint: String
    // MARK: - What's New
    let whatsNewTitle: String
    let whatsNewClose: String

    // MARK: - Shelf
    let shelfName: String
    let shelfEnable: String
    let shelfEnableCaption: String
    let shelfHowTitle: String
    let shelfStep1: String
    let shelfStep2: String
    let shelfStep3: String
    let shelfShakeToggle: String
    let shelfShakeCaption: String
    let shelfDropZoneToggle: String
    let shelfDropZoneCaption: String
    let shelfDropZoneLabel: String
    let shelfCollapse: String
    let shelfBehaviorTitle: String
    let shelfCloseAfterDrop: String
    let shelfCloseAfterDropCaption: String
    let shelfRemoveAfterDrop: String
    let shelfRemoveAfterDropCaption: String
    let shelfExclusionsTitle: String
    let shelfExclusionsEmpty: String
    let shelfExclusionsCaption: String
    let shelfPin: String
    let shelfUnpin: String
    let shelfHotkeyLabel: String
    let shelfOpenNow: String
    let shelfNoPermission: String
    let shelfMenuItem: String
    let shelfTitle: String
    let shelfEmpty: String
    let shelfClearAll: String
    let shelfRemoveSelected: String
    let shelfSelectedFormat: String
    let shelfHint: String
    let shelfItemImage: String
    let shelfActionOpen: String
    let shelfActionOpenWith: String
    let shelfActionAirDrop: String
    let shelfActionReveal: String
    let shelfShortcutToggle: String
    let shelfFeatureUnavailable: String
    let shelfAddApp: String
    let shelfAppPickerTitle: String
    let shelfAppPickerSearch: String
    let shelfAppPickerCancel: String
    let shelfAppPickerEmpty: String

    // MARK: - Uninstaller
    let uninstallerName: String
    let uninstallerEnableCaption: String
    let uninstallerDropTitle: String
    let uninstallerDropSubtitle: String
    let uninstallerChoose: String
    let uninstallerPickerTitle: String
    let uninstallerPickerSearch: String
    let uninstallerPickerEmpty: String
    let uninstallerEmptyNote: String
    let uninstallerFDANote: String
    let uninstallerFDAGrant: String
    let uninstallerFDAHint: String
    let uninstallerFDARelaunch: String
    let uninstallerScanning: String
    let uninstallerRemoving: String
    let uninstallerFoundTitle: String
    let uninstallerSelectedFormat: String   // + selected, total
    let uninstallerRemove: String
    let uninstallerCancel: String
    let uninstallerDoneTitle: String
    let uninstallerFreedFormat: String      // + size string
    let uninstallerSomeFailed: String
    let uninstallerAnother: String
    let uninstallerCatApp: String
    let uninstallerCatSupport: String
    let uninstallerCatCaches: String
    let uninstallerCatPreferences: String
    let uninstallerCatContainers: String
    let uninstallerCatLogs: String
    let uninstallerCatState: String
    let uninstallerCatOther: String

    // MARK: - Color Picker
    let colorPickerName: String
    let colorPickerDescription: String
    let colorPickerIntroTitle: String
    let colorPickerIntroCaption: String
    let colorPickerStart: String
    let colorPickerInProgress: String
    let colorPickerPickAgain: String
    let colorPickerFormatHex: String
    let colorPickerFormatRGB: String
    let colorPickerFormatHSL: String

    // MARK: - Network Diagnostics
    let networkDiagnosticsSegmentNetwork: String
    let networkDiagnosticsSegmentPorts: String
    let networkDiagnosticsRefresh: String
    let networkDiagnosticsCopy: String
    let networkDiagnosticsValueUnavailable: String
    // Network segment
    let networkDiagnosticsHostSection: String
    let networkDiagnosticsHostname: String
    let networkDiagnosticsInterfacesSection: String
    let networkDiagnosticsInterfaceIPv4: String
    let networkDiagnosticsInterfaceIPv6: String
    let networkDiagnosticsInterfaceMAC: String
    let networkDiagnosticsRouteSection: String
    let networkDiagnosticsGateway: String
    let networkDiagnosticsRouteInterface: String
    let networkDiagnosticsDNSSection: String
    let networkDiagnosticsDNSServers: String
    let networkDiagnosticsPublicIPSection: String
    let networkDiagnosticsPublicIPv4: String
    let networkDiagnosticsPublicIPv6: String
    let networkDiagnosticsPublicIPLoading: String
    let networkDiagnosticsNetworkEmpty: String
    let networkDiagnosticsNetworkLoadFailed: String
    // Port segment
    let networkDiagnosticsSearchPlaceholder: String
    let networkDiagnosticsScopeListen: String
    let networkDiagnosticsScopeAll: String
    let networkDiagnosticsColumnProtocol: String
    let networkDiagnosticsColumnLocalPort: String
    let networkDiagnosticsColumnProcess: String
    let networkDiagnosticsColumnStatus: String
    let networkDiagnosticsPortsEmpty: String
    let networkDiagnosticsPortsEmptyListen: String
    let networkDiagnosticsPortsLoadFailed: String
    let networkDiagnosticsPortsLoadFailedBanner: String
    let networkDiagnosticsPartialPermissionBanner: String
    let networkDiagnosticsCopyTerminalCommand: String
    let networkDiagnosticsShowCommand: String
    let networkDiagnosticsHideCommand: String
    // Row actions
    let networkDiagnosticsCopyHostPort: String
    let networkDiagnosticsCopyPID: String
    let networkDiagnosticsCopyProcessName: String
    let networkDiagnosticsCopySudoKill: String
    let networkDiagnosticsCopySudoKill9: String
    let networkDiagnosticsTerminateProcess: String
    // Terminate flow
    let networkDiagnosticsTerminateTitle: String
    let networkDiagnosticsTerminateMessageFormat: String
    let networkDiagnosticsTerminateConfirm: String
    let networkDiagnosticsTerminateCancel: String
    let networkDiagnosticsTerminateSuccess: String
    let networkDiagnosticsAlertOK: String
    let networkDiagnosticsProcessGone: String
    let networkDiagnosticsForceTerminateTitle: String
    let networkDiagnosticsForceTerminateMessage: String
    let networkDiagnosticsForceTerminateConfirm: String
    let networkDiagnosticsTerminateFailed: String
    let networkDiagnosticsProtectedProcess: String
    let networkDiagnosticsUnknownProcess: String

    // MARK: - DSH Web
    let dshWebStart: String
    let dshWebStop: String
    let dshWebRestart: String
    let dshWebOpenBrowser: String
    let dshWebStateRunning: String
    let dshWebStateStopped: String
    let dshWebStateStarting: String
    let dshWebStateStopping: String
    let dshWebStateFailed: String     // + failed reason
    let dshWebPortOccupied: String
    let dshWebPortOccupiedFormat: String
    let dshWebStartTimeout: String
    let dshWebLaunchFailed: String
    let dshWebLogTitle: String
    let dshWebLogEmpty: String
    let dshWebCopyLog: String
    let dshWebClearLog: String
    let dshWebPort: String
    let dshWebRefresh: String
    let dshWebServicesTitle: String
    let dshWebExternalServicesTitle: String
    let dshWebNoServices: String
    let dshWebManagedService: String
    let dshWebExternalService: String
    let dshWebStopExternalTitle: String
    let dshWebStopExternalMessageFormat: String
    let dshWebCancel: String
    let networkDiagnosticsProcessPIDFormat: String

    // MARK: - Cleaner
    let cleanerName: String
    let cleanerIntroTitle: String
    let cleanerIntroCaption: String
    let cleanerScan: String
    let cleanerScanning: String
    let cleanerScanProgressFormat: String
    let cleanerCleaning: String
    let cleanerCatLeftovers: String
    let cleanerCatLoginItems: String
    let cleanerCatCaches: String
    let cleanerCatLogs: String
    let cleanerCatDeveloper: String
    let cleanerCatTrash: String
    let cleanerLeftoversNote: String
    let cleanerLoginItemsNote: String
    let cleanerTrashNote: String
    let cleanerCatDeviceBackups: String
    let cleanerDeviceBackupsCaption: String
    let cleanerNothingFound: String
    let cleanerClean: String
    let cleanerDoneNote: String
    let cleanerAgain: String
    let cleanerRevealInFinder: String
    let cleanerSafeSection: String
    let cleanerOptionalSection: String
    let cleanerCatOtherCaches: String
    let cleanerCachesCaption: String
    let cleanerLogsCaption: String
    let cleanerDeveloperCaption: String
    let cleanerLoginItemsCaption: String
    let cleanerLeftoversCaption: String
    let cleanerOtherCachesCaption: String
    let cleanerCleanSizeFormat: String      // + size string
    let cleanerScheduleTitle: String
    let cleanerScheduleOff: String
    let cleanerScheduleDaily: String
    let cleanerScheduleWeekly: String
    let cleanerScheduleCaption: String
    let cleanerScheduleLastFormat: String   // + size string
    let cleanerAutoNotificationFormat: String  // + size string
    let cleanerScheduleNextFormat: String   // + relative date and time
    let cleanerScheduleRanFormat: String    // + relative date and time
    let cleanerScheduleNotifyToggle: String
    let cleanerNotifDenied: String
    let cleanerNotifOpenSettings: String
    // MARK: - Mouse & Trackpad
    let scrollSection: String
    let invertMouseScroll: String
    let invertMouseScrollCaption: String
    let scrollTrackpadNote: String
    let scrollActiveNow: String
    let smoothScrollName: String
    let smoothScrollCaption: String
    let smoothScrollStepLabel: String
    let mouseNavigationSection: String
    let mouseNavigationEnable: String
    let mouseNavigationCaption: String
    let mouseNavigationActiveNow: String
    let dockClickSection: String
    let dockClickMinimize: String
    let dockClickMinimizeCaption: String
    let dockClickCycleWindows: String
    let dockClickCycleWindowsCaption: String
    let permissionRequired: String

    // MARK: - Keep Awake
    let keepAwakeTitle: String
    let keepAwakeDurationLabel: String
    let keepAwakeDurationNever: String
    let keepAwakeDuration15m: String
    let keepAwakeDuration1h: String
    let keepAwakeDuration4h: String
    let keepAwakeClamshellTitle: String
    let keepAwakeClamshellSubtitle: String
    let keepAwakeClamshellFootnote: String
    let keepAwakeStatusCurrentPrefix: String
    let keepAwakeOptionsSection: String
    let keepAwakeRemainingLabel: String
    let keepAwakeEndsAtLabel: String
    let keepAwakeOpenSettingsHint: String
    let keepAwakeClamshellCaption: String
    let keepAwakeStart: String
    let keepAwakeStop: String
    let keepAwakeRetryCleanup: String
    let keepAwakeUnavailable: String
    let keepAwakeStatusFeatureUnavailable: String
    let keepAwakeStatusWaitingRecovery: String
    let keepAwakeStatusNormalSleep: String
    let keepAwakeStatusNotActiveWithError: String
    let keepAwakeStatusStarting: String
    let keepAwakeStatusActiveTimed: String
    let keepAwakeStatusActiveIndefinite: String
    let keepAwakeStatusStopping: String
    let keepAwakeStatusCleanupRequired: String
    let keepAwakeClamshellChecking: String
    let keepAwakeClamshellAuthorizing: String
    let keepAwakeClamshellEnabling: String
    let keepAwakeClamshellActive: String
    let keepAwakeClamshellRestoring: String
    let keepAwakeClamshellConflict: String
    let keepAwakeClamshellFailed: String
    let keepAwakeRecoveryCheckingTitle: String
    let keepAwakeRecoveryCheckingDetail: String
    let keepAwakeRecoveryRestoringTitle: String
    let keepAwakeRecoveryRestoringDetail: String
    let keepAwakeRecoveryCleanupTitle: String
    let keepAwakeRecoveryConflictTitle: String
    let keepAwakeRetry: String
    let keepAwakeMenuStartDefault: String
    let keepAwakeMenuRetryLastStart: String
    let keepAwakeMenuStartDuration: String
    let keepAwakeMenuProcessing: String
    let keepAwakeMenuStop: String
    let keepAwakeMenuRetryCleanup: String
    let keepAwakeMenuOpenSettings: String
    let keepAwakeClamshellAction: String
    let keepAwakeMenuQuit: String
    let keepAwakeTooltipInactive: String
    let keepAwakeTooltipInactiveWithError: String
    let keepAwakeTooltipActivating: String
    let keepAwakeTooltipDeactivating: String
    let keepAwakeTooltipActiveTimed: String
    let keepAwakeTooltipActiveIndefinite: String
    let keepAwakeTooltipCleanupRequired: String
    let keepAwakeNotificationTitle: String
    let keepAwakeAuthDisclosureTitle: String
    let keepAwakeAuthDisclosureBody: String
    let keepAwakeAuthContinue: String
    let keepAwakeAuthRemoveTitle: String
    let keepAwakeAuthRemoveBody: String
    let keepAwakeAuthRemove: String
    let keepAwakeAuthCancel: String
    // 设置页表单
    let keepAwakeSectionSession: String
    let keepAwakeDefaultDuration: String
    let keepAwakeDurationIndefinite: String
    let keepAwakeDurationMinutesFormat: String
    let keepAwakeDurationHoursFormat: String
    let keepAwakeAutoStart: String
    let keepAwakeSectionBattery: String
    let keepAwakeBatteryThreshold: String
    let keepAwakeBatteryOff: String
    let keepAwakeBatteryPercentFormat: String
    let keepAwakeBatteryCaption: String
    let keepAwakeSectionMenuBar: String
    let keepAwakeShowCountdown: String
    let keepAwakeSectionShortcut: String
    let keepAwakeEnableShortcut: String
    let keepAwakeHotkeyManagerMissing: String
    let keepAwakeRecord: String
    let keepAwakeCancelRecording: String
    let keepAwakeSectionPointer: String
    let keepAwakeEnableJiggle: String
    let keepAwakeJiggleInterval: String
    let keepAwakeJiggleCaption: String
    let keepAwakeRequestAccessibility: String
    let keepAwakeSectionClamshell: String
    let keepAwakePreferClamshell: String
    let keepAwakeCapabilityPrefix: String
    let keepAwakeCapabilityChecking: String
    let keepAwakeCapabilityUnsupportedFormat: String
    let keepAwakeCapabilityNeedsAuth: String
    let keepAwakeCapabilityReady: String
    let keepAwakeCapabilityConflictFormat: String
    let keepAwakeCapabilityInvalidFormat: String
    let keepAwakeConfigureAuth: String
    let keepAwakeRemoveAuth: String
    let keepAwakeRefreshStatus: String
    let keepAwakeSectionDiagnostics: String
    let keepAwakeDiagSessionFormat: String
    let keepAwakeDiagClamshellFormat: String
    let keepAwakeDiagErrorFormat: String
    let keepAwakeDiagManagerMissing: String
    let keepAwakeDiagRecoveryFormat: String
    let keepAwakeRecoveryIdle: String
    let keepAwakeRecoveryRecovered: String
    // 授权结果与错误摘要
    let keepAwakeAuthInstallSuccess: String
    let keepAwakeAuthRemoveSuccess: String
    let keepAwakeAuthManagerMissingInstall: String
    let keepAwakeAuthNoRemoveEntry: String
    let keepAwakeErrCancelled: String
    let keepAwakeErrSudoersFormat: String
    let keepAwakeErrRemovalFormat: String
    let keepAwakeErrBusy: String
    let keepAwakeErrClamshellUnsupportedFormat: String
    // 通知 body
    let keepAwakeNotifDurationElapsed: String
    let keepAwakeNotifLowBattery: String
    let keepAwakeNotifCleanupDuration: String
    let keepAwakeNotifCleanupLowBattery: String
    // Hub
    let featureHubRetryUninstall: String
    let featureHubUninstallFailedFormat: String

    // MARK: - Screenshot
    let screenshotEnable: String
    let screenshotEnableCaption: String
    let screenshotPermissionSection: String
    let screenshotPermissionCaption: String
    let screenshotRequestPermission: String
    let screenshotHotkeysSection: String
    let screenshotHotkeyAllInOne: String
    let screenshotHotkeyCopy: String
    let screenshotHotkeyPin: String
    let screenshotHotkeyFullscreen: String
    let screenshotHotkeyRecord: String
    let screenshotOutputSection: String
    let screenshotSaveDirectory: String
    let screenshotChooseDirectory: String
    let screenshotPermissionDenied: String
    let screenshotHotkeyIgnoredNotListening: String
    let screenshotHotkeyIgnoredUnavailable: String
    // Recording
    let recordingSection: String
    let recordingSaveDirectory: String
    let recordingChooseDirectory: String
    let recordingFormatPreference: String
    let recordingFormatManual: String
    let recordingFormatMP4: String
    let recordingFormatGIF: String
    let recordingFormatLabel: String
    let recordingFormatChoiceTitle: String
    let recordingFormatChoiceMessage: String
    let recordingSavePrompt: String
    let recordingCancelPrompt: String
    let recordingStop: String
    let recordingPause: String
    let recordingResume: String
    let recordingCancelled: String
    let recordingExportingGIF: String
    let recordingSavedFormat: String
    let recordingFailedFormat: String
    // 主菜单 / 托盘（T14）
    let screenshotMenuTitle: String
    let pinnedMenuTitle: String
    let pinnedMenuEmpty: String
    let pinnedMenuCopy: String
    let pinnedMenuSave: String
    let pinnedMenuEnableClickThrough: String
    let pinnedMenuDisableClickThrough: String
    let pinnedMenuLock: String
    let pinnedMenuUnlock: String
    let pinnedMenuClose: String
    let pinnedMenuCloseAll: String
    let pinnedMenuActionFailedFormat: String
    // 会话可见错误 / 遮罩 / 滚动 HUD（T14 校对）
    let screenshotSessionAlreadyActive: String
    let screenshotTargetDisplayUnavailable: String
    let screenshotModeNotImplementedFormat: String
    let screenshotCaptureFailedFormat: String
    let screenshotInvalidResultFormat: String
    let screenshotInvalidSelectionFormat: String
    let screenshotPipelineFailedFormat: String

    // MARK: - Element Detection
    let screenshotElementRoleWindow: String
    let screenshotElementRoleButton: String
    let screenshotElementRoleMenu: String
    let screenshotElementRoleMenuItem: String
    let screenshotElementRoleTextField: String
    let screenshotElementRoleSearchField: String
    let screenshotElementRoleTab: String
    let screenshotElementRoleCheckbox: String
    let screenshotElementRoleRadioButton: String
    let screenshotElementRoleSlider: String
    let screenshotElementRoleListItem: String
    let screenshotElementRoleCell: String
    let screenshotElementRoleToolbarItem: String
    let screenshotElementRoleGroup: String
    let screenshotElementRoleScrollArea: String
    let screenshotElementRoleImage: String
    let screenshotElementRoleUnknown: String
    let screenshotElementAccessibilityPermissionMissing: String
    let screenshotElementTargetUnavailable: String
    let screenshotElementDetectionFailedFormat: String

    // MARK: - Screenshot settings (T15 SPEC 3.11 / 3.5)
    let screenshotFileNamePrefixLabel: String
    let screenshotFileNamePrefixCaption: String
    let screenshotFileNamePrefixInvalid: String
    let screenshotCustomPresetsSection: String
    let screenshotCustomPresetsCaption: String
    let screenshotPresetAspectWidth: String
    let screenshotPresetAspectHeight: String
    let screenshotPresetAddAspect: String
    let screenshotPresetFixedWidth: String
    let screenshotPresetFixedHeight: String
    let screenshotPresetAddFixed: String
    let screenshotPresetRemove: String
    let screenshotPresetInvalidInput: String
    // Pin 上下文菜单（T15 L10n 收口，原硬编码中文）
    let screenshotPinMenuCopy: String
    let screenshotPinMenuSave: String
    let screenshotPinMenuLock: String
    let screenshotPinMenuUnlock: String
    let screenshotPinMenuClickThrough: String
    let screenshotPinMenuDisableClickThrough: String
    let screenshotPinMenuOpacity: String
    let screenshotPinMenuClose: String
    // 区域选区 HUD 显示（T15 L10n 收口，原硬编码）
    let screenshotOverlayPresetFree: String
    let screenshotOverlayFixedExceedsFormat: String
    let screenshotOverlayFixedDoesNotFit: String

    // MARK: - Annotation Editor
    let annotationWindowTitle: String
    let annotationToolSelect: String
    let annotationToolArrow: String
    let annotationToolLine: String
    let annotationToolRectangle: String
    let annotationToolEllipse: String
    let annotationToolText: String
    let annotationToolFreehand: String
    let annotationToolMosaic: String
    let annotationToolBlur: String
    let annotationToolRedaction: String
    /// 遮挡模式：像素化（pixelate）
    let annotationRedactionModePixelate: String
    /// 遮挡模式：模糊
    let annotationRedactionModeBlur: String
    /// 遮挡模式：纯色块
    let annotationRedactionModeSolid: String
    let annotationToolHighlighter: String
    let annotationToolCounter: String
    let annotationToolCrop: String
    let annotationCropHint: String
    let annotationCropConfirm: String
    let annotationCropCancel: String
    let annotationCropClear: String
    /// 裁剪页：比例预设菜单标题
    let annotationCropPreset: String
    let annotationCropPresetFreeform: String
    let annotationCropPresetOriginal: String
    let annotationCropPresetSquare: String
    let annotationCropPreset4x3: String
    let annotationCropPreset3x2: String
    let annotationCropPreset16x9: String
    /// 裁剪页：边缘吸附开关
    let annotationCropSnap: String
    let annotationCropSnapHelp: String
    let annotationCropWidth: String
    let annotationCropHeight: String
    /// 非法裁剪矩形（确认失败，不静默）
    let annotationCropErrorInvalid: String
    /// 裁剪页：顺时针旋转 90°
    let annotationCropRotate: String
    /// 裁剪页：水平翻转
    let annotationCropFlipHorizontal: String
    /// 裁剪页：垂直翻转
    let annotationCropFlipVertical: String
    /// 有标注对象时禁用旋转/翻转的说明
    let annotationCropTransformDisabledHelp: String
    let annotationBeautifyEnabled: String
    let annotationBeautifyBackground: String
    let annotationBeautifyBackgroundSolid: String
    let annotationBeautifyBackgroundBlur: String
    let annotationBeautifySolidColor: String
    let annotationBeautifyPadding: String
    let annotationBeautifyCornerRadius: String
    let annotationBeautifyShadow: String
    let annotationBeautifyShadowIntensity: String
    let annotationStyleStroke: String
    let annotationStyleFill: String
    let annotationStyleFillColor: String
    let annotationStyleLineWidth: String
    let annotationStyleLineDash: String
    let annotationStyleFontSize: String
    /// 文字效果：背景填充（Fill）
    let annotationTextFill: String
    /// 文字效果：框描边（Outline）
    let annotationTextOutline: String
    /// 文字效果：字形描边（Trace）
    let annotationTextTrace: String
    /// 色板：自定义色（打开系统色板）
    let annotationColorCustom: String
    /// 色板：屏幕取色
    let annotationColorEyedropper: String
    /// 色板：复制当前 HEX
    let annotationColorCopyHex: String
    let annotationLineDashSolid: String
    let annotationLineDashDashed: String
    let annotationLineDashDotted: String
    let annotationActionCopy: String
    let annotationActionSave: String
    let annotationActionPin: String
    let annotationActionDrag: String
    /// 工具栏「移动选区」拖动手柄提示。
    let tipMoveSelection: String
    /// 工具栏长截图按钮提示。
    let tipScrollCapture: String
    /// 工具栏录屏按钮提示。
    let tipRecord: String
    /// 长截图自动滚动模式。
    let scrollCaptureAutoScroll: String
    /// 长截图手动滚动模式。
    let scrollCaptureManualScroll: String
    /// 自动滚动时提示（按任意键结束）。
    let scrollCaptureHint: String
    /// 手动滚动时提示。
    let scrollCaptureManualHint: String
    /// 缺少辅助功能权限时的提示。
    let autoScrollPermissionNeeded: String
    /// 进入长截图裁剪模式提示。
    let cropLongScreenshotHint: String
    /// 长截图合并完成提示。
    let mergedLongScreenshot: String
    /// 长截图裁剪确认按钮提示。
    let tipScrollCropConfirm: String
    let annotationZoomIn: String
    let annotationZoomOut: String
    let annotationZoomFit: String
    let annotationStatusCopied: String
    let annotationStatusSaved: String
    let annotationStatusSavedFormat: String
    let annotationStatusPinned: String
    let annotationStatusDragReady: String
    let annotationErrorNoImage: String
    let annotationErrorNoResultMetadata: String
    let annotationErrorPinNotWired: String
    let annotationErrorDragNotWired: String
    let annotationErrorRenderFormat: String
    let annotationErrorPipelineFormat: String
    let annotationCloseUnsavedTitle: String
    let annotationCloseUnsavedMessage: String
    let annotationCloseDiscard: String
    let annotationCloseCancel: String
    // Inline annotation (T10)
    let inlineAnnotationFinish: String
    let inlineAnnotationCancel: String
    let inlineAnnotationErrorMissingSelection: String
    let inlineAnnotationErrorModeNotRegion: String
    let inlineAnnotationErrorScreenInvalid: String
    let inlineAnnotationErrorEmptyFrame: String
    let inlineAnnotationErrorInvalidImage: String
    let inlineAnnotationErrorSelectionImageSizeMismatch: String
    let inlineAnnotationErrorPresenterUnavailable: String
    // All-in-One workbench toolbar (A4)
    let allInOneToolbarComplete: String
    let allInOneToolbarCopy: String
    let allInOneToolbarOCR: String
    let allInOneToolbarFullscreen: String
    let allInOneToolbarWindow: String
    let allInOneToolbarScrolling: String
    let allInOneToolbarCancel: String
    // Capture annotation lightweight workbench (Snipaste-style)
    let captureAnnotationToolShape: String
    let captureAnnotationToolLine: String
    let captureAnnotationToolPencil: String
    let captureAnnotationToolHighlighter: String
    let captureAnnotationToolMosaic: String
    let captureAnnotationToolText: String
    let captureAnnotationToolEraser: String
    let captureAnnotationActionUndo: String
    let captureAnnotationActionRedo: String
    let captureAnnotationActionCancel: String
    let captureAnnotationActionPin: String
    let captureAnnotationActionSave: String
    let captureAnnotationActionCopy: String
    let captureAnnotationShapeFilledRect: String
    let captureAnnotationShapeHollowRect: String
    let captureAnnotationShapeEllipse: String
    let captureAnnotationLineStraight: String
    let captureAnnotationLineArrow: String
    let captureAnnotationBrushRound: String
    let captureAnnotationBrushSquare: String
    let captureAnnotationMosaicPixelate: String
    let captureAnnotationOptionColor: String
    let captureAnnotationOptionSize: String
    let captureAnnotationOptionMosaicIntensity: String
    let captureAnnotationOptionBold: String
    let captureAnnotationOptionItalic: String
    let captureAnnotationOptionFont: String
    let captureAnnotationErrorCopy: String
    let captureAnnotationErrorSave: String
    let captureAnnotationErrorPin: String
    let captureAnnotationErrorFreeze: String
    // MARK: - Token Usage
    let featureHubNameTokenUsage: String
    let featureHubDescTokenUsage: String
    let controlcenterTabTokenUsage: String
    let controlcenterNavTokenUsage: String
    let settingsTabTokenUsage: String
    let tokenSettingsCaption: String
    let tokenEmptyHint: String
    let tokenReauthHint: String
    let tokenRefresh: String
    let tokenProviderAll: String
    let tokenWindowSession5h: String
    let tokenWindowWeekly: String
    let tokenWindowMonthly: String
    let tokenWindowCredits: String
    let tokenWindowCreditsShort: String
    let tokenWindowWeeklyShort: String
    let tokenWindowPlanShort: String
    let tokenWindowAutoShort: String
    let tokenStatusNormal: String
    let tokenStatusApproaching: String
    let tokenStatusExceeded: String
    let tokenStatusReauth: String
    let tokenStatusRateLimited: String
    let tokenStatusStale: String
    let tokenErrorNetwork: String
    let tokenErrorTransient: String
    let tokenErrorNotRunning: String
    let tokenRateLimitedCaptionFormat: String
    let tokenErrorRetryableHint: String
    let tokenErrorNotRunningHint: String
    /// 未运行 + 无缓存可显示：点名 provider（如「Antigravity 未运行 · 启动后自动更新」）。
    let tokenErrorNotRunningNamedFormat: String
    /// 未运行 + 展示 last-good 缓存：点名 provider 并附缓存采集时间。
    let tokenErrorNotRunningCachedFormat: String
    let tokenBackfilling: String
    let tokenCreditsRemainingFormat: String
    let tokenResetInApproxFormat: String
    let tokenPaceOver: String
    let tokenPaceProjectedFormat: String
    let tokenCreditCaption: String
    let tokenResetBankEntryTitleFormat: String
    let tokenResetBankEntryFormat: String
    let tokenResetBankCountOnlyFormat: String
    let tokenUpdatedJustNow: String
    let tokenUpdatedMinutesFormat: String
    let tokenUpdatedHoursFormat: String
    let tokenSourceOfficial: String
    let tokenFooterFormat: String
    let tokenUsageLocalFormat: String
    let tokenSummaryToday: String
    let tokenSummarySevenDays: String
    let tokenSummaryThirtyDays: String
    let tokenSummaryTotal: String
    let tokenSummaryConversationsFormat: String
    let tokenSummaryActiveDaysFormat: String
    let tokenSummaryAvgPerDayFormat: String
    let tokenActivityTitle: String
    let tokenActivityLegendLess: String
    let tokenActivityLegendMore: String
    let tokenTrendTitle: String
    let tokenTrendPeriodDay: String
    let tokenTrendPeriodWeek: String
    let tokenTrendPeriodMonth: String
    let tokenTrendPeriodTotal: String
    let tokenTopModelsTitle: String
    let tokenUnit: String
    let tokenSettingsGenericSection: String
    let tokenSettingsProvidersSection: String
    let tokenSettingsAlertsSection: String
    let tokenSettingsMenuBarMode: String
    let tokenSettingsMenuBarToday: String
    let tokenSettingsMenuBarSession: String
    let tokenSettingsMenuBarOff: String
    let tokenMenuBarTodayLabel: String
    let tokenSettingsRefreshInterval: String
    let tokenSettingsRefreshMinuteFormat: String
    let tokenSettingsLimitsDisplay: String
    let tokenSettingsLimitsUsed: String
    let tokenSettingsLimitsRemaining: String
    /// 限额显示弹层：额度重置时显示提示（toast）开关文案。
    let tokenResetToastLabel: String
    /// 限额显示弹层：额度重置时撒花开关文案。
    let tokenResetConfettiLabel: String
    /// 重置庆祝 toast 文案格式（%@ = provider 名 + 窗口标签，如 "Codex 7d"）。
    let tokenResetCelebrationFormat: String
    let tokenSettingsDefaultPeriod: String
    let tokenSettingsProviderStatusFormat: String
    let tokenSettingsLoggedIn: String
    let tokenSettingsNotConfigured: String
    let tokenSettingsHowToConfigure: String
    let tokenSettingsNoSubscription: String
    let tokenSettingsNoQuotaAvailable: String
    let tokenSettingsManageMoreProviders: String
    /// 会话窗阈值告警开关文案格式（%g = 当前阈值，如「会话窗用量 ≥90% 时通知」）。
    let tokenSettingsSessionAlertFormat: String
    let tokenSettingsAlertThreshold: String
    /// 告警阈值选项文案格式（%g = 百分比）。
    let tokenSettingsAlertThresholdFormat: String
    let tokenSettingsPaceAlert: String
    let tokenSettingsRequestPermission: String
    let tokenSettingsPermissionGranted: String
    let tokenSettingsPermissionDenied: String
    let tokenSettingsConfigureHintFormat: String
    let tokenSettingsConfigureHintCursor: String
    let tokenSettingsConfigureHintAntigravity: String
    let tokenSettingsConfigureHintTraeCn: String
    let tokenMenuBarSessionLabel: String
    let tokenAlertSessionTitle: String
    let tokenAlertSessionBodyFormat: String
    let tokenAlertPaceTitle: String
    let tokenAlertPaceBodyFormat: String
    let tokenDurationDayFormat: String
    let tokenDurationHourFormat: String
    let tokenDurationMinuteFormat: String
    /// 星期缩写（索引 0 = 周日；用于「峰值 168k（周三）」）。中文为准。
    let tokenWeekdayNames: [String]
    // MARK: - DeepSeek Balance
    let deepSeekBalanceCardTitle: String
    let deepSeekBalanceLoading: String
    let deepSeekBalanceUnavailable: String
    let deepSeekStatusBelowThreshold: String
    let deepSeekStatusReauthKey: String
    let deepSeekBalanceFooterFormat: String
    let deepSeekAlertTitle: String
    let deepSeekAlertBodyFormat: String
    let tokenSettingsTraeCnSection: String
    let tokenSettingsTraeCnJwtPlaceholder: String
    let opencodeSettingsApiKeyPlaceholder: String
    let opencodeSettingsApiKeyCaption: String
    let arkSettingsAkPlaceholder: String
    let arkSettingsSkPlaceholder: String
    let arkSettingsCaption: String
    let deepSeekSettingsApiKeyPlaceholder: String
    /// 凭证行小标题（如「API Key」），OpenCode / DeepSeek 等共用。
    let tokenSettingsApiKeyTitle: String
    let deepSeekSettingsSaveKey: String
    let deepSeekSettingsClearKey: String
    let deepSeekSettingsKeySaved: String
    let deepSeekSettingsKeyMissing: String
    let deepSeekSettingsApiKeyCaption: String
    let deepSeekSettingsApiKeyInvalid: String
    let deepSeekSettingsLowBalanceAlert: String
    /// 低余额通知开关文案（与 Section 标题区分）。
    let deepSeekSettingsLowBalanceAlertToggle: String
    let deepSeekSettingsThresholdLabel: String
    let deepSeekSettingsThresholdHint: String
    /// 阈值输入非法时的错误提示。
    let deepSeekSettingsThresholdInvalid: String
    let deepSeekSettingsRefreshInterval: String
    // MARK: - Provider Switch
    /// 特性名（功能中心 / 侧栏 tab 共用）。
    let featureHubNameProviderSwitch: String
    /// 特性描述（功能中心）。
    let featureHubDescProviderSwitch: String
    /// AI 分组标题。
    let featureHubGroupAI: String
    let settingsTabProviderSwitch: String
    /// 控制中心分段标题。
    let controlcenterTabProviderSwitch: String
    /// 控制中心导航标题。
    let controlcenterNavProviderSwitch: String
    let providerToolClaudeCode: String
    let providerToolCodex: String
    /// 官方供应商行标题。
    let providerOfficial: String
    let providerOfficialClaudeCaption: String
    let providerOfficialCodexCaption: String
    /// 「切换到官方」按钮。
    let providerSwitchBackToOfficial: String
    /// 激活项标注（%@ = profile 名）。
    let providerActiveProfileFormat: String
    /// 未托管配置卡标题。
    let providerActiveUnmanagedTitle: String
    /// 未托管摘要（%@ = base URL / provider 键）。
    let providerActiveUnmanagedSummaryFormat: String
    /// 损坏配置卡标题。
    let providerActiveUnreadableTitle: String
    let providerActiveUnreadableCaption: String
    /// profile 行「设为激活」。
    let providerSetActive: String
    /// profile 行激活打勾的无障碍标注。
    let providerActiveMark: String
    /// 激活卡片右上角「使用中」微章。
    let providerInUseBadge: String
    let providerEdit: String
    let providerDelete: String
    /// 菜单栏档案卡片复制指定配置启动命令。
    let providerCopyLaunchCommand: String
    let providerLaunchCommandCopied: String
    let providerLaunchCommandCopyFailed: String
    /// 顶部新增供应商按钮。
    let providerAddProvider: String
    /// 新增按钮（%@ = 工具名）。
    let providerAddProfileFormat: String
    /// 无 profile 时的引导文案。
    let providerEmptyProfilesHint: String
    /// 收编按钮 / 动作。
    let providerUnmanagedAdopt: String
    /// 收编命名弹窗标题。
    let providerUnmanagedAdoptPrompt: String
    let providerUnmanagedAdoptPlaceholder: String
    /// 缺 base URL / 凭证无法收编。
    let providerUnmanagedAdoptError: String
    /// 损坏配置「备份并重建」。
    let providerCorruptedBackupAndRebuild: String
    let providerCorruptedRebuildConfirmTitle: String
    let providerCorruptedRebuildConfirmMessage: String
    /// 切换结果 toast（%@ = profile 名）。
    let providerSwitchDoneFormat: String
    let providerSwitchDoneOfficial: String
    /// 切换完成后的重启提示。
    let providerRestartHint: String
    /// 检测到 CLI 运行时的额外提醒（%@ = 工具名）。
    let providerRestartRunningHintFormat: String
    /// 切换失败 toast（%@ = 错误描述）。
    let providerSwitchFailedFormat: String
    let providerEditConfigFile: String
    let providerRestoreBackup: String
    /// 恢复备份成功 toast。
    let providerBackupRestored: String
    let providerDeleteConfirmTitle: String
    /// 删除确认（%@ = profile 名）。
    let providerDeleteConfirmMessageFormat: String
    let providerDeleteConfirmButton: String
    let providerNameLabel: String
    let providerBaseURLLabel: String
    let providerTokenLabel: String
    let providerTokenPlaceholder: String
    /// 模型覆盖（可选）。
    let providerModelLabel: String
    let providerModelHint: String
    /// 角色模型映射分组标题（Claude Code）。
    let providerModelMappingLabel: String
    let providerModelMappingSectionTitle: String
    let providerSonnetModelLabel: String
    let providerSonnetNameLabel: String
    let providerOpusModelLabel: String
    let providerOpusNameLabel: String
    let providerFableModelLabel: String
    let providerFableNameLabel: String
    let providerHaikuModelLabel: String
    let providerHaikuNameLabel: String
    let providerSubagentModelLabel: String
    let providerPresetLabel: String
    let providerPresetSectionTitle: String
    let providerPresetHint: String
    /// 预设下拉「自定义」项。
    let providerPresetNone: String
    let providerBasicInfoSectionTitle: String
    let providerModelMappingDefaultHint: String
    let providerModelFallbackLabel: String
    let providerModelMappingRoleHint: String
    let providerModelCustomDisplayNames: String
    /// 撞名写入被拒提示。
    let providerFormNameConflict: String
    let providerFormSave: String
    let providerFormCancel: String
    /// 表单标题（%@ = 工具名）。
    let providerFormTitleNewFormat: String
    let providerFormTitleEditFormat: String
    /// 编辑器标题（%@ = 工具名）。
    let providerEditorTitleFormat: String
    /// 非法内容拒绝保存。
    let providerEditorInvalidContent: String
    let providerEditorSaved: String
    let providerEditorHint: String
    let providerBackupListTitle: String
    let providerBackupEmpty: String
    let providerBackupRestoreConfirmTitle: String
    /// 恢复确认（%@ = 备份名）。
    let providerBackupRestoreConfirmMessageFormat: String
    let providerBackupRestore: String
    let providerBackupRestoreFailed: String

    // MARK: - Sticky Notes（桌面便签）
    /// 实用工具列表行副标题。
    let utilityStickyNotesSubtitle: String
    let featureHubNameStickyNotes: String
    let featureHubDescStickyNotes: String
    // 便签窗口
    let stickyNotePlaceholder: String
    let stickyNoteSaved: String
    let stickyNoteSaving: String
    let stickyNoteNewNote: String
    let stickyNoteColorYellow: String
    let stickyNoteColorMint: String
    let stickyNoteColorBlue: String
    let stickyNoteColorPink: String
    let stickyNotePin: String
    let stickyNoteUnpin: String
    let stickyNoteSetReminder: String
    let stickyNoteEditReminder: String
    let stickyNoteCollapse: String
    let stickyNoteExpand: String
    let stickyNoteComplete: String
    // 提醒面板
    let stickyNoteReminderQuick15: String
    let stickyNoteReminderQuick1h: String
    let stickyNoteReminderQuickTomorrow: String
    /// 精确时间分组小标签。
    let stickyNoteReminderExactTime: String
    let stickyNoteReminderSet: String
    let stickyNoteReminderClear: String
    let stickyNoteReminderClose: String
    let stickyNoteReminderPast: String
    /// 提醒时刻（%@ = 本地格式化时间）。
    let stickyNoteReminderAtFormat: String
    /// 提醒时刻同日展示（%@ = HH:mm）。
    let stickyNoteReminderTodayFormat: String
    let stickyNoteReminderFired: String
    // 通知
    let stickyNoteNotificationTitle: String
    // 托盘菜单
    let stickyNoteMenuNew: String
    let stickyNoteMenuShowAll: String
    let stickyNoteMenuHideAll: String
    // 管理页
    let stickyNoteSectionActive: String
    let stickyNoteSectionCompleted: String
    /// 设置区分组标题。
    let stickyNoteSectionSettings: String
    /// 头部统计（%1$d = 进行中数量，%2$d = 已完成数量）。
    let stickyNoteCountsFormat: String
    let stickyNoteEmptyContent: String
    let stickyNoteBadgeHidden: String
    let stickyNoteCreateButton: String
    let stickyNoteLocate: String
    let stickyNoteRestore: String
    let stickyNoteUncomplete: String
    let stickyNoteDelete: String
    let stickyNoteDeleteCancel: String
    let stickyNoteDeleteConfirmTitle: String
    let stickyNoteDeleteConfirmMessage: String
    /// 已完成区头部「清空」按钮。
    let stickyNoteClearCompleted: String
    let stickyNoteClearCompletedConfirmTitle: String
    /// 清空已完成确认文案（%d = 已完成条数）。
    let stickyNoteClearCompletedConfirmMessage: String
    let stickyNoteNoNotes: String
    let stickyNoteHotkeyTitle: String
    let stickyNoteNotificationPermission: String
    let stickyNoteNotificationGranted: String
    let stickyNoteNotificationDenied: String

    // MARK: - Cleaning Mode（清洁模式）
    let utilityCleaningModeSubtitle: String
    let featureHubNameCleaningMode: String
    let featureHubDescCleaningMode: String
    let cleaningModeActionKeyboard: String
    let cleaningModeActionScreen: String
    let cleaningModeActionKeyboardHint: String
    let cleaningModeActionScreenHint: String
    let cleaningModeExit: String
    let cleaningModeActiveKeyboard: String
    let cleaningModeActiveScreen: String
    let cleaningModeLockedHint: String
    let cleaningModeScreenLockedHint: String
    let cleaningModeOverlayStyle: String
    let cleaningModeOverlayBlack: String
    let cleaningModeOverlayWhite: String
    let cleaningModeTimeout: String
    let cleaningModeTimeoutOff: String
    let cleaningModeTimeoutMinutesFormat: String
    let cleaningModePermissionTitle: String
    let cleaningModePermissionAction: String
}
