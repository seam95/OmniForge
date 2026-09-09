import XCTest
@testable import OmniForge

// MARK: - 假件

private final class RecordingKeyPoster: KeyEventPosting {
    /// 模拟目标应用响应 ⌘C：向剪贴板写入该文本；nil 表示不响应（无选中）。
    var selectionTextToWrite: String?
    private(set) var commandCCount = 0

    func postCommandV() {}

    func postCommandC() {
        commandCCount += 1
        guard let selectionTextToWrite else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectionTextToWrite, forType: .string)
    }
}

private final class RecordingSuspender: ClipboardCaptureSuspending {
    private(set) var events: [String] = []

    func suspendCapture() {
        events.append("suspend")
    }

    func resumeCapture() {
        events.append("resume")
    }
}

// MARK: - 测试

/// ⌘C 兜底取词：注入 → 轮询 → 读取 → 恢复剪贴板与暂停窗口的完整闭环。
/// 用真实 NSPasteboard.general（Recorder 写入驱动 changeCount 变化），每测试恢复原内容。
@MainActor
final class FallbackSelectionCopierTests: XCTestCase {
    private var poster: RecordingKeyPoster!
    private var suspender: RecordingSuspender!
    private var originalContents: String!

    override func setUp() {
        super.setUp()
        poster = RecordingKeyPoster()
        suspender = RecordingSuspender()
        originalContents = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() {
        // 还原测试对系统剪贴板的占用，避免污染后续用例/用户环境。
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let originalContents {
            pasteboard.setString(originalContents, forType: .string)
        }
        super.tearDown()
    }

    private func makeCopier(timeout: TimeInterval = 0.5) -> FallbackSelectionCopier {
        FallbackSelectionCopier(
            pasteboard: .general,
            keyPoster: poster,
            captureSuspender: suspender,
            pollInterval: 0.005,
            timeout: timeout
        )
    }

    private func seedPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func test_success_readsSelectionThenRestoresOriginal() async {
        seedPasteboard("原剪贴板内容")
        poster.selectionTextToWrite = "选中的提示词"

        let text = await makeCopier().copySelectionAndRead()

        XCTAssertEqual(text, "选中的提示词")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "原剪贴板内容", "读完后必须恢复原剪贴板")
        XCTAssertEqual(poster.commandCCount, 1)
        XCTAssertEqual(suspender.events.first, "suspend")
        XCTAssertEqual(suspender.events.last, "resume")
        XCTAssertEqual(suspender.events.filter { $0 == "suspend" }.count, suspender.events.filter { $0 == "resume" }.count, "暂停/恢复配对")
    }

    func test_timeoutWithoutChangeReturnsNil() async {
        seedPasteboard("原剪贴板内容")
        poster.selectionTextToWrite = nil // 应用不响应拷贝

        let text = await makeCopier(timeout: 0.05).copySelectionAndRead()

        XCTAssertNil(text)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "原剪贴板内容")
        XCTAssertEqual(suspender.events.last, "resume", "失败路径也必须恢复暂停窗口")
    }

    func test_writtenEmptyStringReturnsNil() async {
        seedPasteboard("原剪贴板内容")
        poster.selectionTextToWrite = "   " // 拷贝出空白（无有效选中）

        let text = await makeCopier().copySelectionAndRead()

        XCTAssertNil(text)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "原剪贴板内容")
    }

    func test_snapshot_roundTripsMultipleItems() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("文本条目", forType: .string)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .URL)
        second.setString("https://example.com", forType: .string)
        pasteboard.writeObjects([first, second])

        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("覆盖", forType: .string)
        XCTAssertNotEqual(pasteboard.string(forType: .string), "文本条目")

        snapshot.restore(to: pasteboard)

        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2, "多条目保真")
        XCTAssertEqual(items.first?.string(forType: .string), "文本条目")
        XCTAssertEqual(items.last?.string(forType: .URL), "https://example.com")
    }
}
