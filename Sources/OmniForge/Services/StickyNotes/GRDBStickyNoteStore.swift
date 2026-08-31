import Foundation
import GRDB

/// GRDB 生产实现。初始化失败时静默降级为空库（对齐 GRDBQuickPhraseStore 模式）。
final class GRDBStickyNoteStore: StickyNoteStore {
    private let databaseQueue: DatabaseQueue?

    init(databaseURL: URL) {
        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var dbQueue: DatabaseQueue?
        do {
            dbQueue = try DatabaseQueue(path: databaseURL.path)
            guard let queue = dbQueue else {
                self.databaseQueue = nil
                return
            }
            try Self.databaseMigrator.migrate(queue)
        } catch {
            print("[GRDBStickyNoteStore] Failed to initialize database: \(error)")
            self.databaseQueue = nil
            return
        }
        self.databaseQueue = dbQueue
    }

    private static var databaseMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createStickyNote") { db in
            try db.create(table: "stickyNote") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("content", .text).notNull()
                t.column("color", .text).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("completed", .boolean).notNull().defaults(to: false)
                // 秒级时间戳，nil = 未设置
                t.column("reminderAt", .double)
                t.column("reminderFiredAt", .double)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }
        // v2：折叠（正文收起为工具栏条）持久化状态。
        migrator.registerMigration("addStickyNoteCollapsed") { db in
            try db.alter(table: "stickyNote") { t in
                t.add(column: "collapsed", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }

    func loadNotes() -> [StickyNote] {
        guard let databaseQueue else { return [] }
        var notes: [StickyNote] = []
        do {
            try databaseQueue.read { db in
                notes = try StickyNoteDBRecord
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
                    .compactMap { $0.toStickyNote() }
            }
        } catch {
            print("[GRDBStickyNoteStore] Failed to load notes: \(error)")
        }
        return notes
    }

    func saveNote(_ note: StickyNote) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                let record = StickyNoteDBRecord(from: note)
                try record.save(db)
            }
        } catch {
            print("[GRDBStickyNoteStore] Failed to save note: \(error)")
        }
    }

    func deleteNote(id: UUID) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                try StickyNoteDBRecord.filter(Column("id") == id.uuidString).deleteAll(db)
            }
        } catch {
            print("[GRDBStickyNoteStore] Failed to delete note: \(error)")
        }
    }

    func releaseMemory() {
        databaseQueue?.releaseMemory()
    }
}

private struct StickyNoteDBRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var content: String
    var color: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var pinned: Bool
    var hidden: Bool
    var completed: Bool
    var collapsed: Bool
    var reminderAt: Double?
    var reminderFiredAt: Double?
    var createdAt: Double
    var updatedAt: Double

    static let databaseTableName = "stickyNote"

    init(from note: StickyNote) {
        self.id = note.id.uuidString
        self.content = note.content
        self.color = note.color.rawValue
        self.x = note.x
        self.y = note.y
        self.width = note.width
        self.height = note.height
        self.pinned = note.pinned
        self.hidden = note.hidden
        self.completed = note.completed
        self.collapsed = note.collapsed
        self.reminderAt = note.reminderAt?.timeIntervalSince1970
        self.reminderFiredAt = note.reminderFiredAt?.timeIntervalSince1970
        self.createdAt = note.createdAt.timeIntervalSince1970
        self.updatedAt = note.updatedAt.timeIntervalSince1970
    }

    func toStickyNote() -> StickyNote? {
        guard let uuid = UUID(uuidString: id),
              let color = StickyNoteColor(rawValue: color) else {
            return nil
        }
        return StickyNote(
            id: uuid,
            content: content,
            color: color,
            x: x,
            y: y,
            width: width,
            height: height,
            pinned: pinned,
            hidden: hidden,
            completed: completed,
            collapsed: collapsed,
            reminderAt: reminderAt.map(Date.init(timeIntervalSince1970:)),
            reminderFiredAt: reminderFiredAt.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
