import Foundation

// MARK: - retrieveUserQuota 边界（半私有端点，集中定义可改 — SPEC 11 风险表）

/// Google Code Assist 半私有端点配置（`v1internal` 可能变动；解析失败降级不崩）。
enum GeminiCodeAssistEndpoints {
    /// loadCodeAssist：读取 tier/project（失败降级 → 匿名配额）。
    static let loadCodeAssist = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    /// retrieveUserQuota：按模型桶报告剩余额度。
    static let retrieveUserQuota = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
}

// MARK: - loadCodeAssist 响应解读

/// loadCodeAssist 精简解析（纯函数；tier/project 三形状兼容 — 参考 loadGeminiCodeAssistStatus）。
enum GeminiCodeAssistParser {
    struct Status: Equatable {
        var tier: String?
        var projectID: String?
    }

    static func parse(_ object: [String: Any]?) -> Status {
        guard let object else { return Status() }
        let tier = (object["currentTier"] as? [String: Any])?["id"] as? String
        let rawProject = object["cloudaicompanionProject"]
        let projectID: String? = {
            if let string = rawProject as? String, !string.isEmpty { return string }
            if let dict = rawProject as? [String: Any] {
                if let id = dict["id"] as? String, !id.isEmpty { return id }
                if let projectId = dict["projectId"] as? String, !projectId.isEmpty { return projectId }
            }
            return nil
        }()
        return Status(tier: tier, projectID: projectID)
    }
}

/// tier → 显示套餐（standard → Paid / legacy → Legacy / free → Free；其余 nil）。
enum GeminiQuotaPlanLabel {
    static func planLabel(fromTier tier: String?) -> String? {
        switch tier {
        case "standard-tier": return "Paid"
        case "legacy-tier": return "Legacy"
        case "free-tier": return "Free"
        default: return nil
        }
    }
}

// MARK: - retrieveUserQuota 响应解码（按模型桶分类）

/// Gemini 配额响应解码 — 纯函数，独立可测（参考 normalizeGeminiQuotaResponse）。
///
/// 窗口映射：按模型 cognate 分类 — pro → session 槽、flash → weekly、flash-lite → monthly；
/// 无 cognate 时 lowest remainingFraction 兜底到 session 槽；每模型取剩余分数最低者。
enum GeminiQuotaResponseDecoder {
    static func decode(buckets: Any?) -> [LimitWindowKind: UsageWindow] {
        let models = normalizeModelBuckets(buckets)
        guard !models.isEmpty else { return [:] }

        let lowest = { (predicate: (String) -> Bool) -> GeminiModelBucket? in
            models.filter { predicate($0.modelID) }
                .sorted { $0.remainingFraction < $1.remainingFraction }
                .first
        }
        let pro = lowest(isProModel)
        let flash = lowest(isFlashModel)
        let flashLite = lowest(isFlashLiteModel)
        let fallback: GeminiModelBucket? = (pro == nil && flash == nil && flashLite == nil)
            ? models.sorted { $0.remainingFraction < $1.remainingFraction }.first
            : nil

        var windows: [LimitWindowKind: UsageWindow] = [:]
        if let model = pro ?? fallback, let window = toWindow(model) {
            windows[.session] = window
        }
        if let model = flash, let window = toWindow(model) {
            windows[.weekly] = window
        }
        if let model = flashLite, let window = toWindow(model) {
            windows[.monthly] = window
        }
        return windows
    }

    // MARK: 内部

    private static let flashLiteKeywords = ["flash-lite", "flash_lite", "flashlite"]
    private static let flashKeywords = ["flash"]
    private static let proKeywords = ["pro"]

    private static func isProModel(_ id: String) -> Bool {
        proKeywords.contains { id.lowercased().contains($0) }
    }

    private static func isFlashLiteModel(_ id: String) -> Bool {
        flashLiteKeywords.contains { id.lowercased().contains($0) }
    }

    private static func isFlashModel(_ id: String) -> Bool {
        flashKeywords.contains { id.lowercased().contains($0) } && !isFlashLiteModel(id)
    }

    /// 每模型取剩余分数最低者（剔除不可解析字段）。
    private static func normalizeModelBuckets(_ value: Any?) -> [GeminiModelBucket] {
        guard let buckets = value as? [[String: Any]] else { return [] }
        var byModel: [String: GeminiModelBucket] = [:]
        for bucket in buckets {
            guard let modelID = bucket["modelId"] as? String, !modelID.isEmpty else { continue }
            guard let fraction = UsageWindowParsing.numeric(bucket["remainingFraction"]), fraction.isFinite else {
                continue
            }
            let existing = byModel[modelID]
            if existing == nil || fraction < existing!.remainingFraction {
                byModel[modelID] = GeminiModelBucket(
                    modelID: modelID,
                    remainingFraction: fraction,
                    resetAt: UsageWindowParsing.parseResetDate(bucket["resetTime"])
                )
            }
        }
        return byModel.values.sorted { $0.modelID < $1.modelID }
    }

