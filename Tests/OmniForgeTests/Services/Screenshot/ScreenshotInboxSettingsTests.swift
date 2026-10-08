// Tests/OmniForgeTests/Services/Screenshot/ScreenshotInboxSettingsTests.swift
import XCTest
@testable import OmniForge

private final class FakePreferencesStore: ScreenshotPreferencesStore {
    var storage: [String: [String: Any]] = [:]  // domain -> key -> value
    var synchronizedDomains: [String] = []

    func copyValue(forKey key: String, domain: String) -> Any? { storage[domain]?[key] }
    func setValue(_ value: Any?, forKey key: String, domain: String) {
        storage[domain, default: [:]][key] = value
    }
    func synchronize(domain: String) { synchronizedDomains.append(domain) }
}

final class ScreenshotInboxSettingsTests: XCTestCase {
    private var store: FakePreferencesStore!
    private var defaults: UserDefaults!
    private var settings: ScreenshotInboxSettings!
    private let target = URL(fileURLWithPath: "/tmp/inbox-dir", isDirectory: true)

    override func setUp() {
        super.setUp()
        store = FakePreferencesStore()
        let suite = "inbox-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        settings = ScreenshotInboxSettings(store: store, userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys
            .first { $0.hasPrefix("inbox-tests") } ?? "")
        super.tearDown()
    }

    private func setSystemPref(_ key: String, _ value: Any?) {
        store.setValue(value, forKey: key, domain: "com.apple.screencapture")
    }

    func testApplyWritesBothLocationKeysAndDisablesThumbnail() {
        setSystemPref("location", "~/Pictures/shots")
        setSystemPref("show-thumbnail", true)
        settings.apply(targetDirectory: target)
        let domain = "com.apple.screencapture"
        XCTAssertEqual(store.storage[domain]?["location"] as? String, target.path)
        XCTAssertEqual(store.storage[domain]?["location-screenshot"] as? String, target.path)
        XCTAssertEqual(store.storage[domain]?["show-thumbnail"] as? Bool, false)
        XCTAssertTrue(settings.isEnabled)
    }

    func testApplySavesPreviousValuesOnce() {
        setSystemPref("location", "~/Pictures/shots")
        setSystemPref("show-thumbnail", true)
        settings.apply(targetDirectory: target)
        // 第二次 apply（目录变化场景）不得把自身值误存为旧值
        setSystemPref("location", target.path)
        settings.apply(targetDirectory: URL(fileURLWithPath: "/tmp/inbox-2", isDirectory: true))
        let saved = defaults.dictionary(forKey: UserDefaultsKeys.screenshotClotheslineInboxSavedSettings)
        XCTAssertEqual(saved?["location"] as? String, "~/Pictures/shots")
        XCTAssertEqual(saved?["thumbnail"] as? Bool, true)
    }

    func testApplySavesAbsenceAsMissingKey() {
        // 旧值原本不存在 → 保存字典不含该键 → restore 时删除键恢复系统默认
        settings.apply(targetDirectory: target)
        let saved = defaults.dictionary(forKey: UserDefaultsKeys.screenshotClotheslineInboxSavedSettings)
        XCTAssertNil(saved?["location"])
    }

    func testRestorePutsBackPreviousValues() {
        setSystemPref("location", "~/Pictures/shots")
        setSystemPref("show-thumbnail", true)
        settings.apply(targetDirectory: target)
        settings.restore()
        let domain = "com.apple.screencapture"
        XCTAssertEqual(store.storage[domain]?["location"] as? String, "~/Pictures/shots")
        XCTAssertNil(store.storage[domain]?["location-screenshot"])
        XCTAssertEqual(store.storage[domain]?["show-thumbnail"] as? Bool, true)
        XCTAssertFalse(settings.isEnabled)
    }

    func testRestoreWhenNotAppliedIsNoop() {
        setSystemPref("location", "~/Pictures/shots")
        settings.restore()
        XCTAssertEqual(store.storage["com.apple.screencapture"]?["location"] as? String, "~/Pictures/shots")
    }

    func testIsAppliedRequiresBothKeysMatchingTarget() {
        XCTAssertFalse(settings.isApplied(targetDirectory: target))
        setSystemPref("location", target.path)
        XCTAssertFalse(settings.isApplied(targetDirectory: target))  // 缺第二个键
        setSystemPref("location-screenshot", target.path)
        XCTAssertTrue(settings.isApplied(targetDirectory: target))
    }

    func testWasOfferedRoundTrip() {
        XCTAssertFalse(settings.wasOffered)
        settings.wasOffered = true
        XCTAssertTrue(settings.wasOffered)
    }
}
