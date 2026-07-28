import XCTest
@testable import OmniForge

final class ClipboardStoreTests: XCTestCase {
    func test_saveAndLoadRoundTrip() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardStoreTests_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = FileClipboardStore(directoryURL: tempDir)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let textEntry = ClipboardEntry(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            createdAt: createdAt,
            type: .text,
            preview: "Hello",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("Hello")
        )

        let imageData = Data([0x01, 0x02, 0x03])
        let thumbnailData = Data([0x0a, 0x0b])
        let imageEntry = ClipboardEntry(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            createdAt: createdAt.addingTimeInterval(10),
            type: .image,
            preview: "Image",
            sourceAppBundleID: "com.test.app",
            sourceAppName: "Test",
            content: .image(imageData),
            thumbnailData: thumbnailData
        )

        store.saveEntries([textEntry, imageEntry])
        let loaded = store.loadEntries()

        XCTAssertEqual(loaded, [textEntry.lightweight(), imageEntry.lightweight()])
        XCTAssertEqual(store.loadFullContent(for: textEntry.id), textEntry.content)
        XCTAssertEqual(store.loadFullContent(for: imageEntry.id), imageEntry.content)
    }

    func test_saveRewritesAndCleansObsoleteThumbnailBlob() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardStoreTests_clean_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let store = FileClipboardStore(directoryURL: tempDir)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)

        let first = ClipboardEntry(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: createdAt,
            type: .image,
            preview: "Image",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .image(Data([0x01, 0x02, 0x03])),
            thumbnailData: Data([0x09])
        )

        store.saveEntries([first])

        let second = ClipboardEntry(
            id: UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!,
            createdAt: createdAt.addingTimeInterval(5),
            type: .text,
            preview: "Hello",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("Hello")
        )

        store.saveEntries([second])

        let blobs = tempDir
            .appendingPathComponent("blobs")
        let oldImageBlob = blobs.appendingPathComponent("\(first.id.uuidString).png")
        let oldThumbnailBlob = blobs.appendingPathComponent("\(first.id.uuidString)_thumb.png")

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldImageBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldThumbnailBlob.path))
    }
}
