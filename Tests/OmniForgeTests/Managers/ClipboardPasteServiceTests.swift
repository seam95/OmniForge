import AppKit
import XCTest
@testable import OmniForge

final class ClipboardPasteServiceTests: XCTestCase {
    func test_unloadedPayloadDoesNotClearCloseOrPostPaste() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 0,
            pollInterval: 0.01,
            isAppActive: { false }
        )
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

    func test_pasteWritesTextAndTriggersPaste() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 0,
            pollInterval: 0.01,
            isAppActive: { false }
        )

        let entry = makeTextEntry()

        let expectation = expectation(description: "Paste triggered")
        poster.onPost = { expectation.fulfill() }

        service.paste(entry: entry, close: nil)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(writer.clearCount, 1)
        XCTAssertEqual(writer.lastString, "Hello")
    }

    func test_pasteCallsCloseBeforeTriggeringPaste() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 0,
            pollInterval: 0.01,
            isAppActive: { false }
        )

        var didClose = false
        let expectation = expectation(description: "Paste triggered")
        poster.onPost = {
            XCTAssertTrue(didClose)
            expectation.fulfill()
        }

        service.paste(entry: makeTextEntry(), close: { didClose = true })

        waitForExpectations(timeout: 1)
    }

    func test_pasteWaitsForAppToDeactivateBeforeTriggeringPaste() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()

        var appActive = true
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 1,
            pollInterval: 0.01,
            isAppActive: { appActive }
        )

        let expectation = expectation(description: "Paste triggered after app deactivates")
        poster.onPost = {
            XCTAssertFalse(appActive)
            expectation.fulfill()
        }

        service.paste(entry: makeTextEntry(), close: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            appActive = false
        }

        waitForExpectations(timeout: 1)
    }

    func test_pasteTriggersAfterTimeoutIfAppStaysActive() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()

        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 0.05,
            pollInterval: 0.01,
            isAppActive: { true }
        )

        let expectation = expectation(description: "Paste triggered after timeout")
        poster.onPost = { expectation.fulfill() }

        service.paste(entry: makeTextEntry(), close: nil)

        waitForExpectations(timeout: 1)
    }

    func test_pasteWaitsForCustomReadyCondition() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()

        var readyToPaste = false
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 1,
            pollInterval: 0.01,
            isAppActive: { false }
        )

        let expectation = expectation(description: "Paste triggered after ready condition becomes true")
        poster.onPost = {
            XCTAssertTrue(readyToPaste)
            expectation.fulfill()
        }

        service.paste(entry: makeTextEntry(), close: nil, isReadyToPaste: { readyToPaste })

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            readyToPaste = true
        }

        waitForExpectations(timeout: 1)
    }

    func test_pasteUsesGlobalPasteWhenReadyEvenIfTargetPIDProvided() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let targetPID: pid_t = 123
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 1,
            pollInterval: 0.01,
            isAppActive: { true }
        )

        let expectation = expectation(description: "Paste posted globally when ready")
        poster.onPost = {
            XCTAssertNil(poster.lastTargetPID)
            expectation.fulfill()
        }

        service.paste(entry: makeTextEntry(), close: nil, isReadyToPaste: { true }, targetPID: targetPID)

        waitForExpectations(timeout: 1)
    }

    func test_pastePostsToTargetPIDAfterTimeoutWhenNotReady() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let targetPID: pid_t = 456
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 0.05,
            pollInterval: 0.01,
            isAppActive: { true }
        )

        let expectation = expectation(description: "Paste posted to target PID after timeout")
        poster.onPost = {
            XCTAssertEqual(poster.lastTargetPID, targetPID)
            expectation.fulfill()
        }

        service.paste(entry: makeTextEntry(), close: nil, isReadyToPaste: { false }, targetPID: targetPID)

        waitForExpectations(timeout: 1)
    }

    func test_pasteWritesURLAsPlainTextAndURLFormats() {
        let writer = FakePasteboardWriter()
        let poster = FakeKeyEventPoster()
        let service = ClipboardPasteService(
            writer: writer,
            keyPoster: poster,
            pasteDelay: 0,
            maxWaitForDeactivate: 0,
            pollInterval: 0.01,
            isAppActive: { false }
        )

        let entry = makeURLEntry()
        let expectation = expectation(description: "Paste triggered")
        poster.onPost = { expectation.fulfill() }

        service.paste(entry: entry, close: nil)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(writer.stringByType[.string], "https://example.com/docs?q=inputlock")
        XCTAssertEqual(writer.stringByType[.URL], "https://example.com/docs?q=inputlock")
        XCTAssertEqual(writer.writeObjectsCallCount, 1)
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
    private(set) var lastTargetPID: pid_t?
    private(set) var postCount = 0

    func postCommandV(targetPID: pid_t?) {
        postCount += 1
        lastTargetPID = targetPID
        onPost?()
    }
}
