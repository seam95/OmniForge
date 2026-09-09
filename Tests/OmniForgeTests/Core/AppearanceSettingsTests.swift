import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 外观设置：枚举解析、持久化回退、NSAppearance 映射、批量应用与弱引用清理。
@MainActor
final class AppearanceSettingsTests: XCTestCase {
    private let suite = "AppearanceSettingsTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - 枚举解析

    func test_appearanceMode_rawValueRoundTrip() {
        for mode in AppearanceMode.allCases {
            XCTAssertEqual(AppearanceMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertEqual(AppearanceMode.allCases.map(\.rawValue), ["system", "light", "dark"])
    }

    func test_appearanceMode_invalidRawValueReturnsNil() {
        XCTAssertNil(AppearanceMode(rawValue: "midnight"))
    }

    func test_appearanceMode_nsAppearanceMapping() {
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    // MARK: - 默认与回退

    func test_init_missingKeyFallsBackToSystem() {
        let defaults = makeDefaults()
        let settings = AppearanceSettings(userDefaults: defaults)
        XCTAssertEqual(settings.mode, .system)
    }

    func test_init_invalidPersistedValueFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("midnight", forKey: UserDefaultsKeys.appearanceMode)
        let settings = AppearanceSettings(userDefaults: defaults)
        XCTAssertEqual(settings.mode, .system)
    }

    // MARK: - 持久化

    func test_setMode_persistsAndNewInstanceReadsSameMode() {
        let defaults = makeDefaults()
        let settings = AppearanceSettings(userDefaults: defaults)

        settings.setMode(.dark)

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.appearanceMode), "dark")
        let reloaded = AppearanceSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.mode, .dark)
    }

    func test_setMode_systemPersistsRawValue() {
        let defaults = makeDefaults()
        let settings = AppearanceSettings(userDefaults: defaults)

        settings.setMode(.system)

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.appearanceMode), "system")
    }

    // MARK: - 窗口应用

    func test_attach_appliesCurrentAppearance() {
        let settings = AppearanceSettings(userDefaults: makeDefaults())
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)

        settings.setMode(.dark)
        settings.attach(window)

        XCTAssertEqual(window.appearance?.name, .darkAqua)
    }

    func test_attachWithSystemResetsToNil() {
        let settings = AppearanceSettings(userDefaults: makeDefaults())
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)

        settings.setMode(.dark)
        settings.attach(window)
        settings.setMode(.system)

        XCTAssertNil(window.appearance, "system 应恢复 window.appearance = nil 跟随系统")
    }

    func test_setMode_applyToAllAttachedWindows() {
        let defaults = makeDefaults()
        let settings = AppearanceSettings(userDefaults: defaults)
        let first = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        settings.attach(first)
        settings.attach(second)

        settings.setMode(.light)

        XCTAssertEqual(first.appearance?.name, .aqua)
        XCTAssertEqual(second.appearance?.name, .aqua)
    }

    func test_windowAppearance_propagatesToHostingViewEffectiveAppearance() {
        // 单点验证：window.appearance → NSHostingController → SwiftUI colorScheme 传导链路。
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let host = NSHostingController(
            rootView: Color.clear.frame(width: 10, height: 10)
        )
        window.contentViewController = host

        window.appearance = AppearanceMode.dark.nsAppearance
        XCTAssertEqual(
            host.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
            .darkAqua
        )

        window.appearance = AppearanceMode.light.nsAppearance
        XCTAssertEqual(
            host.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
            .aqua
        )
    }

    func test_attach_deduplicatesSameWindow() {
        let settings = AppearanceSettings(userDefaults: makeDefaults())
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        settings.attach(window)
        settings.attach(window)
        // 重复 attach 不崩溃即通过；应用路径幂等。
        settings.setMode(.dark)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
    }

    // MARK: - 弱引用清理

    func test_applyToWindows_cleansReleasedWindows() {
        let settings = AppearanceSettings(userDefaults: makeDefaults())
        var window: NSWindow? = NSWindow(
            contentRect: .zero, styleMask: [], backing: .buffered, defer: false
        )
        settings.attach(window!)
        window = nil

        // 释放后批量应用不崩溃、不残留。
        settings.setMode(.dark)

        // 再次 attach 新窗口仍正常应用（内部表已被清理）。
        let fresh = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        settings.attach(fresh)
        XCTAssertEqual(fresh.appearance?.name, .darkAqua)
    }
}