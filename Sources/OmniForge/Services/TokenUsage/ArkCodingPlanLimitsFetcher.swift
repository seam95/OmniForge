import Foundation

// MARK: - 子进程边界

/// arkcli 命令执行边界（测试注入替身）。stdout 非零退出码抛错。
protocol ArkCliCommandRunning: AnyObject {
    func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async throws -> String
}

/// Process 实现（超时终止；stderr 丢弃）。
final class ProcessArkCliRunner: ArkCliCommandRunning {
    func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [weak process] in
                    guard let process, process.isRunning else { return }
                    process.terminate()
                }
                timer.resume()
                defer { timer.cancel() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: LimitError.network("arkcli exited \(process.terminationStatus)"))
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

// MARK: - 解析纯函数

/// arkcli 输出归一化（usage plan / plans get / profile show）。
enum ArkCodingPlanParsing {
    /// `usage plan` 或 OpenAPI 的 coding-plan 条目 → 窗口字典；无订阅 → nil。
    static func usageWindows(from rawBody: [String: Any]?) -> ([LimitWindowKind: UsageWindow], tier: String?)? {
        guard let rawBody else { return nil }
        let body = (rawBody["Result"] as? [String: Any]) ?? rawBody
        let items = body["items"] as? [[String: Any]] ?? []
        guard let item = items.first(where: { ($0["product"] as? String) == "coding-plan" }),
              (item["subscribed"] as? Bool) == true else {
            return nil
        }
        var windows: [LimitWindowKind: UsageWindow] = [:]
        let periods = item["periods"] as? [[String: Any]] ?? []
        for period in periods {
            let label = period["label"] as? String
            let slot: LimitWindowKind
            switch label {
            case "session": slot = .session
            case "weekly": slot = .weekly
            case "monthly": slot = .monthly
            default: continue
            }
            guard let percent = (period["percent"] as? NSNumber)?.doubleValue, percent.isFinite else {
                continue
            }
            windows[slot] = UsageWindow(
                usedPercent: UsageWindowParsing.clampPercent(percent) ?? 0,
                resetAt: UsageWindowParsing.parseResetDate(period["reset_at"]),
                limit: nil,
                used: nil,
                remaining: nil,
                unit: "calls",
                windowSeconds: nil
            )
        }
        guard !windows.isEmpty else { return nil }
        let tier = (item["tier"] as? String).flatMap { planLabelForTier($0) }
        return (windows, tier)
    }

    /// `plans get` 的 coding-plan tier → 套餐名。
    static func tier(fromPlans body: [String: Any]?) -> String? {
        let plans = body?["plans"] as? [[String: Any]] ?? []
        let plan = plans.first { ($0["key"] as? String) == "coding-plan" }
        return plan?["tier"] as? String
    }

    /// `profile show` → 身份（用户 id 或 owner_trn/identity_key 的数字段）。
    static func profileIdentity(from body: [String: Any]?) -> String? {
        let profile = body?["profile"] as? [String: Any] ?? body
        let name = (body?["profile"] as? String)
            ?? profile?["name"] as? String
            ?? profile?["profile"] as? String
            ?? profile?["profile_name"] as? String
        var userID = profile?["user_id"] as? String ?? profile?["userId"] as? String
            ?? body?["user_id"] as? String ?? body?["userId"] as? String
        if userID == nil {
            if let trn = profile?["owner_trn"] as? String,
               let match = trn.range(of: #"::(\d+):"#, options: .regularExpression) {
                userID = String(trn[match]).components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .joined()
            } else if let key = profile?["identity_key"] as? String,
                      let last = key.split(separator: "-").last {
                userID = String(last)
            }
        }
        let identity = [name, userID].compactMap { $0 }.joined(separator: ":")
        return identity.isEmpty ? nil : identity
    }

    static func planLabelForTier(_ tier: String?) -> String? {
        switch tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pro": return "Pro"
        case "lite": return "Lite"
        case let other where other?.isEmpty == false: return tier
        default: return nil
        }
    }
}

// MARK: - Fetcher

