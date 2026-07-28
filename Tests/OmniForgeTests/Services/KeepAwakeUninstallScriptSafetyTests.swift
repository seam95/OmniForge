import XCTest
@testable import OmniForge

final class KeepAwakeUninstallScriptSafetyTests: XCTestCase {
    private var scriptURL: URL {
        // Services → OmniForgeTests → Tests → 仓库根
        let services = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = services
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("tools/uninstall-keep-awake.sh")
    }

    func test_scriptExistsAndIsValidZsh() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", scriptURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func test_decisionTable_matchesClamshellSupport() throws {
        // prepared/enabled/restoring × 0/1
        XCTAssertEqual(try decision(phase: "prepared", actual: "0", valid: "1"), "delete_record")
        XCTAssertEqual(try decision(phase: "prepared", actual: "1", valid: "1"), "restore_zero")
        XCTAssertEqual(try decision(phase: "enabled", actual: "0", valid: "1"), "delete_record")
        XCTAssertEqual(try decision(phase: "enabled", actual: "1", valid: "1"), "restore_zero")
        XCTAssertEqual(try decision(phase: "restoring", actual: "0", valid: "1"), "delete_record")
        XCTAssertEqual(try decision(phase: "restoring", actual: "1", valid: "1"), "restore_zero")
        XCTAssertEqual(try decision(phase: "", actual: "1", valid: "1"), "conflict")
        XCTAssertEqual(try decision(phase: "prepared", actual: "1", valid: "0"), "refuse")
    }

    func test_scriptStaticSafety_noWildcardSudoersDelete() throws {
        let text = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertFalse(text.contains("rm -rf /etc/sudoers.d"))
        XCTAssertFalse(text.contains("sudoers.d/*"))
        XCTAssertTrue(text.contains("--decision-only"))
        XCTAssertTrue(text.contains("/usr/bin/id"))
        XCTAssertTrue(text.contains("/usr/bin/plutil"))
        XCTAssertTrue(text.contains("refuses EUID=0"))
        // 固定 absolute executable 引用
        XCTAssertTrue(text.contains("/usr/bin/pmset"))
        // 主 sudoers 前缀为新名，同时保留历史名用于清理老版本残留。
        XCTAssertTrue(text.contains("omniforge-clamshell-"))
        XCTAssertTrue(text.contains("inputlock-clamshell-"))
        // record bundle 校验同时接受新名与历史名。
        XCTAssertTrue(text.contains("app.omniforge"))
        XCTAssertTrue(text.contains("app.inputlock"))
    }

    private func decision(phase: String, actual: String, valid: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, "--decision-only", phase, actual, valid]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
