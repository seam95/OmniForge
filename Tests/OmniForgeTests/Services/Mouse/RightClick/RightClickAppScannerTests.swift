import XCTest
@testable import OmniForge

final class RightClickAppScannerTests: XCTestCase {
    func test_knownDefinitions_areNotEmpty() {
        XCTAssertFalse(RightClickAppScanner.knownTerminals.isEmpty)
        XCTAssertFalse(RightClickAppScanner.knownEditors.isEmpty)

        // 验证常见关键应用必须存在定义
        XCTAssertTrue(RightClickAppScanner.knownTerminals.contains { $0.bundleId == "com.apple.Terminal" })
        XCTAssertTrue(RightClickAppScanner.knownEditors.contains { $0.bundleId == "com.microsoft.VSCode" })
    }

    func test_scanner_executesWithoutCrash() {
        let scanner = RightClickAppScanner.shared
        let terminals = scanner.scanInstalledTerminals()
        let editors = scanner.scanInstalledEditors()

        // macOS 基础系统必装自带 Terminal
        XCTAssertTrue(terminals.contains { $0.bundleId == "com.apple.Terminal" })
        
        // 验证扫描出的应用信息完整
        for app in terminals + editors {
            XCTAssertFalse(app.name.isEmpty)
            XCTAssertFalse(app.bundleId.isEmpty)
            XCTAssertNotNil(app.appURL)
        }
    }
}
