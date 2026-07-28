import CryptoKit
import Foundation
import GRDB
import ImageIO

final class GRDBClipboardStore: ClipboardStore {
    private let databaseQueue: DatabaseQueue?

    init(
        databaseURL: URL,
        fileManager: FileManager = .default,
        legacyStoreDirectoryURL: URL? = nil,
        removeLegacyStoreFiles: Bool = false
    ) {
        do {
            try Self.ensureParentDirectory(for: databaseURL, fileManager: fileManager)

            var configuration = Configuration()
            configuration.foreignKeysEnabled = true

            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try Self.makeMigrator().migrate(queue)
            self.databaseQueue = queue

            if removeLegacyStoreFiles {
                let legacyDirectoryURL = legacyStoreDirectoryURL ?? databaseURL.deletingLastPathComponent()
                Self.removeLegacyStoreFiles(in: legacyDirectoryURL, fileManager: fileManager)
            }
        } catch {
            self.databaseQueue = nil
        }
    }

    // MARK: - 轻量加载（排除 blobData）

    func loadEntries() -> [ClipboardEntry] {
        guard let databaseQueue else {
            return []
        }

        do {
            return try databaseQueue.read { db in
                let columns: [Column] = [
                    Column("id"), Column("createdAt"), Column("type"), Column("preview"),
                    Column("sourceAppBundleID"), Column("sourceAppName"),
                    Column("urlValue"), Column("filesJSON"),
                    Column("thumbnailData"),
                    Column("blobSize"), Column("imageWidth"), Column("imageHeight"), Column("contentHash")
                ]
                let records = try ClipboardEntryDBRecord
                    .select(columns)
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
                return records.compactMap { $0.toLightweightClipboardEntry() }
            }
        } catch {
            return []
        }
    }

    func saveEntries(_ entries: [ClipboardEntry]) {
        guard let databaseQueue else {
            return
        }

        do {
            try databaseQueue.write { db in
                try ClipboardEntryDBRecord.deleteAll(db)
                for entry in entries {
                    var record = ClipboardEntryDBRecord.from(entry)
                    try record.insert(db)
                }
            }
        } catch {
            return
        }
    }

    // MARK: - 增量方法

    func saveEntry(_ entry: ClipboardEntry) {
        guard let databaseQueue else { return }

        do {
            try databaseQueue.write { db in
                var record = ClipboardEntryDBRecord.from(entry)
                try record.save(db)
            }
        } catch {
            return
        }
    }

    func deleteEntries(ids: Set<UUID>) {
        guard let databaseQueue, !ids.isEmpty else { return }

        do {
            try databaseQueue.write { db in
                let idStrings = ids.map(\.uuidString)
                try ClipboardEntryDBRecord
                    .filter(idStrings.contains(Column("id")))
                    .deleteAll(db)
            }
        } catch {
            return
        }
    }

    func loadFullContent(for entryID: UUID) -> ClipboardContent? {
        guard let databaseQueue else { return nil }

        do {
            return try databaseQueue.read { db in
                let columns = [
                    Column("type"), Column("textValue"), Column("urlValue"),
                    Column("filesJSON"), Column("blobData")
                ]
                guard let record = try ClipboardContentDBRecord
                    .select(columns)
                    .filter(Column("id") == entryID.uuidString)
                    .fetchOne(db) else {
                    return nil
                }
                return record.clipboardContent
            }
        } catch {
            return nil
        }
    }

    func releaseMemory() {
        databaseQueue?.releaseMemory()
    }

    // MARK: - Private

