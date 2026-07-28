import XCTest
@testable import OmniForge

final class StringsTests: XCTestCase {

    func test_english_allPropertiesNonEmpty() {
        let en = Strings.en
        let mirror = Mirror(reflecting: en)
        for child in mirror.children {
            guard let label = child.label, let value = child.value as? String else { continue }
            XCTAssertFalse(value.isEmpty, "英文翻译为空: \(label)")
        }
    }

    func test_chinese_allPropertiesNonEmpty() {
        let zh = Strings.zhHans
        let mirror = Mirror(reflecting: zh)
        for child in mirror.children {
            guard let label = child.label, let value = child.value as? String else { continue }
            XCTAssertFalse(value.isEmpty, "中文翻译为空: \(label)")
        }
    }

    func test_bothLanguagesHaveSamePropertyCount() {
        let enMirror = Mirror(reflecting: Strings.en)
        let zhMirror = Mirror(reflecting: Strings.zhHans)
        XCTAssertEqual(enMirror.children.count, zhMirror.children.count)
    }

    func test_english_knownValues() {
        let s = Strings.en
        XCTAssertEqual(s.appTitle, "OmniForge")
        XCTAssertEqual(s.actionUnlock, "Unlock")
        XCTAssertEqual(s.clipboardTitle, "Clipboard History")
    }

    func test_chinese_knownValues() {
        let s = Strings.zhHans
        XCTAssertEqual(s.actionUnlock, "解锁")
        XCTAssertEqual(s.actionLock, "锁定")
        XCTAssertEqual(s.clipboardTitle, "剪贴板历史")
    }

    func test_menuStringsExist() {
        XCTAssertFalse(Strings.en.menuQuit.isEmpty)
        XCTAssertFalse(Strings.en.menuClose.isEmpty)
        XCTAssertFalse(Strings.en.settingsTitle.isEmpty)
        XCTAssertFalse(Strings.zhHans.menuQuit.isEmpty)
        XCTAssertFalse(Strings.zhHans.settingsTitle.isEmpty)
    }

    func test_controlCenterContractHasExpectedTranslations() {
        XCTAssertEqual(Strings.en.controlcenterTabUtilities, "Utilities")
        XCTAssertEqual(Strings.zhHans.controlcenterTabUtilities, "实用工具")
        XCTAssertEqual(Strings.en.runStateWaitingPermission, "Waiting for permission")
        XCTAssertEqual(Strings.zhHans.runStateWaitingPermission, "等待权限")
        XCTAssertEqual(Strings.en.utilityUninstallBusy, "Available after the current operation finishes")
        XCTAssertEqual(Strings.zhHans.utilityUninstallBusy, "操作完成后可卸载")
    }

    /// 快速操作文案已删除；全能工作台/冻屏文案保留。
    func test_strings_haveNoRetiredResultPanelProperties_andKeepCaptureAnnotationWorkbench() {
        let bannedFragments = [
            "Quick" + "Access",
            "quick" + "Access",
            "screenshot" + "Quick" + "Access",
        ]
        for source in [Strings.en, Strings.zhHans] {
            for child in Mirror(reflecting: source).children {
                guard let label = child.label else { continue }
                for fragment in bannedFragments {
                    XCTAssertFalse(
                        label.contains(fragment),
                        "残留本地化属性: \(label)"
                    )
                }
            }
            XCTAssertFalse(source.captureAnnotationToolShape.isEmpty)
            XCTAssertFalse(source.captureAnnotationActionCopy.isEmpty)
            XCTAssertFalse(source.captureAnnotationErrorFreeze.isEmpty)
            XCTAssertFalse(source.captureAnnotationErrorCopy.isEmpty)
            XCTAssertFalse(source.captureAnnotationErrorSave.isEmpty)
            XCTAssertFalse(source.captureAnnotationErrorPin.isEmpty)
        }
        XCTAssertEqual(Strings.en.captureAnnotationErrorFreeze, "Screen freeze failed")
        XCTAssertEqual(Strings.zhHans.captureAnnotationErrorFreeze, "屏幕冻结失败")
    }
}

