import XCTest
@testable import OmniForge

final class ScreenshotOutputConfigurationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ScreenshotOutputConfigurationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_validatedPrefix_acceptsValidPrefix() {
        XCTAssertEqual(ScreenshotOutputConfiguration.validatedPrefix("InputLock"), "InputLock")
        XCTAssertEqual(ScreenshotOutputConfiguration.validatedPrefix("  Shot  "), "Shot")
    }

    func test_validatedPrefix_rejectsEmptyOrPathSeparators() {
        XCTAssertEqual(ScreenshotOutputConfiguration.validatedPrefix(""), "Screenshot")
        XCTAssertEqual(ScreenshotOutputConfiguration.validatedPrefix("   "), "Screenshot")
        XCTAssertEqual(ScreenshotOutputConfiguration.validatedPrefix("a/b"), "Screenshot")
        XCTAssertEqual(ScreenshotOutputConfiguration.validatedPrefix("a:b"), "Screenshot")
    }

    func test_load_expandsTildeDirectoryAndValidatesPrefix() {
        defaults.set("~/Desktop", forKey: UserDefaultsKeys.screenshotSaveDirectoryPath)
        defaults.set("MyShot", forKey: UserDefaultsKeys.screenshotFileNamePrefix)

        let snapshot = ScreenshotOutputConfiguration(userDefaults: defaults).load()

        let expectedDir = URL(
            fileURLWithPath: (NSString(string: "~/Desktop")).expandingTildeInPath,
            isDirectory: true
        )
        XCTAssertEqual(snapshot.saveDirectory, expectedDir)
        XCTAssertEqual(snapshot.fileNamePrefix, "MyShot")
    }

    func test_load_emptyDirectoryBecomesNil_andInvalidPrefixFallsBack() {
        defaults.set("   ", forKey: UserDefaultsKeys.screenshotSaveDirectoryPath)
        defaults.set("bad/prefix", forKey: UserDefaultsKeys.screenshotFileNamePrefix)

        let snapshot = ScreenshotOutputConfiguration(userDefaults: defaults).load()

        XCTAssertNil(snapshot.saveDirectory)
        XCTAssertEqual(snapshot.fileNamePrefix, ScreenshotOutputConfiguration.defaultPrefix)
    }

    func test_timestampedFileName_usesCustomPrefix() {
        let date = Date(timeIntervalSince1970: 0)
        let name = ScreenshotSaver.timestampedFileName(
            prefix: "MyShot",
            quality: .original,
            date: date
        )
        XCTAssertTrue(name.hasPrefix("MyShot-"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }
}
