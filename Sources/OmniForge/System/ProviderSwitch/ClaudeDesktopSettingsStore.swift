import Foundation

/// Claude Desktop 侧可观察状态 — `detectActive` 与 UI 诊断的数据源。
struct ClaudeDesktopState: Equatable {
    /// 1P config 的 `deploymentMode`（"1p" / "3p"）；文件缺失或无键 → nil。
    var deploymentMode: String?
    /// `_meta.json` 的 `appliedId`；文件缺失或无键 → nil。
    var appliedId: String?
    /// profile 的 `inferenceGatewayBaseUrl`；文件缺失或无键 → nil。
    var inferenceGatewayBaseUrl: String?
    /// profile 的 `inferenceGatewayApiKey`（收编未托管网关时读取）。
    var inferenceGatewayApiKey: String?
    /// `appliedId` 是否指向我们的固定 profile UUID。
    var isOurProfileApplied: Bool
}

/// Claude Desktop 配置写入边界 — 4 文件事务（SPEC 关键设计决策 2）。
protocol ClaudeDesktopSettingsStoring: AnyObject {
    /// 应用供应商 profile（直连形态）：4 文件事务写入 3P。
    /// 映射卡（`desktopModelRoutes` 非空）拒绝直连，抛 `modelRoutesRequireAggregation`。
    /// `inferenceModels`：聚合投影的模型列表（条目为纯字符串或对象形态）；直连传 nil。
    func applyProfile(_ profile: ProviderProfile, inferenceModels: [Any]?, modelDiscoveryEnabled: Bool?) throws
    /// 聚合投影写入（同款事务）：代理 origin + gateway token + 模型列表（无映射卡守卫）。
    func applyAggregation(
        gatewayBaseURL: String,
        gatewayToken: String,
        inferenceModels: [Any],
        modelDiscoveryEnabled: Bool?
    ) throws
    /// 恢复官方：两个 config 写回 "1p"、profile 只清关键字段、`_meta.json` 摘除条目；文件保留。
    func restoreOfficial() throws
    /// 读取当前状态（各文件缺失/缺键取 nil，JSON 损坏抛错）。
    func readState() throws -> ClaudeDesktopState
    /// pending 存在时按其完整内容重放写入（自愈；幂等）。返回是否发生了重放。
    @discardableResult
    func replayPendingIfPresent() throws -> Bool
    /// 丢弃 pending（切换失败回滚后调用：保留 pending 会让下一次 refresh 把
    /// 已回滚的事务重新落盘——回滚结果必须胜利）。
    func discardPending() throws
}

/// Claude Desktop 配置写入错误。
enum ClaudeDesktopSettingsError: Error, Equatable {
    /// 映射卡不能走直连（需聚合模式的模型路由）。
    case modelRoutesRequireAggregation
    /// `_meta.json` 的 `entries` 存在但不是数组 — 按 SPEC 报错，不静默重建。
    case metaEntriesNotArray(path: String)
    /// 任一目标文件 JSON 损坏（无法解析为对象）。
    case corrupted(path: String)
}

extension ClaudeDesktopSettingsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelRoutesRequireAggregation:
            return "该供应商配置了模型映射，直连模式不可用：请进入聚合模式使用"
        case .metaEntriesNotArray(let path):
            return "Claude Desktop 配置注册表损坏（entries 不是数组）：\(path)"
        case .corrupted(let path):
            return "Claude Desktop 配置文件损坏（不是合法 JSON 对象）：\(path)"
        }
    }
}

/// 4 文件事务写入实现（对齐 cc-switch `claude_desktop_config.rs`）：
/// - `~/Library/Application Support/Claude/claude_desktop_config.json`（生效开关，最后写）
/// - `~/Library/Application Support/Claude-3p/claude_desktop_config.json`
/// - `~/Library/Application Support/Claude-3p/configLibrary/<固定UUID>.json`（网关 profile）
/// - `~/Library/Application Support/Claude-3p/configLibrary/_meta.json`（注册表）
///
/// 顺序固定：pending → profile → _meta → 3P config → 1P config（生效开关）→ 删 pending。
/// 崩溃后由 `replayPendingIfPresent` 用 pending 内的完整目标内容前滚补完。
final class ClaudeDesktopSettingsStore: ClaudeDesktopSettingsStoring {
    /// 网关 profile 的固定 UUID（对齐 cc-switch；路径即身份，不生成新 id）。
    static let profileID = "00000000-0000-4000-8000-000000157210"
    /// profile 在 Desktop 配置库里的展示名。
    static let profileName = "OmniForge"
    /// UI 固定四档路由名（Claude-safe）。
    static let defaultRoutes = ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5", "claude-fable-5"]
    /// 旧版工具写进 3P config `enterpriseConfig` 的网关键 — 恢复官方时清除
    /// （对齐 cc-switch `LEGACY_ENTERPRISE_GATEWAY_KEYS`；残留会让 1P 仍走旧网关，
    /// 且把明文 Key 留在磁盘上）。
    static let legacyEnterpriseGatewayKeys = [
        "disableDeploymentModeChooser",
        "inferenceGatewayApiKey",
        "inferenceGatewayAuthScheme",
        "inferenceGatewayBaseUrl",
        "inferenceProvider",
    ]

