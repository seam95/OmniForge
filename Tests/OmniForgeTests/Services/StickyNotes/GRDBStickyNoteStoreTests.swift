import XCTest
import GRDB
@testable import OmniForge

final class GRDBStickyNoteStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBStickyNoteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("notes.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeStore() -> GRDBStickyNoteStore {
        GRDBStickyNoteStore(databaseURL: databaseURL)
    }

    func test_loadNotes_onEmptyDatabase_returnsEmptyArray() {
        let store = makeStore()
        XCTAssertEqual(store.loadNotes(), [])
    }

    func test_saveNote_andLoad_roundTripsAllFields() throws {
        let store = makeStore()
        let note = StickyNote(
            content: "买牛奶\n回邮件",
            color: .mint,
            x: 100.5,
            y: -42.25,
            width: 320,
            height: 260,
            pinned: true,
            hidden: false,
            completed: true,
            collapsed: true,
            fontSize: 20,
            reminderAt: Date(timeIntervalSince1970: 1_800_000_000),
            reminderFiredAt: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        store.saveNote(note)
        let loaded = store.loadNotes()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0], note)
    }

    func test_loadNotes_afterCollapsedColumnMigration_defaultsToFalse() throws {
        // 模拟 v1 旧库：无 collapsed 列的表结构与一行旧数据。
        // 须同步登记 createStickyNote 已应用，否则新 store 会重跑建表迁移而失败。
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('createStickyNote')")
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
                t.column("reminderAt", .double)
                t.column("reminderFiredAt", .double)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.execute(sql: """
                INSERT INTO stickyNote (id, content, color, x, y, width, height, pinned, hidden, completed, createdAt, updatedAt)
                VALUES ('00000000-0000-0000-0000-000000000001', '旧便签', 'yellow', 0, 0, 320, 260, 0, 0, 0, 1000, 1000)
                """)
        }

        // 迁移在 store 初始化时执行
        let store = makeStore()
        let loaded = store.loadNotes()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "旧便签")
        XCTAssertEqual(loaded[0].collapsed, false)
    }

    func test_loadNotes_afterFontSizeColumnMigration_defaultsToStandardLevel() throws {
        // 模拟 v2 旧库：无 fontSize 列的表结构与一行旧数据。
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('createStickyNote')")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('addStickyNoteCollapsed')")
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
                t.column("collapsed", .boolean).notNull().defaults(to: false)
                t.column("reminderAt", .double)
                t.column("reminderFiredAt", .double)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.execute(sql: """
                INSERT INTO stickyNote (id, content, color, x, y, width, height, pinned, hidden, completed, collapsed, createdAt, updatedAt)
                VALUES ('00000000-0000-0000-0000-000000000001', '旧便签', 'yellow', 0, 0, 320, 260, 0, 0, 0, 0, 1000, 1000)
                """)
        }

        // v3 迁移在 store 初始化时执行
        let store = makeStore()
        let loaded = store.loadNotes()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].fontSize, StickyNote.defaultFontSize)
    }

    func test_saveNote_roundTripsNilReminderFields() {
        let store = makeStore()
        let note = StickyNote(content: "", color: .yellow)

        store.saveNote(note)
        let loaded = store.loadNotes()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].reminderAt)
        XCTAssertNil(loaded[0].reminderFiredAt)
    }

    func test_saveNote_upsertsExistingRow() {
        let store = makeStore()
        var note = StickyNote(content: "初稿", color: .blue)
        store.saveNote(note)

        note.content = "定稿"
        note.color = .pink
        note.pinned = true
        store.saveNote(note)

        let loaded = store.loadNotes()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "定稿")
        XCTAssertEqual(loaded[0].color, .pink)
        XCTAssertTrue(loaded[0].pinned)
    }

    func test_deleteNote_removesRow() {
        let store = makeStore()
        let note = StickyNote(content: "待删除", color: .yellow)
        store.saveNote(note)

        store.deleteNote(id: note.id)

        XCTAssertEqual(store.loadNotes(), [])
    }

    func test_loadNotes_returnsCreatedAtAscending() throws {
        let store = makeStore()
        let early = StickyNote(
            content: "早",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let late = StickyNote(
            content: "晚",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        store.saveNote(late)
        store.saveNote(early)

        let loaded = store.loadNotes()
        XCTAssertEqual(loaded.map(\.content), ["早", "晚"])
    }
}
