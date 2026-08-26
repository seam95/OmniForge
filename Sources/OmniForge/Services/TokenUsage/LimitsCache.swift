import Foundation

/// 限额缓存策略 — 纯函数（TTL + reset 边界提前过期 + 过期窗口丢弃），独立可测（参考 06）。
enum LimitsCachePolicy {
    /// 内存 TTL：2 分钟。
    static let defaultTTL: TimeInterval = 2 * 60
    /// 下限 5 秒：防「reset 就在此刻」导致每次调用都全量拉取。
    static let minTTL: TimeInterval = 5

    /// 内存缓存过期点 = min(now + ttl, 最近的未来 reset)；下限 now + minTTL。
    static func expirationDate(now: Date, ttl: TimeInterval, windows: [LimitWindowKind: UsageWindow]) -> Date {
        var expiry = now.addingTimeInterval(ttl)
        let nextReset = windows.values.compactMap(\.resetAt).filter { $0 > now }.min()
        if let nextReset {
            expiry = min(expiry, nextReset)
        }
        return max(expiry, now.addingTimeInterval(minTTL))
    }

    /// 磁盘 last-good 读取：丢弃 resetAt 已过的窗口（无 reset 时间的窗口保留）。
    static func discardingExpiredWindows(
        _ windows: [LimitWindowKind: UsageWindow],
        at now: Date
    ) -> [LimitWindowKind: UsageWindow] {
        windows.filter { $0.value.resetAt.map { $0 > now } ?? true }
    }
}

/// 限额缓存门面 — 取数器/管理器解耦（测试注入替身；参考 06 四级缓存的前三级）。
protocol LimitsCaching: AnyObject {
    /// 内存新鲜快照（已过期/未存 → nil）。
    func memorySnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits?
    /// 最近的 last-good：内存优先，其次磁盘（读取时丢弃过期 reset 窗口）；无 → nil。
    func lastGoodSnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits?
    /// 成功快照：写内存（按 TTL/reset 计算到期）+ 磁盘原子写 + 清 429 冷却。
    func storeSuccess(_ limits: ProviderUsageLimits)
    /// 未配置：清空该 provider 的内存与磁盘 last-good。
    func storeNotConfigured(_ provider: TokenUsageProvider)
    /// 记录 429 冷却（持久化到磁盘，时长上限 1 小时）。
    func storeRateLimit(for provider: TokenUsageProvider, retryAt: Date)
    /// 正在生效的冷却截止时间；无/已过期 → nil。
    func cooldown(for provider: TokenUsageProvider) -> Date?
    func clearCooldown(for provider: TokenUsageProvider)
}

