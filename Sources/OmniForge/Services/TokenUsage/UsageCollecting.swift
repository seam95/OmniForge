import Combine
import Foundation

/// 用量采集协议 — 每 provider 一个实现（三类分型，参考 01；本期 A 类 JSONL）。
///
/// 实现约定：
/// - `start()` 立即返回，回填/扫描在后台执行（不阻塞启动）；
/// - 每次扫描完毕后通过 `onUsageDidChange` 通知（主线程回调）；
/// - 首次（无既有游标数据的）扫描为「回填」，以 `onBackfillStateChange` 首尾标记。
protocol UsageCollecting: AnyObject {
    var provider: TokenUsageProvider { get }

    /// 每次扫描完成后调用（主线程），参数为该 provider。
    var onUsageDidChange: ((TokenUsageProvider) -> Void)? { get set }
    /// 回填状态首尾标记（主线程）。
    var onBackfillStateChange: ((Bool) -> Void)? { get set }

    func start()
    func stop()
}
