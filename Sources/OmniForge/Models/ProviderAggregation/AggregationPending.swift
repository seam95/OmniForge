import Foundation

/// 写前意图 — 成员增删与模式切换的同一操作里提交的「意图」：
/// 目标工具 + 提交时的**全栈快照**（含另一工具未被影响的一半，前滚时整体写回）。
/// `published` 是 `partial` 语义的唯一判据：发布第一个文件前置 true 并落盘，
/// 此后任何一步崩溃都按「已进入发布流程」前滚（幂等补完）。
struct AggregationPending: Codable, Equatable {
    let tool: ProviderTool
    let stack: AggregationStack
    var published: Bool
}

/// 崩溃恢复判定。
enum AggregationRecovery: Equatable {
    /// 什么都没发布（published == false）→ 回到原状，客户端文件未被触碰。
    case discarded
    /// 已进入发布流程（published == true）→ 幂等补完到新名单。
    case rolledForward
}
