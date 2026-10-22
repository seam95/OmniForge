import Combine
import Foundation

/// Oh My Pi（OMP）用量采集器 — 与 Pi 共用同一 JSONL 记录格式与解析逻辑，只有扫描根不同。
///
/// 数据源：~/.omp/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl；
/// 主会话派生出的子代理写入同名目录：
/// <encoded-cwd>/<timestamp>_<uuid>/<AgentName>.jsonl（advisor 为 __advisor.<name>.jsonl）。
/// 每个子代理文件都是带自己 session 头的完整会话文件，递归扫描后独立解析、独立计会话；
/// 子代理目录与主会话文件物理分离，不会重复读取同一份 transcript。
///
/// 扫描根刻意固定为 home 相对路径、不读环境覆盖：OMP 与 Pi 共用 PI_CODING_AGENT_DIR，
/// 单一覆盖点会让两个采集器指向同一棵树并重复计数（对齐 tokscale omp.rs）。
final class OmpUsageCollector: PiUsageCollector {
    override class var defaultSessionsDirectory: URL {
        URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.omp/agent/sessions")
    }

    override init(
        store: UsageStoring,
        sessionsDirectory: URL = OmpUsageCollector.defaultSessionsDirectory,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        super.init(
            provider: .omp,
            sessionsDirectory: sessionsDirectory,
            store: store,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher,
            scanInterval: scanInterval
        )
    }

    /// 测试进程守卫判定用：OMP 的真实默认目录。
    override var usesRealDirectories: Bool {
        sessionsDirectory.standardizedFileURL == OmpUsageCollector.defaultSessionsDirectory.standardizedFileURL
    }
}
