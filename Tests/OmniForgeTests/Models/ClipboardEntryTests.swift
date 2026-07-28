import XCTest
@testable import OmniForge

final class ClipboardEntryTests: XCTestCase {
    func test_initStoresFields() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = ClipboardEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: createdAt,
            type: .text,
            preview: "Hello",
            sourceAppBundleID: "com.test.app",
            sourceAppName: "Test",
            content: .text("Hello")
        )

        XCTAssertEqual(entry.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(entry.createdAt, createdAt)
        XCTAssertEqual(entry.type, .text)
        XCTAssertEqual(entry.preview, "Hello")
        XCTAssertEqual(entry.sourceAppBundleID, "com.test.app")
        XCTAssertEqual(entry.sourceAppName, "Test")
        XCTAssertEqual(entry.content, .text("Hello"))
        XCTAssertNil(entry.thumbnailData)
    }

    func test_lightweightRemovesTextPayloadButKeepsMetadata() {
        let entry = ClipboardEntry(
            id: UUID(),
            createdAt: Date(),
            type: .text,
            preview: "preview",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("full text")
        )

        let lightweight = entry.lightweight()

        XCTAssertEqual(lightweight.content, .text(nil))
        XCTAssertEqual(lightweight.preview, "preview")
        XCTAssertEqual(lightweight.contentHash, entry.contentHash)
        XCTAssertEqual(lightweight.blobSize, entry.blobSize)
    }
}