    private static func toWindow(_ model: GeminiModelBucket) -> UsageWindow? {
        let usedPercent = UsageWindowParsing.clampPercent(
            // 浮点清洗：0.55 类输入产生 44.999…，四舍五入到分位（显示口径足够）
            ((100 - model.remainingFraction * 100) * 100).rounded() / 100
        )
        guard let usedPercent else { return nil }
        return UsageWindow(
            usedPercent: usedPercent,
            resetAt: model.resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: nil
        )
    }

    private struct GeminiModelBucket {
        var modelID: String
        var remainingFraction: Double
        var resetAt: Date?
    }
}

// MARK: - 取数器

/// Gemini 限额取数器：`oauth_creds.json` → 临期自刷新 → `loadCodeAssist`（tier/project）→
/// `retrieveUserQuota`（参考 08 / fetchGeminiLimits）。
///
/// 请求序：① loadCodeAssist（拿 tier/project；**失败降级**为匿名配额，参考实现同策略）
/// → ② retrieveUserQuota（计数主源）；401/403/429 语义与 Claude/Codex 一致；
/// 刷新失败细分：401 类 → `reauthRequired`，网络类失败回退旧 token 继续（best-effort）。
final class GeminiLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .gemini

    private let credentials: GeminiCredentialReading
    private let refresher: GeminiTokenRefreshing
    private let persistence: (GeminiAuthBundle, GeminiRefreshedTokens, Date) throws -> GeminiAuthBundle
    private let client: ProviderAPIClient
    private let now: () -> Date

    init(
        credentials: GeminiCredentialReading = GeminiAuthFileCredentialReader(),
        refresher: GeminiTokenRefreshing = GeminiTokenRefresher(),
        persistence: @escaping (GeminiAuthBundle, GeminiRefreshedTokens, Date) throws -> GeminiAuthBundle = GeminiAuthPersistence.persistDefault,
        client: ProviderAPIClient = ProviderAPIClient(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.refresher = refresher
        self.persistence = persistence
        self.client = client
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 未配置（oauth_creds.json 缺失/不可读）→ nil，由管理器归一化为 notConfigured。
        guard let bundle = try? credentials.readBundle() else {
            return nil
        }
        let current = try await ensureFresh(bundle)
        let headers = authHeaders(for: current)

        // ① loadCodeAssist：半私有端点；任何失败降级为匿名配额（参考 fetchGeminiLimits）。
        let assistObject = try? await client.postJSON(
            url: GeminiCodeAssistEndpoints.loadCodeAssist,
            headers: headers,
            body: loadCodeAssistBody()
        )
        let assist = GeminiCodeAssistParser.parse(assistObject)

        // ② retrieveUserQuota：计数主源；401 短路 reauth、429 → rateLimited。
        let quotaObject = try await client.postJSON(
            url: GeminiCodeAssistEndpoints.retrieveUserQuota,
            headers: headers,
            body: assist.projectID.map { ["project": $0] } ?? [:]
        )
        let windows = GeminiQuotaResponseDecoder.decode(buckets: quotaObject["buckets"])
        guard !windows.isEmpty else {
            throw LimitError.decoding("No quota buckets")
        }

        let planLabel = GeminiQuotaPlanLabel.planLabel(fromTier: assist.tier)
        return ProviderUsageLimits(
            provider: .gemini,
            configured: true,
            subscriptionStatus: planLabel != nil ? .active : .unknown,
            planLabel: planLabel,
            windows: windows,
            confidence: .official,
            capturedAt: now(),
            stale: false,
            issue: nil
        )
    }

    // MARK: 内部

    /// 「临期才刷」：expiry_date 已过才通知刷新；401 类刷新失败 → `reauthRequired` 短路；
    /// 网络/HTTP 类失败回退旧 token 继续（best-effort，与 Codex 一致）。
    private func ensureFresh(_ bundle: GeminiAuthBundle) async throws -> GeminiAuthBundle {
        guard GeminiTokenFreshness.isStale(expiryDate: bundle.expiryDate, now: now()) else {
            return bundle
        }
        guard let refreshToken = bundle.refreshToken, !refreshToken.isEmpty else {
            return bundle
        }
        do {
            let tokens = try await refresher.refresh(refreshToken: refreshToken)
            return try persistence(bundle, tokens, now())
        } catch let error as GeminiTokenRefreshError {
            switch error {
            case .noRefreshToken, .refreshRejected:
                throw LimitError.reauthRequired
            case .httpError, .invalidResponse, .network:
                return bundle // 网络/副作用失败：回退旧 token 继续
            }
        } catch {
            return bundle
        }
    }

    /// Google Code Assist 请求体（ideType 对齐 GEMINI_CLI 插件类型）。
    private func loadCodeAssistBody() -> [String: Any] {
        [
            "metadata": [
                "ideType": "GEMINI_CLI",
                "pluginType": "GEMINI",
            ],
        ]
    }

    private func authHeaders(for bundle: GeminiAuthBundle) -> [String: String] {
        [
            "Authorization": "Bearer \(bundle.accessToken)",
            "Accept": "application/json",
        ]
    }
}
