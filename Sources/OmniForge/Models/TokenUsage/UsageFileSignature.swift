import Foundation

/// 会话文件版本指纹（大小 + 修改时间）。
///
/// 非游标型采集器（DSH / Antigravity）用它判断文件是否变化：同一指纹视为内容
/// 未变，无需重新解析。指纹随 `ScanCommit` 持久化到用量库，进程重启后仍生效；
/// 仅存于内存时，每次冷启动都会全量重解析历史会话，造成启动期内存峰值。
struct UsageFileSignature: Equatable {
    var size: Int64
    var modifiedAt: Date

    /// 指纹相等判定：修改时间按 1 毫秒容差比较。
    ///
    /// `Date` 在 `attributesOfItem[.modificationDate]` 与
    /// `timeIntervalSince1970` 存储/读回之间往返存在亚微秒级浮点误差
    /// （实测约 0.24µs）。严格相等会让持久化指纹永远不命中，每次冷启动
    /// 仍全量重解析。1 毫秒容差远大于该误差，同时足以识别真实文件变化。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size
            && abs(lhs.modifiedAt.timeIntervalSince1970 - rhs.modifiedAt.timeIntervalSince1970) < 0.001
    }
}
