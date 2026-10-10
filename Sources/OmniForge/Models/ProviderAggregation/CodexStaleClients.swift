import Foundation

/// Codex 陈旧客户端检测结果 — daemon（托管守护进程）与 others（其余 app-server 客户端）
/// 分别报告，界面据此给不同的重启指引。
struct CodexStaleClients: Equatable, Codable {
    let daemon: Bool
    let others: Bool
}

/// 一次目录代记录：代写入时刻（epoch ms）+ 目录字节指纹（非我方目录记 `"none"`）。
struct CodexCatalogGeneration: Codable, Equatable {
    let sinceMs: Int64
    let fingerprint: String
}
