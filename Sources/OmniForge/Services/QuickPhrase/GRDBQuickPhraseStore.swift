import Foundation
import GRDB

final class GRDBQuickPhraseStore: QuickPhraseStore {
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
            print("[GRDBQuickPhraseStore] Failed to initialize database: \(error)")
            self.databaseQueue = nil
            return
        }
        self.databaseQueue = dbQueue
    }

    private static var databaseMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createQuickPhrases") { db in
            try db.create(table: "quick_phrases") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("content", .text).notNull()
                t.column("group", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        return migrator
    }

    func loadPhrases() -> [QuickPhraseEntry] {
        guard let databaseQueue else { return [] }
        var phrases: [QuickPhraseEntry] = []
        do {
            try databaseQueue.read { db in
                phrases = try QuickPhraseDBRecord
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
                    .map { $0.toQuickPhraseEntry() }
            }
        } catch {
            print("[GRDBQuickPhraseStore] Failed to load phrases: \(error)")
        }
        return phrases
    }

    func savePhrase(_ phrase: QuickPhraseEntry) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                var record = QuickPhraseDBRecord(from: phrase)
                try record.save(db)
            }
        } catch {
            print("[GRDBQuickPhraseStore] Failed to save phrase: \(error)")
        }
    }

    func deletePhrase(id: UUID) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                try QuickPhraseDBRecord.filter(Column("id") == id.uuidString).deleteAll(db)
            }
        } catch {
            print("[GRDBQuickPhraseStore] Failed to delete phrase: \(error)")
        }
    }

    func updatePhrase(_ phrase: QuickPhraseEntry) {
        savePhrase(phrase)
    }

    func releaseMemory() {
        databaseQueue?.releaseMemory()
    }
}

private struct QuickPhraseDBRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var content: String
    var group: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "quick_phrases"

    init(from phrase: QuickPhraseEntry) {
        self.id = phrase.id.uuidString
        self.content = phrase.content
        self.group = phrase.group
        self.createdAt = phrase.createdAt
        self.updatedAt = phrase.updatedAt
    }

    func toQuickPhraseEntry() -> QuickPhraseEntry {
        guard let id = UUID(uuidString: id) else {
            return QuickPhraseEntry(content: content, group: group, createdAt: createdAt, updatedAt: updatedAt)
        }
        return QuickPhraseEntry(id: id, content: content, group: group, createdAt: createdAt, updatedAt: updatedAt)
    }

    enum Columns: String, ColumnExpression {
        case id, content, group, createdAt, updatedAt
    }
}
