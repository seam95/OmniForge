import Foundation

/// 桌面便签存储协议；生产实现为 GRDB SQLite，测试用假实现。
protocol StickyNoteStore: AnyObject {
    func loadNotes() -> [StickyNote]
    /// upsert：同 id 已存在则整行覆盖。
    func saveNote(_ note: StickyNote)
    func deleteNote(id: UUID)
    func releaseMemory()
}