    private static func ensureParentDirectory(for databaseURL: URL, fileManager: FileManager) throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directoryURL.path) {
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func removeLegacyStoreFiles(in directoryURL: URL, fileManager: FileManager) {
        let entriesFileURL = directoryURL.appendingPathComponent("entries.json")
        let blobsDirectoryURL = directoryURL.appendingPathComponent("blobs", isDirectory: true)

        if fileManager.fileExists(atPath: entriesFileURL.path) {
            try? fileManager.removeItem(at: entriesFileURL)
        }
        if fileManager.fileExists(atPath: blobsDirectoryURL.path) {
            try? fileManager.removeItem(at: blobsDirectoryURL)
        }
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createClipboardEntries") { db in
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
            }
        }

        migrator.registerMigration("addBlobMetadata") { db in
            try db.alter(table: "clipboard_entries") { t in
                t.add(column: "blobSize", .integer)
                t.add(column: "imageWidth", .integer)
                t.add(column: "imageHeight", .integer)
                t.add(column: "contentHash", .blob)
            }
        }

        migrator.registerMigration("backfillBlobMetadata") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, type, blobData, textValue, urlValue, filesJSON
                FROM clipboard_entries
                WHERE blobSize IS NULL
                """)

            for row in rows {
                let id: String = row["id"]
                let type: String = row["type"]
                let blobData: Data? = row["blobData"]
                let textValue: String? = row["textValue"]
                let urlValue: String? = row["urlValue"]
                let filesJSON: String? = row["filesJSON"]

                var blobSize: Int64 = 0
                var imageWidth: Int?
                var imageHeight: Int?
                var contentHash: Data?

                switch type {
                case "image":
                    if let data = blobData {
                        blobSize = Int64(data.count)
                        contentHash = Data(SHA256.hash(data: data))
                        // 读取图片尺寸
                        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                        if let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
                           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                            imageWidth = props[kCGImagePropertyPixelWidth] as? Int
                            imageHeight = props[kCGImagePropertyPixelHeight] as? Int
                        }
                    }
                case "rtf", "unknown":
                    if let data = blobData {
                        blobSize = Int64(data.count)
                        contentHash = Data(SHA256.hash(data: data))
                    }
                case "text":
                    if let text = textValue {
                        blobSize = Int64(text.utf8.count)
                        contentHash = Data(SHA256.hash(data: Data(text.utf8)))
                    }
                case "url":
                    if let url = urlValue {
                        contentHash = Data(SHA256.hash(data: Data(url.utf8)))
                    }
                case "file":
                    if let json = filesJSON,
                       let data = json.data(using: .utf8),
                       let values = try? JSONDecoder().decode([String].self, from: data) {
                        let joined = values.joined(separator: "\n")
                        contentHash = Data(SHA256.hash(data: Data(joined.utf8)))
                    }
                default:
                    break
                }

                try db.execute(sql: """
                    UPDATE clipboard_entries
                    SET blobSize = ?, imageWidth = ?, imageHeight = ?, contentHash = ?
                    WHERE id = ?
                    """, arguments: [blobSize, imageWidth, imageHeight, contentHash, id])
            }
        }

        return migrator
    }
}

private struct ClipboardEntryDBRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipboard_entries"

    let id: String
    let createdAt: Date
    let type: String
    let preview: String
    let sourceAppBundleID: String?
    let sourceAppName: String?

    let textValue: String?
    let urlValue: String?
    let filesJSON: String?
    let blobData: Data?
    let thumbnailData: Data?

    let blobSize: Int64?
    let imageWidth: Int?
    let imageHeight: Int?
    let contentHash: Data?

    static func from(_ entry: ClipboardEntry) -> ClipboardEntryDBRecord {
        let filesJSON: String?
        let textValue: String?
        let urlValue: String?
        let blobData: Data?

        switch entry.content {
        case .text(let text):
            textValue = text
            urlValue = nil
            filesJSON = nil
            blobData = nil
        case .url(let url):
            textValue = nil
            urlValue = url.absoluteString
            filesJSON = nil
            blobData = nil
        case .files(let files):
            textValue = nil
            urlValue = nil
            filesJSON = try? String(
                data: JSONEncoder().encode(files.map(\.absoluteString)),
                encoding: .utf8
            )
            blobData = nil
        case .image(let data):
            textValue = nil
            urlValue = nil
            filesJSON = nil
            blobData = data
        case .rtf(let data):
            textValue = nil
            urlValue = nil
            filesJSON = nil
            blobData = data
        case .unknown(let data):
            textValue = nil
            urlValue = nil
            filesJSON = nil
            blobData = data
        }

        return ClipboardEntryDBRecord(
            id: entry.id.uuidString,
            createdAt: entry.createdAt,
            type: entry.type.rawValue,
            preview: entry.preview,
            sourceAppBundleID: entry.sourceAppBundleID,
            sourceAppName: entry.sourceAppName,
            textValue: textValue,
            urlValue: urlValue,
            filesJSON: filesJSON,
            blobData: blobData,
            thumbnailData: entry.thumbnailData,
            blobSize: entry.blobSize,
            imageWidth: entry.imageWidth,
            imageHeight: entry.imageHeight,
            contentHash: entry.contentHash
        )
    }

    /// 完整反序列化（含 blobData）
    func toClipboardEntry() -> ClipboardEntry? {
        guard let uuid = UUID(uuidString: id),
              let contentType = ClipboardContentType(rawValue: type) else {
            return nil
        }

        let content: ClipboardContent
        switch contentType {
        case .text:
            guard let textValue else { return nil }
            content = .text(textValue)
        case .url:
            guard let urlValue, let url = URL(string: urlValue) else { return nil }
            content = .url(url)
        case .file:
            guard let filesJSON,
                  let data = filesJSON.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String].self, from: data) else {
                return nil
            }
            let urls = values.compactMap(URL.init(string:))
            guard urls.count == values.count else {
                return nil
            }
            content = .files(urls)
        case .image:
            content = .image(blobData)
        case .rtf:
            content = .rtf(blobData)
        case .unknown:
            content = .unknown(blobData)
        }

        return ClipboardEntry(
            id: uuid,
            createdAt: createdAt,
            type: contentType,
            preview: preview,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            content: content,
            thumbnailData: thumbnailData,
            blobSize: blobSize,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            contentHash: contentHash
        )
    }

    /// 轻量反序列化（blob 类型的 Data 为 nil）
    func toLightweightClipboardEntry() -> ClipboardEntry? {
        guard let uuid = UUID(uuidString: id),
              let contentType = ClipboardContentType(rawValue: type) else {
            return nil
        }

        let content: ClipboardContent
        switch contentType {
        case .text:
            content = .text(nil)
        case .url:
            guard let urlValue, let url = URL(string: urlValue) else { return nil }
            content = .url(url)
        case .file:
            guard let filesJSON,
                  let data = filesJSON.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String].self, from: data) else {
                return nil
            }
            let urls = values.compactMap(URL.init(string:))
            guard urls.count == values.count else {
                return nil
            }
            content = .files(urls)
        case .image:
            content = .image(nil)
        case .rtf:
            content = .rtf(nil)
        case .unknown:
            content = .unknown(nil)
        }

        return ClipboardEntry(
            id: uuid,
            createdAt: createdAt,
            type: contentType,
            preview: preview,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            content: content,
            thumbnailData: thumbnailData,
            blobSize: blobSize,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            contentHash: contentHash
        )
    }
}

private struct ClipboardContentDBRecord: Decodable, FetchableRecord, TableRecord {
    static let databaseTableName = "clipboard_entries"

    let type: String
    let textValue: String?
    let urlValue: String?
    let filesJSON: String?
    let blobData: Data?

    var clipboardContent: ClipboardContent? {
        guard let contentType = ClipboardContentType(rawValue: type) else {
            return nil
        }

        switch contentType {
        case .text:
            guard let textValue else { return nil }
            return .text(textValue)
        case .url:
            guard let urlValue, let url = URL(string: urlValue) else { return nil }
            return .url(url)
        case .file:
            guard let filesJSON,
                  let data = filesJSON.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String].self, from: data)
            else { return nil }
            let urls = values.compactMap(URL.init(string:))
            guard urls.count == values.count else { return nil }
            return .files(urls)
        case .image:
            return .image(blobData)
        case .rtf:
            return .rtf(blobData)
        case .unknown:
            return .unknown(blobData)
        }
    }
}
