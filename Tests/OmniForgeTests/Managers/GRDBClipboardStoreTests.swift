import AppKit
import CryptoKit
import GRDB
import XCTest
@testable import OmniForge

final class GRDBClipboardStoreTests: XCTestCase {
    func test_initPrunesUndecodableImageEntries() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStorePrune_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        // 先建库并写入一条 4 字节占位「图片」（微信式 stub）。
        let store = GRDBClipboardStore(databaseURL: tempDB)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stubEntry = ClipboardEntry(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            createdAt: createdAt,
            type: .image,
            preview: "Image",
            sourceAppBundleID: nil,
            sourceAppName: "WeChat",
            content: .image(Data([0x89, 0x50, 0x4E, 0x47]))
        )
        store.saveEntry(stubEntry)
        XCTAssertEqual(store.loadEntries().count, 1)

        // 重新开库：启动时清理，占位条目被删除。
        let reopened = GRDBClipboardStore(databaseURL: tempDB)
        XCTAssertEqual(reopened.loadEntries().count, 0, "4 字节占位图片条目应在开库时清理")
    }

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

    func test_saveEntryRewritesExistingEntry() {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_rewrite_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
        }

        let store = GRDBClipboardStore(databaseURL: tempDB)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        let entryID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let first = ClipboardEntry(
            id: entryID,
            createdAt: createdAt,
            type: .image,
            preview: "Image",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .image(Data([0x01, 0x02, 0x03])),
            thumbnailData: Data([0x09])
        )

        // 同 id 再次保存（生产「移动到最前」路径）：应更新原行，而不是新增重复行。
        let second = ClipboardEntry(
            id: entryID,
            createdAt: createdAt.addingTimeInterval(5),
            type: .text,
            preview: "Hello",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("Hello")
        )

        store.saveEntry(first)
        store.saveEntry(second)

        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, second.id)
        XCTAssertEqual(loaded[0].type, .text)
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

        for entry in [urlEntry, fileEntry, rtfEntry, unknownEntry] {
            store.saveEntry(entry)
        }
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

        store.saveEntry(entry)
        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, .text(nil))
        XCTAssertEqual(store.loadFullContent(for: entry.id), .text("cleanup"))
    }

    // MARK: - Task 16：库文件损坏时自动重建

    func test_initRebuildsCorruptDatabaseAndPreservesCorruptFile() {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_corrupt_\(UUID().uuidString)", isDirectory: true)
        let dbURL = baseDir.appendingPathComponent("entries.sqlite")
        defer {
            try? FileManager.default.removeItem(at: baseDir)
        }

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // 预置内容为垃圾字节的库文件：文件头不是 "SQLite format 3"，打开时报 SQLITE_NOTADB。
        let garbage = Data("这绝不是 SQLite 数据库文件，只是用于测试损坏自动恢复的垃圾字节。".utf8)
        try! garbage.write(to: dbURL)

        // 损坏库 init：应改名保留现场并以空库重建，而不是永久失败。
        let store = GRDBClipboardStore(databaseURL: dbURL)

        // 1. 损坏文件被改名保留为 entries.sqlite.corrupt-<yyyyMMdd-HHmmss>。
        let contents = try! FileManager.default.contentsOfDirectory(atPath: baseDir.path)
        let preservedNames = contents.filter { $0.hasPrefix("entries.sqlite.corrupt-") }
        XCTAssertEqual(preservedNames.count, 1, "损坏文件应被改名保留，实际目录内容：\(contents)")
        guard preservedNames.count == 1 else { return }
        let stamp = preservedNames[0]
            .replacingOccurrences(of: "entries.sqlite.corrupt-", with: "")
        XCTAssertNotNil(
            stamp.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression),
            "改名后缀应为 yyyyMMdd-HHmmss 时间戳，实际：\(stamp)"
        )
        let preservedURL = baseDir.appendingPathComponent(preservedNames[0])
        XCTAssertEqual(try? Data(contentsOf: preservedURL), garbage, "改名保留的应是原损坏文件的完整字节")

        // 2. 重建成功：无存储错误，新库在原路径可读写回环。
        XCTAssertNil(store.storageErrorMessage, "自动重建后不应再有存储错误")
        let entry = ClipboardEntry(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            createdAt: Date(timeIntervalSince1970: 1_700_003_000),
            type: .text,
            preview: "rebuilt",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("rebuilt")
        )
        store.saveEntry(entry)
        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1, "重建后的空库应可正常读写")
        XCTAssertEqual(loaded[0].id, entry.id)
    }

    // MARK: - Task 19：blob 元数据回填迁移（行为锁定）

    func test_backfillBlobMetadataMigrationBackfillsMissingMetadataForEachType() {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBClipboardStoreTests_backfill_\(UUID().uuidString)", isDirectory: true)
        let dbURL = baseDir.appendingPathComponent("entries.sqlite")
        defer {
            try? FileManager.default.removeItem(at: baseDir)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // 造一张 4x2 的合法 PNG，验证 image 分支的宽高回填。
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = rep.representation(using: .png, properties: [:])!
        // 大于 32 字节，避免 init 时的占位图片清理逻辑误删该行。
        XCTAssertGreaterThan(pngData.count, 32)

        let rtfData = Data(#"{\rtf1}"#.utf8)
        let textValue = "你好剪贴板"
        let urlValue = "https://example.com/backfill"
        let filesJSON = #"["file:///tmp/a.txt","file:///tmp/b.txt"]"#
        let createdAt = Date(timeIntervalSince1970: 1_700_004_000)

        // 手工构造「前两个迁移已应用、backfill 未跑」的旧库，并直接 SQL 写入
        // blobSize 为 NULL 的行——绕过记录层（记录层写入会自动填元数据，测不到回填）。
        let legacyQueue = try! DatabaseQueue(path: dbURL.path)
        try! legacyQueue.write { db in
            try db.create(table: "clipboard_entries") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("type", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("sourceAppBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("textValue", .text)
                t.column("urlValue", .text)
                t.column("filesJSON", .text)
                t.column("blobData", .blob)
                t.column("thumbnailData", .blob)
                t.column("blobSize", .integer)
                t.column("imageWidth", .integer)
                t.column("imageHeight", .integer)
                t.column("contentHash", .blob)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: """
                INSERT INTO grdb_migrations (identifier)
                VALUES ('createClipboardEntries'), ('addBlobMetadata')
                """)

            func insertRow(
                _ id: String, _ interval: TimeInterval, _ type: String,
                text: String? = nil, url: String? = nil, files: String? = nil, blob: Data? = nil
            ) throws {
                try db.execute(
                    sql: """
                        INSERT INTO clipboard_entries
                            (id, createdAt, type, preview, textValue, urlValue, filesJSON, blobData)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [id, createdAt.addingTimeInterval(interval), type, type, text, url, files, blob]
                )
            }

            try insertRow("11111111-1111-1111-1111-111111111111", 4, "image", blob: pngData)
            try insertRow("22222222-2222-2222-2222-222222222222", 3, "text", text: textValue)
            try insertRow("33333333-3333-3333-3333-333333333333", 2, "rtf", blob: rtfData)
            try insertRow("44444444-4444-4444-4444-444444444444", 1, "url", url: urlValue)
            try insertRow("55555555-5555-5555-5555-555555555555", 0, "file", files: filesJSON)
        }

        // init 触发剩余的 backfillBlobMetadata 迁移。
        let store = GRDBClipboardStore(databaseURL: dbURL)
        XCTAssertNil(store.storageErrorMessage)

        let byID = Dictionary(
            uniqueKeysWithValues: store.loadEntries().map { ($0.id.uuidString, $0) }
        )
        XCTAssertEqual(byID.count, 5, "五个类型的行都应保留并完成回填")

        // image：blobSize + 宽高 + hash
        let imageRow = byID["11111111-1111-1111-1111-111111111111"]
        XCTAssertEqual(imageRow?.blobSize, Int64(pngData.count))
        XCTAssertEqual(imageRow?.imageWidth, 4)
        XCTAssertEqual(imageRow?.imageHeight, 2)
        XCTAssertEqual(imageRow?.contentHash, Data(SHA256.hash(data: pngData)))

        // text：UTF-8 字节数 + hash
        let textRow = byID["22222222-2222-2222-2222-222222222222"]
        XCTAssertEqual(textRow?.blobSize, Int64(textValue.utf8.count))
        XCTAssertNil(textRow?.imageWidth)
        XCTAssertNil(textRow?.imageHeight)
        XCTAssertEqual(textRow?.contentHash, Data(SHA256.hash(data: Data(textValue.utf8))))

        // rtf：blob 字节数 + hash
        let rtfRow = byID["33333333-3333-3333-3333-333333333333"]
        XCTAssertEqual(rtfRow?.blobSize, Int64(rtfData.count))
        XCTAssertEqual(rtfRow?.contentHash, Data(SHA256.hash(data: rtfData)))

        // url：现有行为只回填 hash，blobSize 保持 0
        let urlRow = byID["44444444-4444-4444-4444-444444444444"]
        XCTAssertEqual(urlRow?.blobSize, 0)
        XCTAssertEqual(urlRow?.contentHash, Data(SHA256.hash(data: Data(urlValue.utf8))))

        // file：现有行为只回填 hash（路径按 \n 连接），blobSize 保持 0
        let fileRow = byID["55555555-5555-5555-5555-555555555555"]
        XCTAssertEqual(fileRow?.blobSize, 0)
        XCTAssertEqual(
            fileRow?.contentHash,
            Data(SHA256.hash(data: Data("file:///tmp/a.txt\nfile:///tmp/b.txt".utf8)))
        )
    }
}
