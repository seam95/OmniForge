import XCTest
@testable import OmniForge

final class L10nTests: XCTestCase {
    func test_init_loadsStoredLanguage() {
        let suiteName = "L10nTests_init"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("zh-Hans", forKey: UserDefaultsKeys.preferredLanguage)
        let l10n = L10n(userDefaults: defaults)
        XCTAssertEqual(l10n.language, .zhHans)
    }

    func test_init_defaultsToSystemLanguage() {
        let suiteName = "L10nTests_default"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let l10n = L10n(userDefaults: defaults)
        XCTAssertTrue([.en, .zhHans].contains(l10n.language))
    }

    func test_setLanguage_persists() {
        let suiteName = "L10nTests_set"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let l10n = L10n(userDefaults: defaults)
        l10n.setLanguage(.en)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.preferredLanguage), "en")
        l10n.setLanguage(.zhHans)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.preferredLanguage), "zh-Hans")
    }

    func test_setLanguage_nil_clearsPreference() {
        let suiteName = "L10nTests_nil"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let l10n = L10n(userDefaults: defaults)
        l10n.setLanguage(.en)
        XCTAssertNotNil(defaults.string(forKey: UserDefaultsKeys.preferredLanguage))
        l10n.setLanguage(nil)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.preferredLanguage))
    }

    func test_s_returnsCorrectStringsForLanguage() {
        let suiteName = "L10nTests_s"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let l10n = L10n(userDefaults: defaults)
        l10n.setLanguage(.en)
        XCTAssertEqual(l10n.s.appTitle, "OmniForge")
        l10n.setLanguage(.zhHans)
        XCTAssertEqual(l10n.s.actionUnlock, "解锁")
    }
}
