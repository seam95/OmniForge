import XCTest
@testable import OmniForge

final class ScreenshotDefaultsTests: XCTestCase {
    func test_register_setsScreenshotDefaults() {
        let suite = "ScreenshotDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.screenshotEnabled))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.screenshotSaveDirectoryPath),
            ScreenshotOutputConfiguration.defaultDirectoryPath
        )
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.screenshotFileNamePrefix),
            ScreenshotOutputConfiguration.defaultPrefix
        )
        XCTAssertTrue(defaults.bool(forKey: AppFeature.screenshot.availabilityKey))
    }

    /// 快速操作锚点/自动关闭键已删除，不得再注册默认值。
    /// 旧快捷键默认值已收敛为 only allInOne + fullscreen。
    func test_screenshotDefaults_doNotRegisterRetiredResultPanelKeys() {
        let registration = Defaults.registrationValues
        let retiredAnchor = "screenshot" + "Quick" + "Access" + "Anchor"
        let retiredAutoClose = "screenshot" + "Quick" + "Access" + "AutoCloseSeconds"
        XCTAssertNil(registration[retiredAnchor])
        XCTAssertNil(registration[retiredAutoClose])

        // 死设置项不得再注册。
        XCTAssertNil(registration["screenshot.saveFormat"])
        XCTAssertNil(registration["screenshot.jpegQuality"])
        XCTAssertNil(registration["screenshot.includePointer"])
        XCTAssertNil(registration["screenshot.windowShadow"])

        // 其它截图输出与快捷键默认仍保留（含 copy/pin 与重排后的 fullscreen/record）。
        XCTAssertEqual(
            registration[UserDefaultsKeys.screenshotSaveDirectoryPath] as? String,
            ScreenshotOutputConfiguration.defaultDirectoryPath
        )
        XCTAssertEqual(
            registration[UserDefaultsKeys.screenshotFileNamePrefix] as? String,
            ScreenshotOutputConfiguration.defaultPrefix
        )
        XCTAssertNotNil(registration[UserDefaultsKeys.screenshotHotkeyAllInOneKeyCode])
        XCTAssertNotNil(registration[UserDefaultsKeys.screenshotHotkeyCopyKeyCode])
        XCTAssertNotNil(registration[UserDefaultsKeys.screenshotHotkeyPinKeyCode])
        XCTAssertNotNil(registration[UserDefaultsKeys.screenshotHotkeyFullscreenKeyCode])
        XCTAssertNotNil(registration[UserDefaultsKeys.screenshotHotkeyRecordKeyCode])
        XCTAssertEqual(
            registration[UserDefaultsKeys.screenshotHotkeyCopyKeyCode] as? Int,
            HotkeyDefinition.defaultScreenshotCopy.keyCode
        )
        XCTAssertEqual(
            registration[UserDefaultsKeys.screenshotHotkeyPinKeyCode] as? Int,
            HotkeyDefinition.defaultScreenshotPin.keyCode
        )
        XCTAssertEqual(
            registration[UserDefaultsKeys.screenshotHotkeyFullscreenKeyCode] as? Int,
            HotkeyDefinition.defaultScreenshotFullscreen.keyCode
        )
        XCTAssertEqual(
            registration[UserDefaultsKeys.screenshotHotkeyRecordKeyCode] as? Int,
            HotkeyDefinition.defaultScreenshotRecord.keyCode
        )
    }

    /// 设置分段源码不再暴露快速操作分组与死设置项；路径/前缀/快捷键入口保留。
    func test_screenshotSettingsSection_hasNoRetiredResultPanelGroup() throws {
        let path = "Sources/OmniForge/Views/Settings/Screenshot/ScreenshotSettingsSection.swift"
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let banned = [
            "Quick" + "Access",
            "quick" + "Access",
            "screenshot" + "Quick" + "Access",
            "screenshotSaveFormat",
            "screenshotJPEGQuality",
            "screenshotIncludePointer",
            "screenshotWindowShadow",
        ]
        for token in banned {
            XCTAssertFalse(contents.contains(token), "settings section still mentions \(token)")
        }
        XCTAssertTrue(contents.contains("screenshotSaveDirectoryPath"))
        XCTAssertTrue(contents.contains("screenshotFileNamePrefix"))
        XCTAssertTrue(contents.contains("hotkeysSection"))
        XCTAssertTrue(contents.contains("outputSection"))
    }
}
