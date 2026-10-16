import Darwin
import Foundation

/// 聚合编排管理器 — 聚合模式的唯一编排入口：模式切换、成员管理、写前意图、
/// 崩溃恢复、看门狗。持有 `AggregationStack`（唯一真源，按工具各一份）。
@MainActor
final class ProviderAggregationManager: ObservableObject {
    /// 每工具的生效态（既作数据态，也作 UI 分段行选中态——两者取值域相同）。
    enum AggregationMode: String, CaseIterable, Identifiable, Equatable {
        case direct
        case aggregation
        var id: String { rawValue }
    }

    /// 成员行视图（UI 直接消费）。
    struct AggregationMemberView: Equatable, Identifiable {
        let id: String
        let name: String
        /// 是否默认那家（名单首位）。
        let isDefault: Bool
        /// 是否官方账号（只能做默认，不能加入聚合）。
        let isOfficial: Bool
        /// 该成员发布的模型条数。
        let publishedCount: Int
        /// 该成员发布的 Stack id 列表（选择器预览）。
        let modelIDs: [String]
    }

    // MARK: - 发布状态

    @Published private(set) var stack: AggregationStack
    @Published private(set) var isProxyRunning: Bool
    @Published private(set) var resolvedPort: UInt16?
    @Published private(set) var lastError: String?
    /// 最近一次操作是否留下「一半新一半旧」的客户端配置（pending 保留，待前滚）。
    @Published private(set) var lastPartialWrite: Bool
    @Published private(set) var staleClients: CodexStaleClients?

    private let profileStore: ProviderProfileStoring
    private let backupStore: ProviderBackupStoring
    private let stackStore: AggregationStackStoring
    private let pendingStore: AggregationPendingStoring
    private let loginStashStore: CodexLoginStashStoring
    private let staleDetector: CodexStaleClientDetecting
    private let proxy: AggregationProxying
    private let claudeWriter: AggregationClaudeConfigWriting
    private let codexWriter: AggregationCodexConfigWriting
    /// 生产装配的迟绑定（单测为 nil）——代理状态变化时喂新快照。
    private let proxyBinding: AggregationProxyBinding?
    private var profiles: [ProviderProfile]
    private let fileManager: FileManager

    init(
        profileStore: ProviderProfileStoring,
        backupStore: ProviderBackupStoring,
        stackStore: AggregationStackStoring,
        pendingStore: AggregationPendingStoring,
        loginStashStore: CodexLoginStashStoring,
        staleDetector: CodexStaleClientDetecting,
        proxy: AggregationProxying,
        claudeWriter: AggregationClaudeConfigWriting,
        codexWriter: AggregationCodexConfigWriting,
        profiles: [ProviderProfile],
        fileManager: FileManager = .default,
        proxyBinding: AggregationProxyBinding? = nil
    ) {
        self.profileStore = profileStore
        self.backupStore = backupStore
        self.stackStore = stackStore
        self.pendingStore = pendingStore
        self.loginStashStore = loginStashStore
        self.staleDetector = staleDetector
        self.proxy = proxy
        self.claudeWriter = claudeWriter
        self.codexWriter = codexWriter
        self.profiles = profiles
        self.fileManager = fileManager
        self.proxyBinding = proxyBinding
        stack = stackStore.load()
        isProxyRunning = proxy.isRunning
        resolvedPort = proxy.resolvedPort
        lastError = nil
        lastPartialWrite = false
        staleClients = nil
        proxy.onUnexpectedStop = { [weak self] in
            self?.handleProxyUnexpectedStop()
        }
    }

    // MARK: - 状态查询

    func mode(tool: ProviderTool) -> AggregationMode {
        stack.toolStack(tool).enabled ? .aggregation : .direct
    }

    func toolStack(_ tool: ProviderTool) -> AggregationStack.ToolStack {
        stack.toolStack(tool)
    }

