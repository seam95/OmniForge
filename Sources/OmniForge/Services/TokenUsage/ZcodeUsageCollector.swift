import Combine
import Foundation

/// zcode 用量采集器（B 类 SQLite，opencode-fork schema）。
///
/// 数据源：`~/.zcode/cli/db/db.sqlite`（`$ZCODE_HOME` 覆盖）。复用 opencode 的
/// `message` 表读取与差分；按 `providerID` **黑名单**过滤 anthropic/openai/google
/// 子代理（这些 turn 由 Claude/Codex/Gemini 独立采集，避免重复计数；参考
/// TokenTracker isZcodeNativeMessage —— 黑名单而非白名单，自定义 provider 的
/// 随机 UUID 不会被静默丢弃）。
///
/// 隐私红线（SPEC 2.6）：DB 只读打开，只读身份/模型/时间/用量字段。
final class ZcodeUsageCollector: OpencodeSchemaCollectorBase {
    static func defaultDatabaseURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["ZCODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("cli/db/db.sqlite")
        }
        return URL(fileURLWithPath: homePath + "/.zcode/cli/db/db.sqlite")
    }

    private let configuredDatabaseURL: URL

    init(
        store: UsageStoring,
        databaseURL: URL = ZcodeUsageCollector.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.configuredDatabaseURL = databaseURL
        super.init(
            provider: .zcode,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var schemaDatabaseURL: URL? { configuredDatabaseURL }

    override var usesRealDirectories: Bool {
        configuredDatabaseURL == ZcodeUsageCollector.defaultDatabaseURL()
    }

    override func isNativeMessage(_ data: OpencodeMessageData) -> Bool {
        let provider = (data.providerID ?? data.provider ?? "").lowercased()
        guard !provider.isEmpty else { return false }
        return !(provider.contains("anthropic")
            || provider.contains("openai")
            || provider.contains("google"))
    }
}