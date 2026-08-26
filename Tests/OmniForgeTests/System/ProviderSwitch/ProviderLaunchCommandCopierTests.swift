import AppKit
import XCTest
@testable import OmniForge

final class ProviderLaunchCommandCopierTests: XCTestCase {
    private let homePath = "/Users/tester"

    func test_copyLaunchCommand_writesCompleteCommandAndReportsSuccess() {
        let writer = RecordingPasteboardWriter()
        let copier = ProviderLaunchCommandCopier(
            writer: writer,
            homePath: homePath,
            environment: [:]
        )

        XCTAssertTrue(copier.copyLaunchCommand(for: makeProfile()))
        XCTAssertEqual(writer.clearCount, 1)
        XCTAssertEqual(
            writer.strings,
            ["claude --settings ~/.claude/providers/deepseek.json"]
        )
    }

    func test_copyLaunchCommand_reportsPasteboardFailure() {
        let writer = RecordingPasteboardWriter(setStringResult: false)
        let copier = ProviderLaunchCommandCopier(
            writer: writer,
            homePath: homePath,
            environment: [:]
        )

        XCTAssertFalse(copier.copyLaunchCommand(for: makeProfile()))
        XCTAssertEqual(writer.clearCount, 1)
        XCTAssertEqual(writer.strings, ["claude --settings ~/.claude/providers/deepseek.json"])
    }

    private func makeProfile() -> ProviderProfile {
        ProviderProfile(
            id: "deepseek",
            name: "DeepSeek",
            tool: .claudeCode,
            baseURL: "https://api.deepseek.com/anthropic",
            token: "sk-test",
            modelOverride: nil,
            modelMapping: nil,
            extraEnv: [:],
            managedBy: ProviderProfile.managedByMarker
        )
    }
}

private final class RecordingPasteboardWriter: PasteboardWriting {
    private(set) var strings: [String] = []
    private(set) var clearCount = 0
    private let setStringResult: Bool

    init(setStringResult: Bool = true) {
        self.setStringResult = setStringResult
    }

    func clearContents() {
        clearCount += 1
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        strings.append(string)
        return setStringResult
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        true
    }

    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        true
    }
}
