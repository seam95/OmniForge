import XCTest
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