/// 方舟 Coding Plan 限额（D 类仅限额，无 token 消耗采集）。
///
/// 数据源：本地 `arkcli` 子进程（`usage plan --format json` 主路径；`plans get`
/// 补 tier；`profile show` 作磁盘缓存身份守卫）。无 arkcli 安装证据 → `configured: false`
/// （零 spawn）。失败走 `~/.omniforge/ark-coding-plan-limits-cache.json` 磁盘缓存
/// （TTL 12h，reset 已过期的窗口丢弃）。
final class ArkCodingPlanLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .arkCodingPlan

    static let cacheTTL: TimeInterval = 12 * 3600
    static let unknownResetCacheTTL: TimeInterval = 12 * 3600
    static let cacheFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".omniforge/ark-coding-plan-limits-cache.json")
    static let openApiEndpoint = URL(string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")!

    var apiTimeout: TimeInterval = 10
    var usageTimeout: TimeInterval = 10
    var profileTimeout: TimeInterval = 2.5
    var plansTimeout: TimeInterval = 5

    private let runner: ArkCliCommandRunning
    private let credentialsStore: ArkCredentialsStoring?
    private let session: URLSession
    private let signer: VolcengineSigV4Signer
    private let environment: [String: String]
    private let cacheURL: URL
    private let fileManager: FileManager
    /// 测试注入：非 nil 时跳过二进制探测直接使用。
    var binaryOverride: String?
    /// 测试注入：非 nil 时覆盖安装证据探测。
    var installEvidenceOverride: Bool?

    init(
        runner: ArkCliCommandRunning = ProcessArkCliRunner(),
        credentialsStore: ArkCredentialsStoring? = ArkKeychainStore(),
        session: URLSession = .shared,
        signer: VolcengineSigV4Signer = VolcengineSigV4Signer(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cacheURL: URL = ArkCodingPlanLimitsFetcher.cacheFileURL,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.credentialsStore = credentialsStore
        self.session = session
        self.signer = signer
        self.environment = environment
        self.cacheURL = cacheURL
        self.fileManager = fileManager
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 1. 第一优先级：AK/SK OpenAPI 直连（若已配置 AK/SK）
        if let creds = effectiveCredentials() {
            do {
                if let limits = try await fetchOpenApiLimits(credentials: creds) {
                    return limits
                }
            } catch let error as LimitError where error == .reauthRequired {
                throw error
            } catch {
                // 网络/临时错误：若本地有 arkcli 或缓存，继续向下回退尝试
            }
        }

        // 2. 第二优先级：本地 arkcli 命令行子进程
        if let binary = resolveBinaryPath() {
            do {
                let usageBody = try await runJSON(binary, ["usage", "plan", "--format", "json"], timeout: usageTimeout)
                guard let (windows, inlineTier) = ArkCodingPlanParsing.usageWindows(from: usageBody) else {
                    return nil // 无订阅 → configured: false
                }
                var planLabel = inlineTier
                if planLabel == nil {
                    let plansBody = try? await runJSON(binary, ["plans", "get", "--format", "json"], timeout: plansTimeout)
                    planLabel = ArkCodingPlanParsing.tier(fromPlans: plansBody)
                        .flatMap { ArkCodingPlanParsing.planLabelForTier($0) }
                }
                let identity = try? await profileIdentity(binary: binary)
                let limits = makeLimits(
                    windows: windows,
                    planLabel: planLabel,
                    stale: false,
                    issue: nil
                )
                writeCache(limits, identity: identity)
                return limits
            } catch {
                // 3. 兜底：磁盘缓存（身份守卫）。
                if let cached = readCache(identity: try? await profileIdentity(binary: binary), now: Date()) {
                    return cached
                }
                throw error
            }
        }

        // 4. 若无 binary 但有磁盘缓存（例如之前 AK/SK 或 arkcli 存留的有效快照）
        if let cached = readCache(identity: effectiveCredentials()?.accessKeyId, now: Date()) {
            return cached
        }

        // 无凭证、无 arkcli 且无缓存 → 未配置
        return nil
    }

    // MARK: - OpenAPI 直连

    private func effectiveCredentials() -> ArkCredentials? {
        if let stored = try? credentialsStore?.readCredentials(), stored.isValid {
            return stored
        }
        let ak = environment["VOLCENGINE_ACCESS_KEY"] ?? environment["ARK_AK"] ?? environment["VOLCENGINE_AK"]
        let sk = environment["VOLCENGINE_SECRET_KEY"] ?? environment["ARK_SK"] ?? environment["VOLCENGINE_SK"]
        if let ak = ak?.trimmingCharacters(in: .whitespacesAndNewlines), !ak.isEmpty,
           let sk = sk?.trimmingCharacters(in: .whitespacesAndNewlines), !sk.isEmpty {
            return ArkCredentials(accessKeyId: ak, secretAccessKey: sk)
        }
        return nil
    }

    private func fetchOpenApiLimits(credentials: ArkCredentials) async throws -> ProviderUsageLimits? {
        var request = URLRequest(url: Self.openApiEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = apiTimeout
        request = signer.sign(request: request, credentials: credentials)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Volcengine OpenAPI request failed")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LimitError.reauthRequired
        }
        guard http.statusCode == 200 else {
            throw LimitError.network("Volcengine OpenAPI returned HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("Volcengine OpenAPI returned non-JSON")
        }
        guard let (windows, tier) = ArkCodingPlanParsing.usageWindows(from: json) else {
            return nil
        }
        let limits = makeLimits(
            windows: windows,
            planLabel: tier,
            stale: false,
            issue: nil
        )
        writeCache(limits, identity: credentials.accessKeyId)
        return limits
    }

    // MARK: - 子进程

    private func runJSON(_ binary: String, _ arguments: [String], timeout: TimeInterval) async throws -> [String: Any]? {
        let stdout = try await runner.run(binary, arguments, timeout: timeout)
        guard let data = stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("arkcli \(arguments.first ?? "") returned non-JSON")
        }
        return object
    }

    private func profileIdentity(binary: String) async throws -> String? {
        let body = try await runJSON(binary, ["profile", "show", "--format", "json"], timeout: profileTimeout)
        return ArkCodingPlanParsing.profileIdentity(from: body)
    }

    // MARK: - 二进制探测

    /// 配置目录证据或 PATH/常见安装目录里找到 `arkcli`；否则 nil。
    private func resolveBinaryPath() -> String? {
        if let binaryOverride {
            return binaryOverride
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let evidenceDirs = [
            home + "/.arkcli",
            home + "/.config/arkcli",
        ]
        let hasEvidence = installEvidenceOverride
            ?? evidenceDirs.contains { fileManager.fileExists(atPath: $0) }
        let binDirs = [
            home + "/.local/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
        ]
        let binaryInDirs = binDirs.first { fileManager.fileExists(atPath: $0 + "/arkcli") }
        guard hasEvidence || binaryInDirs != nil else { return nil }
        if let binaryInDirs { return binaryInDirs + "/arkcli" }
        // PATH 探测（evidence 存在但常见目录没有时）。
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = String(dir) + "/arkcli"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - 磁盘缓存

    private struct CachePayload: Codable {
        var planLabel: String?
        var profileIdentity: String?
        var cachedAt: Double
        var windows: [String: CachedWindow]

        struct CachedWindow: Codable {
            var usedPercent: Double
            var resetAt: Double?
        }
    }

    private func makeLimits(
        windows: [LimitWindowKind: UsageWindow],
        planLabel: String?,
        stale: Bool,
        issue: LimitError?
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: planLabel,
            windows: windows,
            confidence: .official,
            capturedAt: Date(),
            stale: stale,
            issue: issue
        )
    }

    private func writeCache(_ limits: ProviderUsageLimits, identity: String?) {
        var cachedWindows: [String: CachePayload.CachedWindow] = [:]
        for (kind, window) in limits.windows {
            cachedWindows[kind.rawValue] = CachePayload.CachedWindow(
                usedPercent: window.usedPercent,
                resetAt: window.resetAt?.timeIntervalSince1970
            )
        }
        let payload = CachePayload(
            planLabel: limits.planLabel,
            profileIdentity: identity,
            cachedAt: Date().timeIntervalSince1970,
            windows: cachedWindows
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private func readCache(identity: String?, now: Date) -> ProviderUsageLimits? {
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return nil
        }
        // 身份守卫：profile show 成功但与缓存身份不符 → 缓存无效。
        if let identity, let cachedIdentity = payload.profileIdentity, identity != cachedIdentity {
            return nil
        }
        let age = now.timeIntervalSince1970 - payload.cachedAt
        guard age >= 0, age < Self.cacheTTL else { return nil }

        var windows: [LimitWindowKind: UsageWindow] = [:]
        for (rawKind, cached) in payload.windows {
            guard let kind = LimitWindowKind(rawValue: rawKind) else { continue }
            let resetAt = cached.resetAt.map { Date(timeIntervalSince1970: $0) }
            // reset 已过期的窗口丢弃（配额已滚动）。
            if let resetAt, resetAt <= now { continue }
            // 无 reset 日期的窗口：快照太旧则丢弃。
            if cached.resetAt == nil, age > Self.unknownResetCacheTTL { continue }
            windows[kind] = UsageWindow(
                usedPercent: cached.usedPercent,
                resetAt: resetAt,
                limit: nil,
                used: nil,
                remaining: nil,
                unit: "calls",
                windowSeconds: nil
            )
        }
        guard !windows.isEmpty else { return nil }
        return makeLimits(windows: windows, planLabel: payload.planLabel, stale: true, issue: nil)
    }
}