    /// 直连互斥判定：该工具处于聚合时，直连分区的「连接」动作须禁用（两个写者不得同时生效）。
    func isAggregating(_ tool: ProviderTool) -> Bool {
        mode(tool: tool) == .aggregation
    }

    func members(tool: ProviderTool) -> [AggregationMemberView] {
        let toolStack = stack.toolStack(tool)
        return toolStack.members.compactMap { profileID -> AggregationMemberView? in
            guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
            let published = publishedModels(for: profile)
            return AggregationMemberView(
                id: profileID,
                name: profile.name,
                isDefault: profileID == toolStack.members.first,
                isOfficial: Self.isOfficial(profile),
                publishedCount: published.count,
                modelIDs: published.map(\.id)
            )
        }
    }

    /// 可加入聚合的 profile：同工具、非官方、尚未在名单。
    func joinableProfileIDs(tool: ProviderTool) -> [String] {
        let toolStack = stack.toolStack(tool)
        return profiles
            .filter { $0.tool == tool && !Self.isOfficial($0) && !toolStack.isMember($0.id) }
            .map(\.id)
    }

    /// 某工具全部成员的已发布模型（名单顺序 = 选择器顺序；默认那家在首位）。
    func publishedModels(tool: ProviderTool) -> [AggregationPublishedModel] {
        stack.toolStack(tool).members.flatMap { profileID -> [AggregationPublishedModel] in
            guard let profile = profiles.first(where: { $0.id == profileID }) else { return [] }
            return publishedModels(for: profile)
        }
    }

    // MARK: - 模式切换

    /// 进入聚合：先起代理，成功才写配置。任一步失败按 `partial` 语义处理
    /// （发布前失败 → 什么都不动；发布后失败 → 保留 pending 待前滚）。
    func enterAggregation(tool: ProviderTool, defaultProfileID: String) throws {
        guard let defaultProfile = profiles.first(where: { $0.id == defaultProfileID }) else {
            throw AggregationManagerError.profileNotFound(id: defaultProfileID)
        }
        guard defaultProfile.tool == tool else {
            throw AggregationManagerError.toolMismatch(id: defaultProfileID, expected: tool)
        }
        guard defaultProfile.hasCompleteConnection else {
            throw AggregationManagerError.incompleteConnection(id: defaultProfileID)
        }
        // 已在聚合 → 视为切换默认那家。
        if stack.toolStack(tool).enabled {
            try setDefault(defaultProfileID)
            return
        }

        // 1) 起代理（失败即抛，不写任何配置）。
        try proxy.start()
        guard let port = proxy.resolvedPort else { throw AggregationProxyError.allPortsTaken }
        syncProxyState()

        // 2) Codex 官方登录收纳（仅 Codex）。
        if tool == .codex {
            try? loginStashStore.stash()
        }

        // 3) 目标文件快照 — 退出聚合时的直连恢复点。
        try? backupStore.snapshot(tool: tool, of: Self.configURL(for: tool))

        // 4) 组新栈：默认那家入座首位 + key 分配 + 模式位。
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = true
        if !toolStack.isMember(defaultProfileID) {
            toolStack.members.insert(defaultProfileID, at: 0)
        }
        let registry = AggregationKeyRegistry(keys: toolStack.keys)
        _ = registry.allocate(profile: defaultProfile)
        toolStack.keys = registry.keys
        newStack.setToolStack(toolStack, for: tool)

        // 5) pending（published: false）。
        let intent = AggregationPending(tool: tool, stack: newStack, published: false)
        try pendingStore.save(intent)

        // 6) 发布第一个文件之前：published = true —— 此后任何一步崩溃都按「已进入
        // 发布流程」前滚（幂等补完），杜绝「目录已落地、pending 仍 false、恢复却丢弃」。
        var entered = intent
        entered.published = true
        try pendingStore.save(entered)

        // 7) 写该工具投影。
        do {
            try publishProjection(tool: tool, defaultProfile: defaultProfile, port: port)
        } catch {
            // 已进入发布 → partial：保留 pending，提交栈态，下次操作或重启前滚。
            lastPartialWrite = true
            commit(stack: newStack)
            throw error
        }

        // 8) 提交 + 清 pending。
        lastPartialWrite = false
        commit(stack: newStack)
        try? pendingStore.clear()
    }

