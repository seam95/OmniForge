import AppKit
import XCTest
@testable import OmniForge

/// 粘贴服务：写入剪贴板 → 关闭面板 → 权限预检 → 焦点恢复（有原应用时）→ 注入 Cmd+V。
/// 恢复焦点时注入经 schedule 延后，等待激活 IPC 完成。
final class ClipboardPasteServiceTests: XCTestCase {
    func test_unloadedPayloadDoesNotClearCloseOrPostPaste() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = makeService(writer: writer, poster: poster)
        let entry = ClipboardEntry(
            id: UUID(),
            createdAt: Date(),
            type: .text,
            preview: "missing",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text(nil)
        )
        var didClose = false

        service.paste(entry: entry, close: { didClose = true })

        XCTAssertEqual(writer.clearCount, 0)
        XCTAssertFalse(didClose)
        XCTAssertEqual(poster.postCount, 0)
    }

    func test_pasteWritesTextAndPostsCommandVSynchronously() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = makeService(writer: writer, poster: poster)

        service.paste(entry: makeTextEntry(), close: nil)

        XCTAssertEqual(writer.clearCount, 1)
        XCTAssertEqual(writer.lastString, "Hello")
        XCTAssertEqual(poster.postCount, 1)
    }

    func test_pasteCallsCloseBeforePosting() {
        let poster = FakeKeyEventPoster()
        let service = makeService(poster: poster)

        var events: [String] = []
        poster.onPost = { events.append("post") }

        service.paste(entry: makeTextEntry(), close: { events.append("close") })

        XCTAssertEqual(events, ["close", "post"])
    }

    func test_pasteWithReactivateReactivatesBeforePosting() {
        let poster = FakeKeyEventPoster()
        let service = makeService(poster: poster)

        var events: [String] = []
        poster.onPost = { events.append("post") }

        service.paste(
            entry: makeTextEntry(),
            close: { events.append("close") },
            reactivate: { events.append("reactivate") },
            schedule: { work in
                events.append("schedule")
                work()
            }
        )

        // 关面板 → 焦点交还原应用 → 等激活 IPC 完成（schedule）→ 注入 Cmd+V
        XCTAssertEqual(events, ["close", "reactivate", "schedule", "post"])
    }

    func test_pasteWithReactivateDefersPostUntilScheduled() {
        let poster = FakeKeyEventPoster()
        let service = makeService(poster: poster)

        var scheduledWork: (() -> Void)?
        service.paste(
            entry: makeTextEntry(),
            close: nil,
            reactivate: {},
            schedule: { work in scheduledWork = work }
        )

        // 注入必须推迟到 schedule 执行后：activate 是异步 IPC，同步注入会早于焦点转移
        XCTAssertEqual(poster.postCount, 0)

        scheduledWork?()
        XCTAssertEqual(poster.postCount, 1)
    }

    func test_pasteWithReactivateSkipsReactivationWhenAccessibilityMissing() {
        let poster = FakeKeyEventPoster()
        var deniedPromptCount = 0
        let service = ClipboardPasteService(
            writer: FakePasteboardWriter(),
            keyPoster: poster,
            isAccessibilityGranted: { false },
            onAccessibilityDenied: { deniedPromptCount += 1 }
        )
        var reactivateCount = 0

        service.paste(
            entry: makeTextEntry(),
            close: nil,
            reactivate: { reactivateCount += 1 },
            schedule: { $0() }
        )

        // 权限缺失时仅引导授权：不恢复焦点、不注入（内容已写入剪贴板可手动粘贴）
        XCTAssertEqual(reactivateCount, 0)
        XCTAssertEqual(poster.postCount, 0)
        XCTAssertEqual(deniedPromptCount, 1)
    }

    func test_pasteWithoutAccessibilityWritesPasteboardButDoesNotPost() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        var deniedPromptCount = 0
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            isAccessibilityGranted: { false },
            onAccessibilityDenied: { deniedPromptCount += 1 }
        )

        service.paste(entry: makeTextEntry(), close: nil)

        // 权限缺失时合成按键会静默失效：内容仍写入（可手动 Cmd+V 补救），改为触发授权引导。
        XCTAssertEqual(writer.clearCount, 1)
        XCTAssertEqual(writer.lastString, "Hello")
        XCTAssertEqual(poster.postCount, 0)
        XCTAssertEqual(deniedPromptCount, 1)
    }

    func test_pasteDoesNotPromptWhenAccessibilityGranted() {
        let poster = FakeKeyEventPoster()
        var deniedPromptCount = 0
        let service = ClipboardPasteService(
            keyPoster: poster,
            isAccessibilityGranted: { true },
            onAccessibilityDenied: { deniedPromptCount += 1 }
        )

        service.paste(entry: makeTextEntry(), close: nil)

        XCTAssertEqual(poster.postCount, 1)
        XCTAssertEqual(deniedPromptCount, 0)
    }

    func test_pasteWritesURLAsPlainTextAndURLFormats() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = makeService(writer: writer, poster: poster)

        service.paste(entry: makeURLEntry(), close: nil)

        XCTAssertEqual(writer.stringByType[.string], "https://example.com/docs?q=inputlock")
        XCTAssertEqual(writer.stringByType[.URL], "https://example.com/docs?q=inputlock")
        XCTAssertEqual(writer.writeObjectsCallCount, 1)
        XCTAssertEqual(poster.postCount, 1)
    }

    private func makeService(
        writer: FakePasteboardWriter = FakePasteboardWriter(),
        poster: FakeKeyEventPoster
    ) -> ClipboardPasteService {
        ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            isAccessibilityGranted: { true }
        )
    }
}

private func makeTextEntry() -> ClipboardEntry {
    ClipboardEntry(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        type: .text,
        preview: "Hello",
        sourceAppBundleID: nil,
        sourceAppName: nil,
        content: .text("Hello")
    )
}

private func makeURLEntry() -> ClipboardEntry {
    ClipboardEntry(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        type: .url,
        preview: "https://example.com/docs?q=inputlock",
        sourceAppBundleID: nil,
        sourceAppName: nil,
        content: .url(URL(string: "https://example.com/docs?q=inputlock")!)
    )
}

private final class FakePasteboardWriter: PasteboardWriting {
    private(set) var clearCount = 0
    private(set) var lastString: String?
    private(set) var stringByType: [NSPasteboard.PasteboardType: String] = [:]
    private(set) var writeObjectsCallCount = 0

    func clearContents() {
        clearCount += 1
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        lastString = string
        stringByType[type] = string
        return true
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        true
    }

    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        writeObjectsCallCount += 1
        return true
    }
}

private final class FakeKeyEventPoster: KeyEventPosting {
    var onPost: (() -> Void)?
    private(set) var postCount = 0

    func postCommandV() {
        postCount += 1
        onPost?()
    }

    func postCommandC() {}
}
