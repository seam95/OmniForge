import CryptoKit
import Foundation
import GRDB
import ImageIO
import os

final class GRDBClipboardStore: ClipboardStore {
    private static let logger = Logger(subsystem: "com.omniforge.clipboard", category: "store")

    private let databaseQueue: DatabaseQueue?
    /// 最近一次存储层错误；nil = 健康。init 失败与读写 catch 都会更新，
    /// 由 Manager 透出为界面错误态（不再伪装空库静默丢写）。
    private(set) var storageErrorMessage: String?

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

            do {
                self.databaseQueue = try Self.setupDatabase(at: databaseURL, configuration: configuration)
            } catch {
                // 库文件损坏（如 SQLITE_NOTADB / SQLITE_CORRUPT）时，界面上的「重试」
                // 永远走同一条失败路径，等于功能报废。这里把损坏文件改名保留现场，
                // 再以空库重建重试一次；改名失败或非损坏类错误（磁盘满、权限等）
                // 重建也救不了，维持原来的报错现状交给用户处理。
                guard Self.isDatabaseCorruption(error),
                      let renamedURL = Self.quarantineCorruptedDatabase(at: databaseURL, fileManager: fileManager)
                else {
                    throw error
                }
                Self.logger.error(
                    "clipboard database corrupted; moved aside to \(renamedURL.lastPathComponent, privacy: .public) and rebuilt an empty store"
                )
                self.databaseQueue = try Self.setupDatabase(at: databaseURL, configuration: configuration)
            }

            if removeLegacyStoreFiles {
                let legacyDirectoryURL = legacyStoreDirectoryURL ?? databaseURL.deletingLastPathComponent()
                Self.removeLegacyStoreFiles(in: legacyDirectoryURL, fileManager: fileManager)
            }
        } catch {
            Self.logger.error("clipboard store init failed: \(error.localizedDescription, privacy: .public)")
            self.databaseQueue = nil
            self.storageErrorMessage = error.localizedDescription
        }
    }

    // MARK: - 轻量加载（排除 blobData）

    /// 清理历史遗留的不可解码图片条目：部分应用（微信）在 .png 槽位只写几字节
    /// 占位符，旧版采集照存不误，条目永远「无法预览」。合法 PNG/TIFF 不可能
    /// 小于 32 字节，按长度一刀切（SQL 级，启动时零成本）。
    private static func pruneUndecodableImageEntries(in queue: DatabaseQueue) {
        do {
            let deleted = try queue.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM clipboard_entries
                        WHERE type = 'image' AND (blobSize IS NULL OR blobSize < 32)
                        """
                )
                return db.changesCount
            }
            if deleted > 0 {
                Self.logger.notice("pruned \(deleted, privacy: .public) undecodable image entries")
            }
        } catch {
            Self.logger.error("prune undecodable image entries failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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
            Self.logger.error("loadEntries failed: \(error.localizedDescription, privacy: .public)")
            storageErrorMessage = error.localizedDescription
            return []
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
            Self.logger.error("saveEntry failed: \(error.localizedDescription, privacy: .public)")
            storageErrorMessage = error.localizedDescription
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
            Self.logger.error("deleteEntries failed: \(error.localizedDescription, privacy: .public)")
            storageErrorMessage = error.localizedDescription
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

    /// 建库三步（建队列 → 迁移 → 清理占位图片）。首次打开与损坏重建共用。
    private static func setupDatabase(at databaseURL: URL, configuration: Configuration) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(queue)
        Self.pruneUndecodableImageEntries(in: queue)
        return queue
    }

    /// 仅库文件损坏类错误才值得自动重建：SQLITE_NOTADB（文件根本不是数据库）、
    /// SQLITE_CORRUPT（磁盘镜像损坏）。其他错误（磁盘满、权限等）重建空库无济于事。
    private static func isDatabaseCorruption(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        return dbError.resultCode == .SQLITE_NOTADB || dbError.resultCode == .SQLITE_CORRUPT
    }

    /// 把损坏库文件改名保留现场：`entries.sqlite` → `entries.sqlite.corrupt-<yyyyMMdd-HHmmss>`。
    /// 不直接删除：保留现场让用户有机会找回历史数据，也便于事后排查损坏原因。
    /// 残留的 `-wal` / `-shm` 一并改名，避免旧日志干扰新库重建。
    /// 任一步失败（如目标名已存在）返回 nil，调用方维持报错现状。
    private static func quarantineCorruptedDatabase(at databaseURL: URL, fileManager: FileManager) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())

        var movedURLs: [URL] = []
        let sidecarSuffixes = ["", "-wal", "-shm"]
        for suffix in sidecarSuffixes {
            let sourceURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let targetURL = URL(fileURLWithPath: sourceURL.path + ".corrupt-" + stamp)
            guard !fileManager.fileExists(atPath: targetURL.path),
                  (try? fileManager.moveItem(at: sourceURL, to: targetURL)) != nil else {
                // 已改名的文件不回滚：同样是保留现场，无副作用。
                return nil
            }
            movedURLs.append(targetURL)
        }
        return movedURLs.first
    }

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
            // 旧库升级时待回填的行可能携带大量 blobData；fetchCursor 逐行流式处理，
            // 避免一次把全部行（含 blob）载入内存，造成升级瞬间的内存尖峰。
            // 游标在本迁移事务内耗尽后才提交（DatabaseMigrator 以事务包裹迁移闭包）。
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, type, blobData, textValue, urlValue, filesJSON
                FROM clipboard_entries
                WHERE blobSize IS NULL
                """)

            while let row = try cursor.next() {
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