    /// 退出聚合：从进入前的快照恢复直连配置 → 还原 Codex 官方登录 →
    /// 摘模式位（保留名单与登记簿）→ 两个工具都退出则停代理。
    func exitAggregation(tool: ProviderTool) throws {
        do {
            if let backup = backupStore.list(tool: tool).first {
                try backupStore.restore(backup, to: Self.configURL(for: tool))
            } else {
                // 快照不可用 → 退化为仅清聚合键。
                try clearAggregationKeys(tool: tool)
            }
        } catch {
            try clearAggregationKeys(tool: tool)
        }
        if tool == .codex {
            try? loginStashStore.restore()
        }
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = false
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        stopProxyIfIdle(newStack)
    }

    // MARK: - 成员管理

    /// 加入成员：分配永久 key；官方账号不可加入；已在名单里 → 无变化（不重写）。
    func addMember(_ profileID: String) throws {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw AggregationManagerError.profileNotFound(id: profileID)
        }
        guard !Self.isOfficial(profile) else {
            throw AggregationManagerError.officialCannotJoin(id: profileID)
        }
        var newStack = stack
        var toolStack = newStack.toolStack(profile.tool)
        guard !toolStack.isMember(profileID) else { return }   // 无变化
        let registry = AggregationKeyRegistry(keys: toolStack.keys)
        _ = registry.allocate(profile: profile)
        toolStack.keys = registry.keys
        toolStack.members.append(profileID)
        newStack.setToolStack(toolStack, for: profile.tool)
        commit(stack: newStack)
        try rewriteProjectionIfChanged(tool: profile.tool)
    }

    /// 移除成员：默认那家在聚合开启期间不可移除；key 永久保留。
    func removeMember(_ profileID: String) throws {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw AggregationManagerError.profileNotFound(id: profileID)
        }
        var newStack = stack
        var toolStack = newStack.toolStack(profile.tool)
        guard toolStack.isMember(profileID) else { return }
        if toolStack.enabled, profileID == toolStack.members.first {
            throw AggregationManagerError.defaultMemberLocked(id: profileID)
        }
        toolStack.members.removeAll { $0 == profileID }
        newStack.setToolStack(toolStack, for: profile.tool)
        commit(stack: newStack)
        try rewriteProjectionIfChanged(tool: profile.tool)
    }

    /// 设默认那家：移到名单首位（聚合开启期间同步重写投影）。
    func setDefault(_ profileID: String) throws {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw AggregationManagerError.profileNotFound(id: profileID)
        }
        var newStack = stack
        var toolStack = newStack.toolStack(profile.tool)
        guard toolStack.isMember(profileID) else {
            throw AggregationManagerError.notMember(id: profileID)
        }
        toolStack.members.removeAll { $0 == profileID }
        toolStack.members.insert(profileID, at: 0)
        newStack.setToolStack(toolStack, for: profile.tool)
        commit(stack: newStack)
        try rewriteProjectionIfChanged(tool: profile.tool)
    }

    // MARK: - 生命周期

    /// 重新列举 profile；按工具重建登记簿、按名称重绑定 key、摘除已删除的 profile（key 保留）。
    func refresh() {
        profiles = ProviderTool.allCases.flatMap { profileStore.list(for: $0) }
        var newStack = stack
        for tool in ProviderTool.allCases {
            var toolStack = newStack.toolStack(tool)
            toolStack.members.removeAll { profileID in
                !profiles.contains { $0.id == profileID }
            }
            let registry = AggregationKeyRegistry(keys: toolStack.keys)
            for key in toolStack.keys.keys {
                _ = registry.resolve(key: key, candidates: profiles)
            }
            toolStack.keys = registry.keys
            newStack.setToolStack(toolStack, for: tool)
        }
        commit(stack: newStack)
    }

    /// 启动自愈（非 throws——内部吞错置 `lastError`，不阻断启动）：
    /// pending 前滚/丢弃；聚合中的工具确保代理在跑，起不来则回落直连。
    func recoverOnLaunch() {
        defer { syncProxyState() }
        if let pending = pendingStore.load() {
            switch AggregationPendingStore.recovery(for: pending) {
            case .rolledForward:
                commit(stack: pending.stack)
                rollForward(pending)
            case .discarded:
                try? pendingStore.clear()
            }
        }
        for tool in ProviderTool.allCases where stack.toolStack(tool).enabled {
            guard !proxy.isRunning else { continue }
            do {
                try proxy.start()
            } catch {
                fallbackToDirect(tool: tool)
                lastError = Self.message(for: error)
            }
        }
    }

    /// 供 `FeatureFactory.teardownSync` 调用：停代理。
    func stopProxyForTeardown() {
        proxy.stop()
        syncProxyState()
    }

    /// 刷新 Codex 陈旧客户端检测结果（面板横幅用）。
    func refreshStaleClients() async {
        guard stack.toolStack(.codex).enabled else {
            staleClients = nil
            return
        }
        staleClients = await staleDetector.staleClients(
            catalogURL: Self.codexAggregationCatalogURL(),
            catalogIsOurs: true
        )
    }

    /// 重启 Codex 托管守护进程（陈旧客户端一键重启）：读 `daemon.pid` 并发 SIGTERM，
    /// 守护进程由其 Supervisor 重新拉起。pid 文件缺失/进程不在 → false（未在运行）。
    func restartCodexDaemon() -> Bool {
        let pidURL = ProviderSwitchPaths.codexHome()
            .appendingPathComponent("app-server-daemon/daemon.pid")
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              kill(pid, SIGTERM) == 0 else {
            return false
        }
        return true
    }

    // MARK: - 生产装配

    /// 生产实现装配（真实路径）。单测绕开它，直接用注入式 `init`。
    static func production(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> ProviderAggregationManager {
        let root = applicationSupportRoot
            ?? (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("app.omniforge", isDirectory: true))
            ?? fileManager.temporaryDirectory
        let aggregationRoot = root.appendingPathComponent("ProviderAggregation", isDirectory: true)
        let profileStore = ProviderProfileStore(
            claudeProfileDirectory: ProviderSwitchPaths.claudeProfileDirectory(homePath: homePath, environment: environment),
            codexProfileDirectory: ProviderSwitchPaths.codexProfileDirectory(homePath: homePath, environment: environment),
            fileManager: fileManager
        )
        // 迟绑定：代理持 binding，管理器就位后喂快照（破解「代理要解析器、解析器要管理器」的循环初始化）。
        let binding = AggregationProxyBinding()
        let proxy = AggregationProxy(
            resolver: binding,
            modelLister: binding,
            forwarder: AggregationURLSessionForwarder()
        )
        let manager = ProviderAggregationManager(
            profileStore: profileStore,
            backupStore: ProviderBackupStore(
                backupDirectory: ProviderSwitchPaths.backupDirectory(applicationSupportRoot: root)
            ),
            stackStore: AggregationStackStore(
                stackURL: aggregationRoot.appendingPathComponent("stack.json"),
                fileManager: fileManager
            ),
            pendingStore: AggregationPendingStore(
                pendingURL: aggregationRoot.appendingPathComponent("pending.json"),
                fileManager: fileManager
            ),
            loginStashStore: CodexLoginStashStore(
                authURL: CodexAuthFileCredentialReader.defaultAuthURL(homePath: homePath, environment: environment),
                stashURL: ProviderSwitchPaths.codexHome(homePath: homePath, environment: environment)
                    .appendingPathComponent(CodexLoginStashStore.stashFileName),
                fileManager: fileManager
            ),
            staleDetector: CodexStaleClientDetector(
                historyURL: aggregationRoot.appendingPathComponent("codex-catalog-history.json"),
                fileManager: fileManager
            ),
            proxy: proxy,
            claudeWriter: AggregationClaudeConfigWriter(
                settingsURL: ProviderSwitchPaths.claudeSettingsURL(homePath: homePath, environment: environment),
                fileManager: fileManager
            ),
            codexWriter: AggregationCodexConfigWriter(
                configURL: ProviderSwitchPaths.codexConfigURL(homePath: homePath, environment: environment),
                catalogURL: ProviderSwitchPaths.codexAggregationCatalogURL(homePath: homePath, environment: environment),
                fileManager: fileManager
            ),
            profiles: ProviderTool.allCases.flatMap { profileStore.list(for: $0) },
            fileManager: fileManager,
            proxyBinding: binding
        )
        binding.update(manager.proxySnapshot())
        return manager
    }

    // MARK: - private

    /// 提交栈态：内存 + 落盘 + 喂代理快照。
    private func commit(stack newStack: AggregationStack) {
        stack = newStack
        try? stackStore.save(newStack)
        proxyBinding?.update(proxySnapshot())
    }

    private func syncProxyState() {
        isProxyRunning = proxy.isRunning
        resolvedPort = proxy.resolvedPort
    }

    private func stopProxyIfIdle(_ currentStack: AggregationStack) {
        guard !currentStack.toolStack(.claudeCode).enabled,
              !currentStack.toolStack(.codex).enabled else {
            syncProxyState()
            return
        }
        proxy.stop()
        syncProxyState()
    }

    /// 进入聚合的投影写入（无条件）。
    private func publishProjection(tool: ProviderTool, defaultProfile: ProviderProfile, port: UInt16) throws {
        try writeProjection(tool: tool, defaultProfile: defaultProfile, port: port)
        observeCatalogIfNeeded(tool: tool)
    }

    /// 名单变化后的投影写入：契约未变则跳过（避免无谓改写配置、无谓触发重新选模型提示）。
    private func rewriteProjectionIfChanged(tool: ProviderTool) throws {
        guard stack.toolStack(tool).enabled, let port = proxy.resolvedPort else { return }
        guard let defaultID = stack.toolStack(tool).members.first,
              let defaultProfile = profiles.first(where: { $0.id == defaultID }) else {
            return
        }
        let published = publishedModels(tool: tool)
        let changed: Bool
        switch tool {
        case .claudeCode:
            let memberSwitches = mergedSwitches(tool: tool, defaultProfile: defaultProfile)
            changed = claudeWriter.currentContractDigest()
                != claudeWriter.projectedContractDigest(
                    defaultProfile: defaultProfile, published: published, port: port,
                    memberSwitches: memberSwitches
                )
        case .codex:
            changed = codexWriter.currentContractDigest()
                != codexWriter.projectedContractDigest(
                    defaultProfile: defaultProfile, published: published, port: port,
                    requiresOpenAIAuth: loginStashStore.hasNativeLogin
                )
        }
        guard changed else { return }
        try writeProjection(tool: tool, defaultProfile: defaultProfile, port: port)
        observeCatalogIfNeeded(tool: tool)
    }

    private func writeProjection(tool: ProviderTool, defaultProfile: ProviderProfile, port: UInt16) throws {
        let published = publishedModels(tool: tool)
        switch tool {
        case .claudeCode:
            try claudeWriter.applyAggregation(
                defaultProfile: defaultProfile, published: published, port: port,
                memberSwitches: mergedSwitches(tool: tool, defaultProfile: defaultProfile)
            )
        case .codex:
            try codexWriter.applyAggregation(
                defaultProfile: defaultProfile, published: published, port: port,
                requiresOpenAIAuth: loginStashStore.hasNativeLogin
            )
        }
    }

    /// 成员兼容开关合并：底子=默认那家，`others`=名单内其余成员（名单序）。
    /// 合并源 = 名单内该工具全部成员的 `extraEnv`（见 `AggregationSwitchMerger`）。
    private func mergedSwitches(tool: ProviderTool, defaultProfile: ProviderProfile) -> [String: String] {
        let others = stack.toolStack(tool).members
            .filter { $0 != defaultProfile.id }
            .compactMap { id in profiles.first(where: { $0.id == id }) }
        return AggregationSwitchMerger.mergedValues(defaultProfile: defaultProfile, others: others)
    }

    /// Codex 投影写后记录目录代（陈旧客户端检测的基准）。
    private func observeCatalogIfNeeded(tool: ProviderTool) {
        guard tool == .codex else { return }
        staleDetector.observe(catalogURL: Self.codexAggregationCatalogURL(), catalogIsOurs: true)
    }

    private func clearAggregationKeys(tool: ProviderTool) throws {
        switch tool {
        case .claudeCode: try claudeWriter.clearAggregation()
        case .codex: try codexWriter.clearAggregation()
        }
    }

    /// 看门狗：代理异常退出 → 重启；重启失败 → 聚合中的工具全部回落直连并报错。
    private func handleProxyUnexpectedStop() {
        do {
            try proxy.start()
            syncProxyState()
        } catch {
            for tool in ProviderTool.allCases where stack.toolStack(tool).enabled {
                fallbackToDirect(tool: tool)
            }
            lastError = Self.message(for: error)
            syncProxyState()
        }
    }

    /// 回落直连：从最近快照恢复（快照不可用 → 仅清聚合键）→ 还原 Codex 登录 →
    /// 摘模式位（保留名单与登记簿）→ 无工具聚合则停代理。
    private func fallbackToDirect(tool: ProviderTool) {
        if let backup = backupStore.list(tool: tool).first {
            try? backupStore.restore(backup, to: Self.configURL(for: tool))
        } else {
            try? clearAggregationKeys(tool: tool)
        }
        if tool == .codex {
            try? loginStashStore.restore()
        }
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = false
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        stopProxyIfIdle(newStack)
    }

    /// 前滚：按 pending 的新名单幂等补完投影（摘要未变则跳过）。
    private func rollForward(_ pending: AggregationPending) {
        guard let defaultID = pending.stack.toolStack(pending.tool).members.first,
              let defaultProfile = profiles.first(where: { $0.id == defaultID }),
              proxy.isRunning,
              let port = proxy.resolvedPort else {
            try? pendingStore.clear()
            return
        }
        try? rewriteProjectionIfChanged(tool: pending.tool)
        _ = (defaultProfile, port)
        try? pendingStore.clear()
    }

    /// 单个 profile 的已发布模型。
    private func publishedModels(for profile: ProviderProfile) -> [AggregationPublishedModel] {
        guard let key = stack.toolStack(profile.tool).keyOf(profileID: profile.id) else { return [] }
        switch profile.tool {
        case .claudeCode:
            return AggregationModelPublisher.published(profile: profile, key: key)
        case .codex:
            return Self.codexPublishedModels(profile: profile, key: key)
        }
    }

    /// Codex 侧发布源：profile 的成员模型条目逐条转发布条目（原名直出——
    /// Codex 的 Stack id 不带 1M 标记，还原时用裸模型名）。
    /// 显示名/窗口取条目值（SPEC 7 / P1-8），未配置回落旧口径：显示名回落模型名、窗口回落 extraEnv 全局值。
    private static func codexPublishedModels(profile: ProviderProfile, key: String) -> [AggregationPublishedModel] {
        let fallbackWindow = UInt64(profile.extraEnv["model_context_window"] ?? "") ?? 1_000_000
        return profile.codexModelEntries.map { entry in
            AggregationPublishedModel(
                key: key,
                profileName: profile.name,
                model: entry.model,
                upstream: entry.model,
                displayName: entry.displayName ?? entry.model,
                oneM: false,
                window: entry.contextWindow ?? fallbackWindow
            )
        }
    }

    /// 代理侧只读快照（生产装配用：迟绑定解析/列表）。
    func proxySnapshot() -> AggregationProxySnapshot {
        var stacks: [ProviderTool: AggregationStack.ToolStack] = [:]
        var defaultTargets: [ProviderTool: AggregationProxyTarget] = [:]
        var published: [ProviderTool: [AggregationPublishedModel]] = [:]
        for tool in ProviderTool.allCases {
            let toolStack = stack.toolStack(tool)
            stacks[tool] = toolStack
            if let defaultID = toolStack.members.first,
               let profile = profiles.first(where: { $0.id == defaultID }) {
                defaultTargets[tool] = AggregationProxyTarget(
                    key: toolStack.keyOf(profileID: defaultID) ?? "",
                    profileID: defaultID,
                    baseURL: profile.baseURL,
                    token: profile.token
                )
            }
            published[tool] = publishedModels(tool: tool)
        }
        return AggregationProxySnapshot(
            stacks: stacks,
            profiles: profiles,
            defaultTargets: defaultTargets,
            published: published
        )
    }

    /// 官方账号判定：指向厂商官方端点（或无 override 的空 baseURL）的 profile。
    /// 官方账号只能作为默认供应商，不能加入聚合（SPEC 6.9）；按宿主识别比任何
    /// 分类标记更宽——未标 category 的官方托管账号同样命中。
    static func isOfficial(_ profile: ProviderProfile) -> Bool {
        let host = URL(string: profile.baseURL)?.host?.lowercased() ?? ""
        switch profile.tool {
        case .claudeCode:
            return host.isEmpty || host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
        case .codex:
            return host.isEmpty
                || host == "api.openai.com" || host.hasSuffix(".openai.com")
                || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AggregationProxyError.allPortsTaken:
            return "聚合代理端口全部被占用，已回落到直连模式"
        case AggregationProxyError.alreadyRunning:
            return "聚合代理已在运行"
        default:
            return error.localizedDescription
        }
    }

    private static func configURL(for tool: ProviderTool) -> URL {
        ProviderSwitchPaths.configURL(for: tool)
    }

    private static func codexAggregationCatalogURL() -> URL {
        ProviderSwitchPaths.codexAggregationCatalogURL()
    }
}

