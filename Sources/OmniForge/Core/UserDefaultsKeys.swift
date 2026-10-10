enum UserDefaultsKeys {
    static let isLocked = "isLocked"
    static let lockedInputSourceID = "lockedInputSourceID"
    static let preferredLanguage = "preferredLanguage"
    static let appearanceMode = "appearanceMode"
    static let launchAtLogin = "launchAtLogin"
    static let hideDockIcon = "hideDockIcon"
    // 通用设置「显示菜单栏图标」；未写入时默认开启
    static let menuBarIconVisible = "menuBar.iconVisible"
    static let clipboardRetentionDays = "clipboardRetentionDays"
    static let clipboardMaxEntries = "clipboardMaxEntries"
    static let clipboardHotkeyKeyCode = "clipboardHotkeyKeyCode"
    static let clipboardHotkeyModifiers = "clipboardHotkeyModifiers"
    static let clipboardWindowFrame = "clipboardWindowFrame"
    static let clipboardFeatureEnabled = "clipboardFeatureEnabled"
    // Shelf
    static let shelfEnabled = "shelfEnabled"
    static let shelfShortcutEnabled = "shelfShortcutEnabled"
    static let shelfHotkeyKeyCode = "shelfHotkeyKeyCode"
    static let shelfHotkeyModifiers = "shelfHotkeyModifiers"
    static let shelfShakeToOpen = "shelfShakeToOpen"
    static let shelfDropZoneEnabled = "shelfDropZoneEnabled"
    static let shelfCloseAfterDrop = "shelfCloseAfterDrop"
    static let shelfRemoveAfterDrop = "shelfRemoveAfterDrop"
    static let shelfAutomaticExclusions = "shelfAutomaticExclusions"
    static let shelfItems = "shelfItems"
    // 鼠标与触控板
    static let scrollInverterEnabled = "scrollInverterEnabled"
    static let smoothScrollEnabled = "smoothScrollEnabled"
    static let smoothScrollStep = "smoothScrollStep"      // 每个滚轮刻度的像素数
    static let mouseNavigationEnabled = "mouseNavigationEnabled" // 侧键触发 Back/Forward
    static let dockClickMinimize = "dockClickMinimize"    // 点击前台 App 的 Dock 图标最小化其窗口
    static let dockClickCycleWindows = "dockClickCycleWindows" // 点击前台 App 的 Dock 图标循环其窗口
    // 访达右键增强
    static let rightClickFileExtensions = "rightClick_fileExtensions"
    static let rightClickIsSubmenuCollapsed = "rightClick_isSubmenuCollapsed"
    static let rightClickPromotedActionKeys = "rightClick_promotedActionKeys"
    static let rightClickFavoriteDirectories = "rightClick_favoriteDirectories"
    // 控制中心实用工具
    static let lastUtilityTool = "lastUtilityTool"
    // 控制中心顶层页签
    static let lastControlCenterPanel = "lastControlCenterPanel"
    // Onboarding
    static let hasOnboarded = "hasOnboarded"
    static let onboardingCompletedVersion = "onboardingCompletedVersion"
    static let onboardingCurrentStep = "onboardingCurrentStep"
    static let lastWhatsNewVersion = "lastWhatsNewVersion"
    // Cleaner
    static let cleanerScheduleFrequency = "cleanerScheduleFrequency"    // off | daily | weekly
    static let cleanerScheduleHour = "cleanerScheduleHour"
    static let cleanerScheduleMinute = "cleanerScheduleMinute"
    static let cleanerScheduleWeekday = "cleanerScheduleWeekday"        // 1 Sunday ... 7 Saturday
    static let cleanerScheduleNotify = "cleanerScheduleNotify"
    static let cleanerLastAutoRun = "cleanerLastAutoRun"                // Double, epoch seconds
    static let cleanerLastAutoFreed = "cleanerLastAutoFreed"            // Int bytes
    // Cleaning Mode — 清洁模式
    static let cleaningModeOverlayStyle = "cleaningModeOverlayStyle"    // black | white，默认 black
    static let cleaningModeTimeoutMinutes = "cleaningModeTimeoutMinutes" // 0 = off；档位 5/10/15/30，默认 10
    // Keep Awake — 持久化字符串必须稳定，不得重命名
    static let keepAwakeDefaultDurationMinutes = "keepAwake.defaultDurationMinutes"
    static let keepAwakeBatteryLimitPercent = "keepAwake.batteryLimitPercent"
    static let keepAwakeAutoStart = "keepAwake.autoStart"
    static let keepAwakeShowCountdown = "keepAwake.showCountdown"
    static let keepAwakeMouseJiggleEnabled = "keepAwake.mouseJiggleEnabled"
    static let keepAwakeMouseJiggleIntervalMinutes = "keepAwake.mouseJiggleIntervalMinutes"
    static let keepAwakeClamshellPreferred = "keepAwake.clamshellPreferred"
    static let keepAwakeShortcutEnabled = "keepAwake.shortcutEnabled"
    static let keepAwakeHotkeyKeyCode = "keepAwake.hotkeyKeyCode"
    static let keepAwakeHotkeyModifiers = "keepAwake.hotkeyModifiers"
    // Screenshot — 持久化字符串必须稳定，不得重命名
    static let screenshotEnabled = "screenshot.enabled"
    static let screenshotSaveDirectoryPath = "screenshot.saveDirectoryPath"
    static let screenshotFileNamePrefix = "screenshot.fileNamePrefix" // T15 SPEC 3.11
    // 快捷键：UserDefaults 为真源，KeyboardShortcuts 为运行时镜像
    static let screenshotHotkeyAllInOneKeyCode = "screenshot.hotkey.allInOne.keyCode"
    static let screenshotHotkeyAllInOneModifiers = "screenshot.hotkey.allInOne.modifiers"
    static let screenshotHotkeyCopyKeyCode = "screenshot.hotkey.copy.keyCode"
    static let screenshotHotkeyCopyModifiers = "screenshot.hotkey.copy.modifiers"
    static let screenshotHotkeyPinKeyCode = "screenshot.hotkey.pin.keyCode"
    static let screenshotHotkeyPinModifiers = "screenshot.hotkey.pin.modifiers"
    static let screenshotHotkeyFullscreenKeyCode = "screenshot.hotkey.fullscreen.keyCode"
    static let screenshotHotkeyFullscreenModifiers = "screenshot.hotkey.fullscreen.modifiers"
    // 截图编辑器最近 emoji（持久化字符串必须稳定，不得重命名）
    static let screenshotRecentEmojis = "screenshot.recentEmojis"
    // 录屏输出 / 快捷键（持久化字符串必须稳定，不得重命名）
    static let recordingSaveDirectoryPath = "screenshot.recording.saveDirectoryPath"
    static let recordingSavePreference = "screenshot.recording.savePreference"
    static let recordingLastManualFormat = "screenshot.recording.lastManualFormat"
    static let screenshotHotkeyRecordKeyCode = "screenshot.hotkey.record.keyCode"
    static let screenshotHotkeyRecordModifiers = "screenshot.hotkey.record.modifiers"
    // 长截图（滚动截图）
    static let screenshotScrollMaxHeight = "screenshot.scroll.maxHeight"
    static let screenshotScrollFrozenDetection = "screenshot.scroll.frozenDetection"
    // 截图晾衣绳（clothesline）
    static let screenshotClotheslineEnabled = "screenshot.clothesline.enabled"
    static let screenshotClotheslineItems = "screenshot.clothesline.items"
    static let screenshotClotheslineInboxEnabled = "screenshot.clothesline.inboxEnabled"
    static let screenshotClotheslineInboxOffered = "screenshot.clothesline.inboxOffered"
    static let screenshotClotheslineInboxSavedSettings = "screenshot.clothesline.inboxSavedSettings"
    static let screenshotClotheslineSoundOn = "screenshot.clothesline.soundOn"
    static let screenshotClotheslineCapacity = "screenshot.clothesline.capacity"
    static let screenshotClotheslineEditorConfirmHang = "screenshot.clothesline.editorConfirmHang"
    static let screenshotClotheslineHotkeyToggleKeyCode = "screenshot.clothesline.hotkey.toggle.keyCode"
    static let screenshotClotheslineHotkeyToggleModifiers = "screenshot.clothesline.hotkey.toggle.modifiers"
    static let screenshotClotheslineHotkeyHangKeyCode = "screenshot.clothesline.hotkey.hang.keyCode"
    static let screenshotClotheslineHotkeyHangModifiers = "screenshot.clothesline.hotkey.hang.modifiers"
    // 网络诊断 — 持久化字符串必须稳定，不得重命名
    static let networkDiagnosticsSegment = "networkDiagnostics.segment"
    // Sticky Notes — 持久化字符串必须稳定，不得重命名
    static let stickyNoteHotkeyKeyCode = "stickyNote.hotkey.keyCode"
    static let stickyNoteHotkeyModifiers = "stickyNote.hotkey.modifiers"
    // 新建便签的默认排版（「最后使用即默认」：任一便签调整字号/行高后成为后续新建便签的默认值）
    static let stickyNoteDefaultFontSize = "stickyNote.defaultFontSize"
    static let stickyNoteDefaultLineHeight = "stickyNote.defaultLineHeight"
    // 新建便签的默认尺寸（「最后手动调整即默认」：任一便签手动缩放后成为后续新建便签的默认尺寸）
    static let stickyNoteDefaultNoteWidth = "stickyNote.defaultNoteWidth"
    static let stickyNoteDefaultNoteHeight = "stickyNote.defaultNoteHeight"
    // Prompt Optimizer — 提示词优化（持久化字符串必须稳定，不得重命名）
    static let promptOptimizerBaseURL = "promptOptimizer.baseURL"
    static let promptOptimizerModel = "promptOptimizer.model"
    static let promptOptimizerAutoReplace = "promptOptimizer.autoReplace"
    static let promptOptimizerHotkeyKeyCode = "promptOptimizer.hotkey.keyCode"
    static let promptOptimizerHotkeyModifiers = "promptOptimizer.hotkey.modifiers"
}
