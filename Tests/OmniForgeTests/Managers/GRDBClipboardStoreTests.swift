import XCTest
@testable import OmniForge

final class GRDBClipboardStoreTests: XCTestCase {
    func test_saveAndLoadRoundTrip() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        let store = GRDBClipboardStore(databaseURL: tempDB)
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

        // 使用 saveEntry 逐条存入
        store.saveEntry(textEntry)
        store.saveEntry(imageEntry)
        let loaded = store.loadEntries()

        // loadEntries 返回轻量版本：image 的 blob 为 nil
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, imageEntry.id)
        XCTAssertEqual(loaded[1].id, textEntry.id)
        // text 和 image 都返回轻量版
        XCTAssertEqual(loaded[1].content, .text(nil))
        XCTAssertEqual(store.loadFullContent(for: textEntry.id), .text("Hello"))
        // image 内容为轻量版（Data 为 nil）
        XCTAssertEqual(loaded[0].content, .image(nil))
        XCTAssertEqual(loaded[0].type, .image)
        XCTAssertEqual(loaded[0].thumbnailData, thumbnailData)
        // 元数据已填充
        XCTAssertEqual(loaded[0].blobSize, Int64(imageData.count))
    }

    func test_saveRewritesEntries() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_rewrite_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        let store = GRDBClipboardStore(databaseURL: tempDB)
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

        let second = ClipboardEntry(
            id: UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!,
            createdAt: createdAt.addingTimeInterval(5),
            type: .text,
            preview: "Hello",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("Hello")
        )

        store.saveEntries([first])
        store.saveEntries([second])

        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, second.id)
    }

    func test_saveAndLoadRoundTrip_forAdditionalContentTypes() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_contentTypes_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        let store = GRDBClipboardStore(databaseURL: tempDB)
        let createdAt = Date(timeIntervalSince1970: 1_700_001_000)

        let urlEntry = ClipboardEntry(
            id: UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!,
            createdAt: createdAt,
            type: .url,
            preview: "example.com",
            sourceAppBundleID: "com.browser.test",
            sourceAppName: "Browser",
            content: .url(URL(string: "https://example.com/docs?q=inputlock")!)
        )

        let fileEntry = ClipboardEntry(
            id: UUID(uuidString: "22345678-1234-1234-1234-1234567890ab")!,
            createdAt: createdAt.addingTimeInterval(1),
            type: .file,
            preview: "a.txt 等 2 个文件",
            sourceAppBundleID: "com.finder.test",
            sourceAppName: "Finder",
            content: .files([
                URL(fileURLWithPath: "/tmp/a.txt"),
                URL(fileURLWithPath: "/tmp/b.txt")
            ])
        )

        let rtfData = Data([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x31, 0x7d])
        let rtfEntry = ClipboardEntry(
            id: UUID(uuidString: "32345678-1234-1234-1234-1234567890ab")!,
            createdAt: createdAt.addingTimeInterval(2),
            type: .rtf,
            preview: "RTF 内容",
            sourceAppBundleID: "com.editor.test",
            sourceAppName: "Editor",
            content: .rtf(rtfData)
        )

        let unknownEntry = ClipboardEntry(
            id: UUID(uuidString: "42345678-1234-1234-1234-1234567890ab")!,
            createdAt: createdAt.addingTimeInterval(3),
            type: .unknown,
            preview: "Unknown",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .unknown(Data([0xff, 0x00, 0xaa])),
            thumbnailData: Data([0x01, 0x02])
        )

        store.saveEntries([urlEntry, fileEntry, rtfEntry, unknownEntry])
        let loaded = store.loadEntries()

        // 轻量加载：url 和 file 完整，rtf 和 unknown 的 blob 为 nil
        XCTAssertEqual(loaded.count, 4)
        XCTAssertEqual(loaded[0].id, unknownEntry.id)
        XCTAssertEqual(loaded[1].id, rtfEntry.id)
        XCTAssertEqual(loaded[2].id, fileEntry.id)
        XCTAssertEqual(loaded[3].id, urlEntry.id)

        // url/file 内容完整
        XCTAssertEqual(loaded[3].content, urlEntry.content)
        XCTAssertEqual(loaded[2].content, fileEntry.content)
        // rtf/unknown 内容为轻量版
        XCTAssertEqual(loaded[1].content, .rtf(nil))
        XCTAssertEqual(loaded[0].content, .unknown(nil))
        XCTAssertEqual(loaded[0].thumbnailData, Data([0x01, 0x02]))
    }

    func test_loadFullContent() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_fullContent_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        let store = GRDBClipboardStore(databaseURL: tempDB)
        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let entryID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!

        let entry = ClipboardEntry(
            id: entryID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            type: .image,
            preview: "Image",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .image(imageData)
        )

        store.saveEntry(entry)

        // loadEntries 返回轻量版
        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.first?.content, .image(nil))

        // loadFullContent 返回完整 blob
        let fullContent = store.loadFullContent(for: entryID)
        XCTAssertEqual(fullContent, .image(imageData))

        // 不存在的 ID 返回 nil
        let missing = store.loadFullContent(for: UUID())
        XCTAssertNil(missing)
    }

    func test_deleteEntries() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_delete_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        let store = GRDBClipboardStore(databaseURL: tempDB)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let id3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let entries = [
            ClipboardEntry(id: id1, createdAt: createdAt, type: .text, preview: "1", sourceAppBundleID: nil, sourceAppName: nil, content: .text("1")),
            ClipboardEntry(id: id2, createdAt: createdAt.addingTimeInterval(1), type: .text, preview: "2", sourceAppBundleID: nil, sourceAppName: nil, content: .text("2")),
            ClipboardEntry(id: id3, createdAt: createdAt.addingTimeInterval(2), type: .text, preview: "3", sourceAppBundleID: nil, sourceAppName: nil, content: .text("3"))
        ]

        for entry in entries {
            store.saveEntry(entry)
        }
        XCTAssertEqual(store.loadEntries().count, 3)

        // 删除 id1 和 id3
        store.deleteEntries(ids: [id1, id3])

        let remaining = store.loadEntries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, id2)
    }

    func test_initCanRemoveLegacyStoreFilesWithoutAffectingDatabaseReadWrite() {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_legacyCleanup_\(UUID().uuidString)", isDirectory: true)
        let dbURL = baseDir.appendingPathComponent("entries.sqlite")
        let legacyEntriesURL = baseDir.appendingPathComponent("entries.json")
        let legacyBlobsURL = baseDir.appendingPathComponent("blobs", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: baseDir)
        }

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? Data("legacy".utf8).write(to: legacyEntriesURL)
        try? FileManager.default.createDirectory(at: legacyBlobsURL, withIntermediateDirectories: true)
        try? Data([0x01]).write(to: legacyBlobsURL.appendingPathComponent("legacy.bin"))

        let store = GRDBClipboardStore(
            databaseURL: dbURL,
            legacyStoreDirectoryURL: baseDir,
            removeLegacyStoreFiles: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyEntriesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyBlobsURL.path))

        let entry = ClipboardEntry(
            id: UUID(uuidString: "52345678-1234-1234-1234-1234567890ab")!,
            createdAt: Date(timeIntervalSince1970: 1_700_002_000),
            type: .text,
            preview: "cleanup",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("cleanup")
        )

        store.saveEntries([entry])
        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, .text(nil))
        XCTAssertEqual(store.loadFullContent(for: entry.id), .text("cleanup"))
    }
}
