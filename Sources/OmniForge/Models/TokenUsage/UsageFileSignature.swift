import Foundation

/// 会话文件版本指纹（大小 + 修改时间）。
///
/// 非游标型采集器（DSH / Antigravity）用它判断文件是否变化：同一指纹视为内容
/// 未变，无需重新解析。指纹随 `ScanCommit` 持久化到用量库，进程重启后仍生效；
/// 仅存于内存时，每次冷启动都会全量重解析历史会话，造成启动期内存峰值。
struct UsageFileSignature: Equatable {
    var size: Int64
    var modifiedAt: Date
}
