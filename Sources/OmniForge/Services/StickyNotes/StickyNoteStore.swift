import Foundation

/// 桌面便签存储协议；生产实现为 GRDB SQLite，测试用假实现。
/// saveNote 抛错（可观察保存结果）：防抖只是减少写频率，
/// 退出/卸载 flush 依赖成功与否决定能否清脏标记（审查 R12）。
protocol StickyNoteStore: AnyObject {
    func loadNotes() -> [StickyNote]
    /// upsert：同 id 已存在则整行覆盖。数据库不可用或写失败时抛错。
    func saveNote(_ note: StickyNote) throws
    func deleteNote(id: UUID)
    func releaseMemory()
}