// MARK: - 错误

enum AggregationManagerError: Error, Equatable {
    case profileNotFound(id: String)
    case toolMismatch(id: String, expected: ProviderTool)
    case incompleteConnection(id: String)
    case officialCannotJoin(id: String)
    case defaultMemberLocked(id: String)
    case notMember(id: String)
}

// MARK: - 代理侧快照与迟绑定

/// 代理侧解析/列表的只读快照（编排层状态变化时整体替换）。
struct AggregationProxySnapshot {
    var stacks: [ProviderTool: AggregationStack.ToolStack]
    var profiles: [ProviderProfile]
    var defaultTargets: [ProviderTool: AggregationProxyTarget]
    var published: [ProviderTool: [AggregationPublishedModel]]
}

/// 生产装配的迟绑定 — 代理持它做解析/列表，管理器就位后喂快照。
/// 快照经锁整体替换：读取侧（连接队列）拿到的必为自洽快照，无跨线程可变状态。
final class AggregationProxyBinding: AggregationResolving, AggregationProxyModelListing {
    private let lock = NSLock()
    private var snapshot: AggregationProxySnapshot?

    func update(_ snapshot: AggregationProxySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
    }

    func resolve(tool: ProviderTool, model: String) -> AggregationResolution {
        let current = locked { snapshot }
        guard let current,
              let toolStack = current.stacks[tool],
              let defaultTarget = current.defaultTargets[tool] else {
            return .miss(.stackOff)
        }
        return AggregationTargetResolver(
            stack: toolStack,
            registry: AggregationKeyRegistry(keys: toolStack.keys),
            profiles: current.profiles,
            defaultTarget: defaultTarget
        ).resolve(tool: tool, model: model)
    }

    func publishedModels(tool: ProviderTool) -> [AggregationPublishedModel] {
        locked { snapshot }?.published[tool] ?? []
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
