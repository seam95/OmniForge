import Foundation

protocol ClipboardStore {
    /// 最近一次存储层错误（nil = 健康）。失败必须可见可重试，
    /// 不得伪装为空库后继续静默丢弃写入（审查 R19，对齐 QuickPhraseStore）。
    var storageErrorMessage: String? { get }

    func loadEntries() -> [ClipboardEntry]
    func saveEntry(_ entry: ClipboardEntry)
    func deleteEntries(ids: Set<UUID>)
    func loadFullContent(for entryID: UUID) -> ClipboardContent?
    func releaseMemory()
}