/// 限额缓存存储：内存（TTL + reset 提前过期）→ 磁盘 last-good（原子写 + 0600）→ 429 冷却持久化。
/// 数据边界（SPEC 2.6）：只存限额数字、时间戳与错误态，绝不存会话内容。
final class TokenUsageLimitsCache: LimitsCaching {
    /// 生产默认根目录：`~/Library/Application Support/app.omniforge`。
    static let defaultApplicationSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("app.omniforge", isDirectory: true)
    }()

    static let relativeDirectory = "TokenUsage"
    /// 冷却上限 1 小时（参考 06 `CLAUDE_RATE_LIMIT_MAX_COOLDOWN_SEC`）。
    static let maxCooldown: TimeInterval = 60 * 60

    private struct CooldownRecord: Codable {
        let retryAt: Date
    }

    private struct MemoryEntry {
        let limits: ProviderUsageLimits
        let expiresAt: Date
    }

    private let rootDirectory: URL
    private let ttl: TimeInterval
    private let now: () -> Date
    private let fileManager: FileManager
    /// 内存字典会被多 provider 的并发取数任务同时读写（LimitsCachingFetcher 非隔离），
    /// 必须加锁；磁盘文件本身是原子写，无需持锁。
    private let memoryLock = NSLock()
    private var memory: [TokenUsageProvider: MemoryEntry] = [:]

    init(
        applicationSupportRoot: URL = TokenUsageLimitsCache.defaultApplicationSupportDirectory,
        ttl: TimeInterval = LimitsCachePolicy.defaultTTL,
        now: @escaping () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = applicationSupportRoot
        self.ttl = ttl
        self.now = now
        self.fileManager = fileManager
    }

    // MARK: - LimitsCaching

    func memorySnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        guard let entry = memory[provider], now() < entry.expiresAt else { return nil }
        return entry.limits
    }

    func lastGoodSnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits? {
        var candidate: ProviderUsageLimits?
        memoryLock.lock()
        if let entry = memory[provider] {
            candidate = entry.limits
        }
        memoryLock.unlock()
        if candidate == nil, let disk = loadLastGood(from: lastGoodFileURL(for: provider)) {
            candidate = disk
        }
        guard var copy = candidate else { return nil }
        copy.windows = LimitsCachePolicy.discardingExpiredWindows(copy.windows, at: now())
        guard !copy.windows.isEmpty else { return nil }
        return copy
    }

    func storeSuccess(_ limits: ProviderUsageLimits) {
        // 契约守卫：错误快照绝不落缓存 —— 否则会覆盖磁盘 last-good。
        guard limits.issue == nil else { return }
        let expiresAt = LimitsCachePolicy.expirationDate(
            now: now(),
            ttl: ttl,
            windows: limits.windows
        )
        memoryLock.lock()
        memory[limits.provider] = MemoryEntry(limits: limits, expiresAt: expiresAt)
        memoryLock.unlock()
        if let data = try? JSONEncoder().encode(limits) {
            try? writeAtomically(data, to: lastGoodFileURL(for: limits.provider))
        }
        clearCooldown(for: limits.provider)
    }

    func storeNotConfigured(_ provider: TokenUsageProvider) {
        memoryLock.lock()
        memory[provider] = nil
        memoryLock.unlock()
        try? fileManager.removeItem(at: lastGoodFileURL(for: provider))
        clearCooldown(for: provider)
    }

    func storeRateLimit(for provider: TokenUsageProvider, retryAt: Date) {
        // 时长上限 1 小时（与 ProviderAPIClient 的 retry-after 换算一致）。
        let capped = min(retryAt, now().addingTimeInterval(Self.maxCooldown))
        if let data = try? JSONEncoder().encode(CooldownRecord(retryAt: capped)) {
            try? writeAtomically(data, to: cooldownFileURL(for: provider))
        }
    }

    func cooldown(for provider: TokenUsageProvider) -> Date? {
        let url = cooldownFileURL(for: provider)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(CooldownRecord.self, from: data),
              record.retryAt > now() else {
            // 损坏或已过期 → 清理。
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            return nil
        }
        return record.retryAt
    }

    func clearCooldown(for provider: TokenUsageProvider) {
        let url = cooldownFileURL(for: provider)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - 磁盘路径

    var directoryURL: URL {
        rootDirectory.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
    }

    /// last-good 文件名（参考 06 `*-usage-limits-cache.json`）。
    func lastGoodFileURL(for provider: TokenUsageProvider) -> URL {
        directoryURL.appendingPathComponent("\(provider.rawValue)-usage-limits-last-good.json", isDirectory: false)
    }

    /// 429 冷却文件名（参考 06 `*-usage-rate-limit.json`）。
    func cooldownFileURL(for provider: TokenUsageProvider) -> URL {
        directoryURL.appendingPathComponent("\(provider.rawValue)-usage-rate-limit.json", isDirectory: false)
    }

    // MARK: - 原子写（tmp + rename，文件 0600 / 目录 0700）

    private func loadLastGood(from url: URL) -> ProviderUsageLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProviderUsageLimits.self, from: data)
    }

    private func ensureSecureDirectory() throws {
        let dir = directoryURL
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureSecureDirectory()
        let temp = directoryURL.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            // `.atomic` 即 tmp + rename；随后显式 0600。
            try data.write(to: temp, options: [.atomic])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}