// MARK: - KeepAwake 字段完整性

    func test_keepAwakeFields_nonEmpty_inBothLanguages() {
        let labels = [
            "keepAwakeTitle", "keepAwakeStart", "keepAwakeStop", "keepAwakeRetryCleanup",
            "keepAwakeEndsAtLabel",
            "keepAwakeUnavailable", "keepAwakeStatusFeatureUnavailable",
            "keepAwakeStatusWaitingRecovery", "keepAwakeStatusNormalSleep",
            "keepAwakeStatusStarting", "keepAwakeStatusActiveTimed",
            "keepAwakeStatusActiveIndefinite", "keepAwakeStatusStopping",
            "keepAwakeStatusCleanupRequired", "keepAwakeClamshellChecking",
            "keepAwakeClamshellAuthorizing", "keepAwakeClamshellEnabling",
            "keepAwakeClamshellActive", "keepAwakeClamshellRestoring",
            "keepAwakeClamshellConflict", "keepAwakeClamshellFailed",
            "keepAwakeRecoveryCheckingTitle", "keepAwakeRecoveryCheckingDetail",
            "keepAwakeRecoveryRestoringTitle", "keepAwakeRecoveryRestoringDetail",
            "keepAwakeRecoveryCleanupTitle", "keepAwakeRecoveryConflictTitle",
            "keepAwakeRetry", "keepAwakeMenuStartDefault", "keepAwakeMenuRetryLastStart",
            "keepAwakeMenuStartDuration", "keepAwakeMenuProcessing", "keepAwakeMenuStop",
            "keepAwakeMenuRetryCleanup", "keepAwakeMenuOpenSettings", "keepAwakeClamshellAction", "keepAwakeMenuQuit",
            "keepAwakeTooltipInactive", "keepAwakeTooltipActivating",
            "keepAwakeTooltipDeactivating", "keepAwakeTooltipActiveIndefinite",
            "keepAwakeTooltipCleanupRequired", "keepAwakeNotificationTitle",
            "keepAwakeAuthDisclosureTitle", "keepAwakeAuthDisclosureBody",
            "keepAwakeAuthContinue", "keepAwakeAuthRemoveTitle", "keepAwakeAuthRemoveBody",
            "keepAwakeAuthRemove", "keepAwakeAuthCancel",
            "keepAwakeSectionSession", "keepAwakeDefaultDuration",
            "keepAwakeDurationIndefinite", "keepAwakeAutoStart", "keepAwakeSectionBattery",
            "keepAwakeBatteryThreshold", "keepAwakeBatteryOff", "keepAwakeBatteryCaption",
            "keepAwakeSectionMenuBar", "keepAwakeShowCountdown",
            "keepAwakeSectionShortcut", "keepAwakeEnableShortcut",
            "keepAwakeHotkeyManagerMissing", "keepAwakeSectionPointer",
            "keepAwakeEnableJiggle", "keepAwakeJiggleInterval", "keepAwakeJiggleCaption",
            "keepAwakeRequestAccessibility", "keepAwakeSectionClamshell",
            "keepAwakePreferClamshell", "keepAwakeCapabilityPrefix",
            "keepAwakeCapabilityChecking", "keepAwakeCapabilityNeedsAuth",
            "keepAwakeCapabilityReady", "keepAwakeConfigureAuth", "keepAwakeRemoveAuth",
            "keepAwakeRefreshStatus", "keepAwakeSectionDiagnostics",
            "keepAwakeDiagManagerMissing", "keepAwakeAuthInstallSuccess",
            "keepAwakeAuthRemoveSuccess", "keepAwakeAuthManagerMissingInstall",
            "keepAwakeAuthNoRemoveEntry", "keepAwakeErrCancelled", "keepAwakeErrBusy",
            "keepAwakeNotifDurationElapsed", "keepAwakeNotifLowBattery",
            "keepAwakeNotifCleanupDuration", "keepAwakeNotifCleanupLowBattery",
            "featureHubRetryUninstall"
        ]
        func value(_ label: String, _ source: Strings) -> String? {
            Mirror(reflecting: source).children.first { $0.label == label }?.value as? String
        }
        for label in labels {
            let en = value(label, Strings.en)
            let zh = value(label, Strings.zhHans)
            XCTAssertFalse(en?.isEmpty ?? true, "英文 keepAwake 字段缺失或为空: \(label)")
            XCTAssertFalse(zh?.isEmpty ?? true, "中文 keepAwake 字段缺失或为空: \(label)")
        }
    }

// MARK: - 品牌残留扫描（本功能路径）

    func test_keepAwakePaths_haveNoBrandResidue() {
        let directories = [
            "Sources/OmniForge/System/KeepAwake",
            "Sources/OmniForge/Services/KeepAwake",
            "Sources/OmniForge/Models/KeepAwake",
            "Sources/OmniForge/Views/KeepAwake"
        ]
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory) else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for file in files {
                let path = (directory as NSString).appendingPathComponent(file)
                let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                XCTAssertFalse(
                    contents.lowercased().contains("vorssaint"),
                    "保持唤醒路径存在品牌残留: \(path)"
                )
            }
        }
    }

