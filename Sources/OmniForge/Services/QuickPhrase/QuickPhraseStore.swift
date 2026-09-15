import Foundation

/// 快捷短语存储协议（审查 R19：存储失败必须可见可重试）：
/// 全链 throws — 数据库不可用、读/写失败都以错误上抛，
/// 调用方不得把失败伪装为空库或无条件提交界面状态。
protocol QuickPhraseStore {
    /// 读取全部短语；数据库不可用或读失败时抛错（不得静默返回空数组）。
    func loadPhrases() throws -> [QuickPhraseEntry]
    func savePhrase(_ phrase: QuickPhraseEntry) throws
    func deletePhrase(id: UUID) throws
    func updatePhrase(_ phrase: QuickPhraseEntry) throws
    func releaseMemory()
}
