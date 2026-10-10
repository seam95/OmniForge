import XCTest
@testable import OmniForge

/// `settings.json` 根对象读写 helper：缺失返回 nil、非对象抛错、原子写且美化排序。
final class SettingsJSONFileTests: XCTestCase {
    private var tmpDir: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsJSONFileTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        settingsURL = tmpDir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_readRoot_returnsNilWhenFileMissing() throws {
        XCTAssertNil(try SettingsJSONFile.readRoot(from: settingsURL, fileManager: .default))
    }

    func test_readRoot_throwsWhenRootIsNotAnObject() throws {
        try Data("[1,2,3]".utf8).write(to: settingsURL)
        XCTAssertThrowsError(try SettingsJSONFile.readRoot(from: settingsURL, fileManager: .default))
    }

    func test_writeRoot_createsFileWithPrettyPrintedJSON() throws {
        try SettingsJSONFile.writeRoot(["b": 2, "a": 1], to: settingsURL, fileManager: .default)
        let text = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"a\" : 1"))
        XCTAssertEqual(try SettingsJSONFile.readRoot(from: settingsURL, fileManager: .default)?["a"] as? Int, 1)
    }
}
