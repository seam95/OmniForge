enum SettingsAccessibilityID: String, CaseIterable {
    case generalLanguage = "settings.general.language"
    case generalLaunchAtLogin = "settings.general.launchAtLogin"
    case generalHideDockIcon = "settings.general.hideDockIcon"
    case generalLaunchAtLoginError = "settings.general.launchAtLogin.error"

    case cleanerCancelScan = "cleaner.scan.cancel"

    case performanceSegment = "performance.segment"
    case performanceMonitorEnabled = "performance.monitor.enabled"
    case tokenUsageSegment = "tokenUsage.segment"
    case tokenUsageEnabled = "tokenUsage.enabled"
    case tokenUsageMenuBarMode = "tokenUsage.menuBarMode"
    case tokenUsageRefreshInterval = "tokenUsage.refreshInterval"
    case tokenUsageDefaultPeriod = "tokenUsage.defaultPeriod"
    case tokenUsageSessionAlert = "tokenUsage.sessionAlert"
    case tokenUsageAlertThreshold = "tokenUsage.alertThreshold"
    case tokenUsagePaceAlert = "tokenUsage.paceAlert"
    case tokenUsageRequestPermission = "tokenUsage.requestPermission"
    case tokenUsageGearButton = "tokenUsage.gearButton"
    case tokenUsagePopoverDisplayMode = "tokenUsage.popover.displayMode"
    case tokenUsagePopoverResetToast = "tokenUsage.popover.resetToast"
    case tokenUsagePopoverResetConfetti = "tokenUsage.popover.resetConfetti"
    case tokenUsagePopoverManageMore = "tokenUsage.popover.manageMore"
    case deepSeekApiKeyField = "deepSeek.apiKeyField"
    case deepSeekSaveKey = "deepSeek.saveKey"
    case deepSeekClearKey = "deepSeek.clearKey"
    case deepSeekLowBalanceToggle = "deepSeek.lowBalanceToggle"
    case deepSeekThresholdField = "deepSeek.thresholdField"
    case deepSeekRefreshInterval = "deepSeek.refreshInterval"

    case menuBarEnabled = "performance.menuBar.enabled"
    case menuBarPreview = "performance.menuBar.preview"
    case menuBarSpacing = "performance.menuBar.spacing"
    case menuBarMemoryStyle = "performance.menuBar.memoryStyle"
    case menuBarNetworkUploadFirst = "performance.menuBar.networkUploadFirst"
    case menuBarCombineTemperatures = "performance.menuBar.combineTemperatures"
    case menuBarSeparateItems = "performance.menuBar.separateItems"
    case menuBarHideMainIcon = "performance.menuBar.hideMainIcon"

    case mouseScrollInverterEnabled = "mouse.scrollInverter.enabled"
    case mouseSmoothScrollEnabled = "mouse.smoothScroll.enabled"
    case mouseSmoothScrollStep = "mouse.smoothScroll.step"
    case mouseNavigationEnabled = "mouse.navigation.enabled"
    case mouseDockClickMinimize = "mouse.dockClick.minimize"
    case mouseDockClickCycle = "mouse.dockClick.cycle"

    case keepAwakeDuration = "keepAwake.duration"
    case keepAwakeAutoStart = "keepAwake.autoStart"
    case keepAwakeBatteryThreshold = "keepAwake.battery.threshold"
    case keepAwakeCountdown = "keepAwake.countdown"
    case keepAwakeHotkeyEnabled = "keepAwake.hotkey.enabled"
    case keepAwakePointerJiggleEnabled = "keepAwake.pointerJiggle.enabled"
    case keepAwakePointerJiggleInterval = "keepAwake.pointerJiggle.interval"
    case keepAwakeClamshellPreferred = "keepAwake.clamshell.preferred"

    static func performanceSectionEnabled(_ section: MonitorSection) -> String {
        "performance.section.\(section.rawValue).enabled"
    }

    static func menuBarMetricEnabled(_ metric: MenuBarMetric) -> String {
        "performance.menuBar.metric.\(metric.rawValue).enabled"
    }

    static func tokenUsageProviderState(_ provider: TokenUsageProvider) -> String {
        "tokenUsage.provider.\(provider.rawValue).state"
    }

    static func tokenUsageProviderVisible(_ provider: TokenUsageProvider) -> String {
        "tokenUsage.provider.\(provider.rawValue).visible"
    }
}