    /// 恢复官方时从 profile 清除的关键字段（其余用户设置保留，下次切回仍在）。
    static let profileGatewayKeys = [
        "inferenceProvider",
        "inferenceGatewayBaseUrl",
        "inferenceGatewayApiKey",
        "inferenceGatewayAuthScheme",
        "inferenceModels",
        "modelDiscoveryEnabled",
    ]

    private let configURL: URL
    private let config3PURL: URL
    private let profileURL: URL
    private let metaURL: URL
    private let pendingStore: ClaudeDesktopWritePendingStore
    private let fileManager: FileManager

    init(
        configURL: URL,
        config3PURL: URL,
        profileURL: URL,
        metaURL: URL,
        pendingURL: URL,
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.config3PURL = config3PURL
        self.profileURL = profileURL
        self.metaURL = metaURL
        self.pendingStore = ClaudeDesktopWritePendingStore(pendingURL: pendingURL, fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// 生产装配：按 home 布局与 App Support 根解析 4 文件与 pending 路径。
    static func production(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) -> ClaudeDesktopSettingsStore {
        ClaudeDesktopSettingsStore(
            configURL: ProviderSwitchPaths.claudeDesktopConfigURL(homePath: homePath),
            config3PURL: ProviderSwitchPaths.claudeDesktop3PConfigURL(homePath: homePath),
            profileURL: ProviderSwitchPaths.claudeDesktopProfileURL(homePath: homePath),
            metaURL: ProviderSwitchPaths.claudeDesktopMetaURL(homePath: homePath),
            pendingURL: ProviderSwitchPaths.desktopProfileDirectory(applicationSupportRoot: applicationSupportRoot)
                .appendingPathComponent("pending.json", isDirectory: false),
            fileManager: fileManager
        )
    }

    // MARK: - 白名单（纯函数）

    /// Desktop 模型名校验器口径 — 转发到 Models 层单一事实源（`DesktopModelWhitelist`）。
    static func isClaudeSafeModelID(_ model: String) -> Bool {
        DesktopModelWhitelist.isClaudeSafe(model)
    }

    // MARK: - 事务写入

    func applyProfile(
        _ profile: ProviderProfile,
        inferenceModels: [Any]? = nil,
        modelDiscoveryEnabled: Bool? = nil
    ) throws {
        // 直连准入：映射卡必须聚合（对齐 cc-switch validate_direct_provider）。
        if let routes = profile.desktopModelRoutes, !routes.isEmpty {
            throw ClaudeDesktopSettingsError.modelRoutesRequireAggregation
        }
        try writeTransaction(
            gatewayBaseURL: profile.baseURL,
            gatewayToken: profile.token,
            inferenceModels: inferenceModels,
            modelDiscoveryEnabled: modelDiscoveryEnabled
        )
    }

    /// 聚合投影写入（4 文件事务同款）：代理 origin + gateway token + 模型列表。
    /// 不做映射卡守卫——投影的 baseURL 是本机代理而非映射卡直连（守卫只约束直连语义）。
    func applyAggregation(
        gatewayBaseURL: String,
        gatewayToken: String,
        inferenceModels: [Any],
        modelDiscoveryEnabled: Bool?
    ) throws {
        try writeTransaction(
            gatewayBaseURL: gatewayBaseURL,
            gatewayToken: gatewayToken,
            inferenceModels: inferenceModels,
            modelDiscoveryEnabled: modelDiscoveryEnabled
        )
    }

    /// 事务主流程：读现有 → 合并网关字段 → pending → 4 文件按序落盘 → 删 pending。
    private func writeTransaction(
        gatewayBaseURL: String,
        gatewayToken: String,
        inferenceModels: [Any]?,
        modelDiscoveryEnabled: Bool?
    ) throws {
        // 1. 内存生成 4 个文件的完整目标 JSON。
        var gatewayProfile = try readJSONObject(profileURL, allowMissing: true)
        gatewayProfile["inferenceProvider"] = "gateway"
        gatewayProfile["inferenceGatewayBaseUrl"] = gatewayBaseURL
        gatewayProfile["inferenceGatewayApiKey"] = gatewayToken
        gatewayProfile["inferenceGatewayAuthScheme"] = "bearer"
        if let inferenceModels, !inferenceModels.isEmpty {
            gatewayProfile["inferenceModels"] = inferenceModels
        } else if gatewayProfile["inferenceModels"] != nil {
            // 上次聚合写入的列表在直连时必须移除（直连 = Desktop 自动发现）。
            gatewayProfile.removeValue(forKey: "inferenceModels")
        }
        if let modelDiscoveryEnabled {
            gatewayProfile["modelDiscoveryEnabled"] = modelDiscoveryEnabled
        } else if gatewayProfile["modelDiscoveryEnabled"] != nil {
            gatewayProfile.removeValue(forKey: "modelDiscoveryEnabled")
        }
        // 行为定义：这两个键只在缺失时写（用户收紧过则不动）。
        if gatewayProfile["coworkEgressAllowedHosts"] == nil {
            gatewayProfile["coworkEgressAllowedHosts"] = ["*"]
        }
        if gatewayProfile["disableDeploymentModeChooser"] == nil {
            gatewayProfile["disableDeploymentModeChooser"] = true
        }

        var meta = try readMetaForUpdate()
        upsertOwnEntry(&meta)

        try commitTransaction(
            profile: gatewayProfile,
            meta: meta,
            config3P: try mergeConfig3P(mode: "3p"),
            config1P: try mergeConfig(mode: "3p")
        )
    }

    func restoreOfficial() throws {
        // 1. 内存生成目标：两个 config 回 "1p"；profile 只清关键字段（文件保留）；
        //    _meta.json 摘除我们的条目（appliedId 切到剩余第一个，无剩余则删键）。
        var gatewayProfile = try readJSONObject(profileURL, allowMissing: true)
        for key in Self.profileGatewayKeys where gatewayProfile[key] != nil {
            gatewayProfile.removeValue(forKey: key)
        }

        var meta = try readMetaForUpdate()
        if var entries = meta["entries"] as? [Any] {
            let before = entries.count
            entries.removeAll { ($0 as? [String: Any])?["id"] as? String == Self.profileID }
            meta["entries"] = entries
            if let applied = meta["appliedId"] as? String, applied == Self.profileID {
                if let first = entries.first,
                   let firstID = (first as? [String: Any])?["id"] as? String {
                    meta["appliedId"] = firstID
                } else {
                    meta.removeValue(forKey: "appliedId")
                }
            }
            _ = before
        }

        try commitTransaction(
            profile: gatewayProfile,
            meta: meta,
            config3P: try mergeConfig3P(mode: "1p"),
            config1P: try mergeConfig(mode: "1p")
        )
    }

    func readState() throws -> ClaudeDesktopState {
        // 4 个文件全部解析一次：SPEC 要求「任一文件 JSON 损坏 → unreadable」，
        // 只看 1P config 会漏掉 3P 沙盒配置损坏（那份同样是 Desktop 的真源）。
        let config = try readJSONObject(configURL, allowMissing: true)
        _ = try readJSONObject(config3PURL, allowMissing: true)
        let meta = try readJSONObject(metaURL, allowMissing: true)
        let profile = try readJSONObject(profileURL, allowMissing: true)
        let appliedId = meta["appliedId"] as? String
        return ClaudeDesktopState(
            deploymentMode: config["deploymentMode"] as? String,
            appliedId: appliedId,
            inferenceGatewayBaseUrl: profile["inferenceGatewayBaseUrl"] as? String,
            inferenceGatewayApiKey: profile["inferenceGatewayApiKey"] as? String,
            isOurProfileApplied: appliedId == Self.profileID
        )
    }

    func replayPendingIfPresent() throws -> Bool {
        guard let pending = try pendingStore.load() else { return false }
        try writeFiles(from: pending)
        try pendingStore.clear()
        return true
    }

    func discardPending() throws {
        try pendingStore.clear()
    }

    // MARK: - private

    /// 事务落盘：pending → 4 文件（固定顺序）→ 删 pending。
    private func commitTransaction(
        profile: [String: Any],
        meta: [String: Any],
        config3P: [String: Any],
        config1P: [String: Any]
    ) throws {
        let pending = ClaudeDesktopWritePending(
            files: [
                .init(url: profileURL, object: profile),
                .init(url: metaURL, object: meta),
                .init(url: config3PURL, object: config3P),
                .init(url: configURL, object: config1P),
            ],
            createdAt: Date()
        )
        try pendingStore.save(pending)
        try writeFiles(from: pending)
        try pendingStore.clear()
    }

    /// 按固定顺序写 4 文件（profile → _meta → 3P config → 1P config 生效开关最后）。
    private func writeFiles(from pending: ClaudeDesktopWritePending) throws {
        for file in pending.files {
            try fileManager.createDirectory(
                at: file.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: file.object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try AtomicFileWriter.write(data, to: file.url, fileManager: fileManager)
        }
    }

    /// 读 JSON 对象；`allowMissing` 时文件缺失返回 `[:]`（首次创建路径）。
    private func readJSONObject(_ url: URL, allowMissing: Bool) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            if allowMissing { return [:] }
            throw ClaudeDesktopSettingsError.corrupted(path: url.path)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw ClaudeDesktopSettingsError.corrupted(path: url.path)
        }
        // 空白文件视为空对象（对齐 cc-switch `patch_json::parse`）：Desktop 可能留下
        // 0 字节配置，把它判损坏会让用户卡在「切换失败」且无从自愈。
        if data.isEmpty || (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) {
            return [:]
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeDesktopSettingsError.corrupted(path: url.path)
        }
        return object
    }

    /// 读 `_meta.json` 供更新：缺失 → `{entries: [], appliedId: 我们的 UUID}`（首次创建）；
    /// `entries` 存在但不是数组 → 抛错（不静默重建，SPEC 关键设计决策 2）。
    /// 判定按 `[Any]` 口径（对齐 cc-switch `as_array`）：条目不是对象不在此拒绝，
    /// 由 `upsertOwnEntry` 原样保留。
    private func readMetaForUpdate() throws -> [String: Any] {
        var meta = try readJSONObject(metaURL, allowMissing: true)
        if meta["entries"] == nil {
            meta["entries"] = [Any]()
        } else if !(meta["entries"] is [Any]) {
            throw ClaudeDesktopSettingsError.metaEntriesNotArray(path: metaURL.path)
        }
        return meta
    }

    /// 我们的条目在 `entries` 中原位更新（不挪位置），不存在则追加；`appliedId` 指向我们。
    /// 与 cc-switch `MetaPatch` 同口径：既有条目**只覆盖 id/name 两个键**，其余字段
    /// （`note`、Desktop 自己写的元数据）原样保留——整条替换会静默丢用户数据。
    private func upsertOwnEntry(_ meta: inout [String: Any]) {
        var entries = (meta["entries"] as? [Any]) ?? []
        let matchIndex = entries.firstIndex { entry in
            guard let dict = entry as? [String: Any] else { return false }
            return (dict["id"] as? String) == Self.profileID
        }
        if let matchIndex, var existing = entries[matchIndex] as? [String: Any] {
            existing["id"] = Self.profileID
            existing["name"] = Self.profileName
            entries[matchIndex] = existing
        } else {
            // 无匹配（或匹配到非对象条目）→ 追加新条目（cc-switch `_ => push` 同语义）。
            entries.append(["id": Self.profileID, "name": Self.profileName])
        }
        meta["entries"] = entries
        meta["appliedId"] = Self.profileID
    }

    /// 1P config 目标：读现有（缺失 `{}`），只改 `deploymentMode`（其余用户设置保留）。
    private func mergeConfig(mode: String) throws -> [String: Any] {
        var config = try readJSONObject(configURL, allowMissing: true)
        config["deploymentMode"] = mode
        return config
    }

    private func mergeConfig3P(mode: String) throws -> [String: Any] {
        var config = try readJSONObject(config3PURL, allowMissing: true)
        config["deploymentMode"] = mode
        // 恢复官方（1p）时清 legacy 网关键；3p 写入不动（那是别的工具的遗留，不归我们管）。
        if mode == "1p", var enterprise = config["enterpriseConfig"] as? [String: Any] {
            for key in Self.legacyEnterpriseGatewayKeys {
                enterprise.removeValue(forKey: key)
            }
            if enterprise.isEmpty {
                config.removeValue(forKey: "enterpriseConfig")
            } else {
                config["enterpriseConfig"] = enterprise
            }
        }
        return config
    }
}
