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
    /// 模式切换成功后驱动直连激活态重算（生产装配传入 `ProviderSwitchManager`；nil = 不驱动）。
    private let activationRefresher: ProviderActivationRefreshing?
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
        proxyBinding: AggregationProxyBinding? = nil,
        activationRefresher: ProviderActivationRefreshing? = nil
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
        self.activationRefresher = activationRefresher
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
            guard let profile = profile(id: profileID, tool: tool) else { return nil }
            let published = publishedModels(for: profile)
            return AggregationMemberView(
                id: profileID,
                name: profile.name,
                isDefault: profileID == toolStack.members.first,
                isOfficial: Self.isOfficial(profile),
                publishedCount: published.count,
                // 选择器 id 按工具编码：Codex 是 `om-<key>/<model>`，Claude 是
                // `om-claude-<key>--<model>`——`AggregationPublishedModel.id` 恒为
                // Claude 编码，Codex 成员直接用它会把 Claude 形态显示给用户。
                modelIDs: published.map { entry in
                    AggregationModelID.encode(
                        tool: tool, key: entry.key, model: entry.model, oneM: entry.oneM
                    )
                }
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

    /// 按 (id, tool) 定位卡片——profile id 只在单工具目录内唯一，跨工具可同名
    /// （如两侧都建了 DeepSeek 卡，id 同为 "deepseek"）；仅按 id 在全工具数组里查找
    /// 会命中排在前面的别家卡，报「不属于当前工具」或更隐蔽的错乱。
    private func profile(id: String, tool: ProviderTool) -> ProviderProfile? {
        profiles.first { $0.id == id && $0.tool == tool }
    }

    /// 聚合上下文里的官方卡实体（Codex 为合成卡或用户自建官方卡；Claude 仅有
    /// 用户自建官方卡；无 → nil）。UI 官方入口卡与默认候选回落共用。
    func officialProfile(tool: ProviderTool) -> ProviderProfile? {
        profiles.first { $0.tool == tool && $0.isOfficial }
    }

    /// 聚合上下文里官方卡的 id。UI 的默认候选回落用——官方是「系统态」没有
    /// profileID，聚合面板要能看到它。
    func officialProfileID(tool: ProviderTool) -> String? {
        officialProfile(tool: tool)?.id
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
        guard let defaultProfile = profile(id: defaultProfileID, tool: tool) else {
            throw AggregationManagerError.profileNotFound(id: defaultProfileID)
        }
        guard defaultProfile.hasCompleteConnection || Self.isOfficial(defaultProfile) else {
            throw AggregationManagerError.incompleteConnection(id: defaultProfileID)
        }
        try validateOfficialDefaultLogin(tool: tool, defaultProfile: defaultProfile)
        // 已在聚合 → 视为切换默认那家。
        if stack.toolStack(tool).enabled {
            try setDefault(defaultProfileID, tool: tool)
            return
        }

        // 1) 起代理（失败即抛，不写任何配置）。
        try proxy.start()
        guard let port = proxy.resolvedPort else { throw AggregationProxyError.allPortsTaken }
        syncProxyState()

        // 2) Codex 官方登录收纳（仅 Codex）——跟随默认那家是否官方。
        syncCodexLoginStash(tool: tool, defaultProfile: defaultProfile)

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
        let defaultKey = registry.allocate(profile: defaultProfile)
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

        // 7) 写该工具投影（新栈此刻还没 commit，故 key 由调用方显式带下去）。
        do {
            try publishProjection(tool: tool, defaultProfile: defaultProfile, defaultKey: defaultKey, port: port)
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
        // 与异步路径同一条契约：切换成功即驱动激活态重算。
        activationRefresher?.refreshActivationState()
    }

    /// 异步非阻塞进入聚合（UI 优先使用）：先起代理，再将快照、pending 写盘、配置文件覆盖与
    /// 清理等耗时磁盘 I/O 移至后台线程执行，完成后切回主线程提交栈态，消除主线程卡顿与掉帧。
    func enterAggregationAsync(tool: ProviderTool, defaultProfileID: String) async throws {
        guard let defaultProfile = profile(id: defaultProfileID, tool: tool) else {
            throw AggregationManagerError.profileNotFound(id: defaultProfileID)
        }
        guard defaultProfile.hasCompleteConnection || Self.isOfficial(defaultProfile) else {
            throw AggregationManagerError.incompleteConnection(id: defaultProfileID)
        }
        try validateOfficialDefaultLogin(tool: tool, defaultProfile: defaultProfile)
        if stack.toolStack(tool).enabled {
            try setDefault(defaultProfileID, tool: tool)
            return
        }

        try proxy.start()
        guard let port = proxy.resolvedPort else { throw AggregationProxyError.allPortsTaken }
        syncProxyState()

        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = true
        if !toolStack.isMember(defaultProfileID) {
            toolStack.members.insert(defaultProfileID, at: 0)
        }
        let registry = AggregationKeyRegistry(keys: toolStack.keys)
        let defaultKey = registry.allocate(profile: defaultProfile)
        toolStack.keys = registry.keys
        newStack.setToolStack(toolStack, for: tool)

        let backupStore = self.backupStore
        let pendingStore = self.pendingStore
        let loginStashStore = self.loginStashStore
        let staleDetector = self.staleDetector
        let claudeWriter = self.claudeWriter
        let codexWriter = self.codexWriter
        let configURL = Self.configURL(for: tool)
        let codexCatalogURL = Self.codexAggregationCatalogURL()
        let codexAuthURL = Self.codexAuthURL()
        let isDefaultOfficial = Self.isOfficial(defaultProfile)
        let published = publishedModels(tool: tool)
        let memberSwitches = mergedSwitches(tool: tool, defaultProfile: defaultProfile)

        struct AsyncEnterError: Error {
            let error: Error
            let enteredPublished: Bool
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var enteredPublished = false
                    do {
                        if tool == .codex {
                            if isDefaultOfficial {
                                try? loginStashStore.restore()
                                staleDetector.observeLogin(authURL: codexAuthURL)
                            } else {
                                staleDetector.observeLogin(authURL: codexAuthURL)
                                try? loginStashStore.stash()
                            }
                        }

                        try? backupStore.snapshot(tool: tool, of: configURL)

                        let intent = AggregationPending(tool: tool, stack: newStack, published: false)
                        try pendingStore.save(intent)

                        var entered = intent
                        entered.published = true
                        try pendingStore.save(entered)
                        enteredPublished = true

                        switch tool {
                        case .claudeCode:
                            try claudeWriter.applyAggregation(
                                defaultProfile: defaultProfile,
                                published: published,
                                port: port,
                                memberSwitches: memberSwitches
                            )
                        case .codex:
                            try codexWriter.applyAggregation(
                                defaultProfile: defaultProfile,
                                defaultKey: defaultKey,
                                published: published,
                                port: port,
                                requiresOpenAIAuth: loginStashStore.hasNativeLogin
                            )
                            staleDetector.observe(catalogURL: codexCatalogURL, catalogIsOurs: true)
                        }

                        try? pendingStore.clear()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: AsyncEnterError(error: error, enteredPublished: enteredPublished))
                    }
                }
            }

            lastPartialWrite = false
            commit(stack: newStack)
            // 模式已切换且投影已写盘：驱动直连激活态重算，避免 UI 缓存停留在旧值
            // （退出不刷旧的根因修复，见 ProviderActivationRefreshing 注释）。
            activationRefresher?.refreshActivationState()
        } catch let asyncError as AsyncEnterError {
            if asyncError.enteredPublished {
                lastPartialWrite = true
                commit(stack: newStack)
            }
            throw asyncError.error
        }
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
            // 还原之后记一代登录：auth.json 从无到有/换人都是代次变化（P1-9 挂点）。
            observeCodexLoginGeneration()
        }
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = false
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        stopProxyIfIdle(newStack)
        // 与异步路径同一条契约：恢复直连即驱动激活态重算。
        activationRefresher?.refreshActivationState()
    }

    /// 异步非阻塞退出聚合（UI 优先使用）：将快照恢复与文件写入移至后台线程，
    /// 完成后切回主线程提交栈态并根据需要停止代理。
    func exitAggregationAsync(tool: ProviderTool) async throws {
        let backupStore = self.backupStore
        let claudeWriter = self.claudeWriter
        let codexWriter = self.codexWriter
        let loginStashStore = self.loginStashStore
        let staleDetector = self.staleDetector
        let configURL = Self.configURL(for: tool)
        let codexAuthURL = Self.codexAuthURL()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if let backup = backupStore.list(tool: tool).first {
                        try backupStore.restore(backup, to: configURL)
                    } else {
                        switch tool {
                        case .claudeCode: try claudeWriter.clearAggregation()
                        case .codex: try codexWriter.clearAggregation()
                        }
                    }
                } catch {
                    do {
                        switch tool {
                        case .claudeCode: try claudeWriter.clearAggregation()
                        case .codex: try codexWriter.clearAggregation()
                        }
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }
                if tool == .codex {
                    try? loginStashStore.restore()
                    staleDetector.observeLogin(authURL: codexAuthURL)
                }
                continuation.resume()
            }
        }

        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = false
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        stopProxyIfIdle(newStack)
        // 配置已从快照恢复为直连态：驱动激活态重算，消除缓存里的投影态残留
        // （2026-10-17 实测：退出聚合后「未托管配置」横幅常驻至重启）。
        activationRefresher?.refreshActivationState()
    }

    // MARK: - 成员管理

    /// 加入成员：分配永久 key；官方账号不可加入；已在名单里 → 无变化（不重写）。
    /// `tool` 必传：同名卡跨工具并存时仅按 id 定位有歧义。
    func addMember(_ profileID: String, tool: ProviderTool) throws {
        guard let profile = profile(id: profileID, tool: tool) else {
            throw AggregationManagerError.profileNotFound(id: profileID)
        }
        guard !Self.isOfficial(profile) else {
            throw AggregationManagerError.officialCannotJoin(id: profileID)
        }
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        guard !toolStack.isMember(profileID) else { return }   // 无变化
        let registry = AggregationKeyRegistry(keys: toolStack.keys)
        _ = registry.allocate(profile: profile)
        toolStack.keys = registry.keys
        toolStack.members.append(profileID)
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        try rewriteProjectionIfChanged(tool: profile.tool)
    }

    /// 移除成员：默认那家在聚合开启期间不可移除；key 永久保留。
    func removeMember(_ profileID: String, tool: ProviderTool) throws {
        guard profile(id: profileID, tool: tool) != nil else {
            throw AggregationManagerError.profileNotFound(id: profileID)
        }
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        guard toolStack.isMember(profileID) else { return }
        if toolStack.enabled, profileID == toolStack.members.first {
            throw AggregationManagerError.defaultMemberLocked(id: profileID)
        }
        toolStack.members.removeAll { $0 == profileID }
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        try rewriteProjectionIfChanged(tool: tool)
    }

    /// 设默认那家：移到名单首位（聚合开启期间同步重写投影）。
    /// 不在名单的卡（典型是官方卡——官方进聚合只有默认位一条路）一并分配 key
    /// 入座上位，原来的默认留在名单里（对齐 cc-switch「设为默认一家还没添加的：
    /// 一起加入名单」）。
    func setDefault(_ profileID: String, tool: ProviderTool) throws {
        guard let profile = profile(id: profileID, tool: tool) else {
            throw AggregationManagerError.profileNotFound(id: profileID)
        }
        try validateOfficialDefaultLogin(tool: tool, defaultProfile: profile)
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        var registry = AggregationKeyRegistry(keys: toolStack.keys)
        _ = registry.allocate(profile: profile)
        toolStack.keys = registry.keys
        toolStack.members.removeAll { $0 == profileID }
        toolStack.members.insert(profileID, at: 0)
        newStack.setToolStack(toolStack, for: tool)
        // 默认那家换了人 → 登录收纳态跟着换（SPEC 3 / P0-3 契约 3）：投影会翻到官方
        // 分支（或不翻），收纳态若停在切换前的样子，官方登录就会被第三方路由抢占用、
        // 或官方分支发现自己依赖的登录还被收着。仅在聚合生效期间有意义——未聚合时
        // 不动用户的登录态。`stash`/`restore` 无事可做时都是无副作用的空操作，重复调用安全。
        if toolStack.enabled {
            syncCodexLoginStash(tool: tool, defaultProfile: profile)
        }
        commit(stack: newStack)
        try rewriteProjectionIfChanged(tool: tool)
    }

    // MARK: - 生命周期

    /// 重新列举 profile；按工具重建登记簿、按名称重绑定 key、摘除已删除的 profile（key 保留）。
    func refresh() {
        profiles = Self.loadProfilesWithSyntheticOfficial(
            profileStore: profileStore,
            modelsCacheURL: ProviderSwitchPaths.codexModelsCacheURL(),
            fileManager: fileManager
        )
        var newStack = stack
        for tool in ProviderTool.allCases {
            var toolStack = newStack.toolStack(tool)
            let toolProfiles = profiles.filter { $0.tool == tool }
            toolStack.members.removeAll { profileID in
                !toolProfiles.contains { $0.id == profileID }
            }
            let registry = AggregationKeyRegistry(keys: toolStack.keys)
            for key in toolStack.keys.keys {
                _ = registry.resolve(key: key, candidates: toolProfiles)
            }
            toolStack.keys = registry.keys
            newStack.setToolStack(toolStack, for: tool)
        }
        if newStack != stack {
            commit(stack: newStack)
        } else {
            proxyBinding?.update(proxySnapshot())
        }
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
    /// 与 cc-switch 的差异：不等守护进程停机宽限期（60-300s）再起新的——我方 SIGTERM 即返，
    /// 由 Codex 自己的 Supervisor 负责重拉（P1-9 保留简化）。
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

    /// 用户关掉陈旧横幅：记下当前目录与登录指纹，同一份不再提示，指纹再变才重现（P1-9）。
    func acknowledgeStaleClients() {
        staleDetector.acknowledge(
            catalogURL: Self.codexAggregationCatalogURL(),
            authURL: Self.codexAuthURL()
        )
    }

    // MARK: - 生产装配

    /// 生产实现装配（真实路径）。单测绕开它，直接用注入式 `init`。
    /// `activationRefresher`：模式切换成功后驱动直连激活态重算（`FeatureFactory` 喂
    /// `ProviderSwitchManager`；缺省 nil = 不驱动，仅单测/降级装配用）。
    static func production(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default,
        activationRefresher: ProviderActivationRefreshing? = nil
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
                historyURL: aggregationRoot.appendingPathComponent(CodexStaleClientDetector.historyFileName),
                loginHistoryURL: aggregationRoot.appendingPathComponent(CodexStaleClientDetector.loginHistoryFileName),
                ackURL: aggregationRoot.appendingPathComponent(CodexStaleClientDetector.ackFileName),
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
            profiles: Self.loadProfilesWithSyntheticOfficial(
                profileStore: profileStore,
                modelsCacheURL: ProviderSwitchPaths.codexModelsCacheURL(
                    homePath: homePath, environment: environment
                ),
                fileManager: fileManager
            ),
            fileManager: fileManager,
            proxyBinding: binding,
            activationRefresher: activationRefresher
        )
        binding.update(manager.proxySnapshot())
        return manager
    }

    // MARK: - private

    /// 合成内置官方卡的固定 id（仅 Codex；Claude 官方无 OAuth 无凭证形态，不合成）。
    static let officialCodexProfileID = "official-codex"

    /// 聚合上下文的 profile 快照：磁盘全部卡片 + （Codex 侧无任何官方卡片时）合成的
    /// 内置「OpenAI 官方」卡——官方否则没有 profile 实体，进不了默认候选，聚合面板里
    /// 也就看不到官方。合成卡只存在于聚合上下文（直连列表不注入，避免与官方行重复）；
    /// 用户自建官方卡（baseURL 为官方域）存在时不注入。
    /// 模型列表取 `models_cache.json` 的 slug 序列——官方行与目录合并同源。
    static func loadProfilesWithSyntheticOfficial(
        profileStore: ProviderProfileStoring,
        modelsCacheURL: URL,
        fileManager: FileManager
    ) -> [ProviderProfile] {
        var all = ProviderTool.allCases.flatMap { profileStore.list(for: $0) }
        let hasCodexOfficial = all.contains { $0.tool == .codex && $0.isOfficial }
        if !hasCodexOfficial {
            let slugs = (CodexModelCatalogStore.officialCacheRows(
                modelsCacheURL: modelsCacheURL, fileManager: fileManager
            ) ?? [])
                .compactMap { $0["slug"] as? String }
            all.append(ProviderProfile(
                id: officialCodexProfileID,
                name: "OpenAI",
                tool: .codex,
                baseURL: "https://api.openai.com/v1",
                token: "",
                codexModels: slugs
            ))
        }
        return all
    }

    /// 官方默认的前置登录校验（方案 B 契约）：custom 表 + `requires_openai_auth` 依赖
    /// auth.json 的 OAuth 凭证在场，缺失时进入只会在官方上游收到 401——事前挡下并指路。
    private func validateOfficialDefaultLogin(tool: ProviderTool, defaultProfile: ProviderProfile) throws {
        guard tool == .codex, Self.isOfficial(defaultProfile) else { return }
        guard loginStashStore.hasNativeLogin else {
            throw AggregationManagerError.officialLoginRequired
        }
    }

    /// Codex 官方登录收纳跟随「默认那家是否官方」（SPEC 3 / P0-3 契约 3）：
    /// 第三方默认 → 收纳官方登录（第三方投影写的是占位 token，用不上 OAuth 登录，
    /// 不收起来会被它抢占）；官方默认 → 不收纳，并还原此前已收纳的登录。
    /// 进入聚合与「聚合中换默认那家」两条路径共用同一条规则。
    /// 登录代次挂点（P1-9）：第三方分支在 stash **前**、官方分支在 restore **后**各记一代
    /// ——auth.json 随后被移走/放回，登录从无到有或换人都是代次变化，老进程可能还缓存旧账号。
    /// `setDefault` 走同一函数，同理；`exitAggregation`/`fallbackToDirect` 的 restore 后另有一处。
    private func syncCodexLoginStash(tool: ProviderTool, defaultProfile: ProviderProfile) {
        guard tool == .codex else { return }
        if Self.isOfficial(defaultProfile) {
            try? loginStashStore.restore()
            observeCodexLoginGeneration()
        } else {
            observeCodexLoginGeneration()
            try? loginStashStore.stash()
        }
    }

    /// 记一次 Codex 登录代次（陈旧客户端检测：登录身份变了，进程可能还缓存旧账号）。
    private func observeCodexLoginGeneration() {
        staleDetector.observeLogin(authURL: Self.codexAuthURL())
    }

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
    private func publishProjection(tool: ProviderTool, defaultProfile: ProviderProfile, defaultKey: String, port: UInt16) throws {
        try writeProjection(tool: tool, defaultProfile: defaultProfile, defaultKey: defaultKey, port: port)
        observeCatalogIfNeeded(tool: tool)
    }

    /// 名单变化后的投影写入：契约未变则跳过（避免无谓改写配置、无谓触发重新选模型提示）。
    private func rewriteProjectionIfChanged(tool: ProviderTool) throws {
        guard stack.toolStack(tool).enabled, let port = proxy.resolvedPort else { return }
        guard let defaultID = stack.toolStack(tool).members.first,
              let defaultProfile = profile(id: defaultID, tool: tool) else {
            return
        }
        // 默认那家的登记簿 key：Codex 目录按它认「哪些 published 行属于默认那家」。
        let defaultKey = stack.toolStack(tool).keyOf(profileID: defaultID) ?? ""
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
                    defaultProfile: defaultProfile, defaultKey: defaultKey, published: published, port: port,
                    requiresOpenAIAuth: loginStashStore.hasNativeLogin
                )
        }
        guard changed else { return }
        try writeProjection(tool: tool, defaultProfile: defaultProfile, defaultKey: defaultKey, port: port)
        observeCatalogIfNeeded(tool: tool)
    }

    private func writeProjection(tool: ProviderTool, defaultProfile: ProviderProfile, defaultKey: String, port: UInt16) throws {
        let published = publishedModels(tool: tool)
        switch tool {
        case .claudeCode:
            try claudeWriter.applyAggregation(
                defaultProfile: defaultProfile, published: published, port: port,
                memberSwitches: mergedSwitches(tool: tool, defaultProfile: defaultProfile)
            )
        case .codex:
            try codexWriter.applyAggregation(
                defaultProfile: defaultProfile, defaultKey: defaultKey, published: published, port: port,
                requiresOpenAIAuth: loginStashStore.hasNativeLogin
            )
        }
    }

    /// 成员兼容开关合并：底子=默认那家，`others`=名单内其余成员（名单序）。
    /// 合并源 = 名单内该工具全部成员的 `extraEnv`（见 `AggregationSwitchMerger`）。
    private func mergedSwitches(tool: ProviderTool, defaultProfile: ProviderProfile) -> [String: String] {
        let others = stack.toolStack(tool).members
            .filter { $0 != defaultProfile.id }
            .compactMap { id in profile(id: id, tool: tool) }
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
            // 与 exitAggregation 同一条挂点：还原之后记一代登录。
            observeCodexLoginGeneration()
        }
        var newStack = stack
        var toolStack = newStack.toolStack(tool)
        toolStack.enabled = false
        newStack.setToolStack(toolStack, for: tool)
        commit(stack: newStack)
        stopProxyIfIdle(newStack)
        // 与退出的两条路径同契约：配置恢复为直连态即驱动激活态重算。
        activationRefresher?.refreshActivationState()
    }

    /// 前滚：按 pending 的新名单幂等补完投影（摘要未变则跳过）。
    private func rollForward(_ pending: AggregationPending) {
        guard let defaultID = pending.stack.toolStack(pending.tool).members.first,
              let defaultProfile = profile(id: defaultID, tool: pending.tool),
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
               let profile = profile(id: defaultID, tool: tool) {
                defaultTargets[tool] = AggregationProxyTarget(
                    key: toolStack.keyOf(profileID: defaultID) ?? "",
                    profileID: defaultID,
                    baseURL: profile.baseURL,
                    token: profile.token,
                    // 官方默认（**仅 Codex**）：登录走 auth.json OAuth、没有静态 token，
                    // 客户端自己的 Authorization 原样透传（换成空串只会 401；SPEC 3 契约 4）。
                    // Claude 侧官方 Anthropic 是静态 API key，投影写的又是占位 token，
                    // 必须照常替换（SPEC §3 收尾「Claude 侧不动」）——漏掉工具闸门会让
                    // `Bearer PROXY_MANAGED` 直达 Anthropic，每个请求都 401。
                    passesThroughAuthorization: tool == .codex && Self.isOfficial(profile)
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

    /// 官方账号判定 — 转发到 `ProviderProfile.isOfficial`（Models 层的纯谓词，
    /// 判据与「为何按宿主而非分类标记」的说明见那里）。保留本转发只为不一次性
    /// 改动全部调用点；新代码请直接读 `profile.isOfficial`。
    static func isOfficial(_ profile: ProviderProfile) -> Bool {
        profile.isOfficial
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

    /// Codex 登录身份文件 `auth.json`（登录代次指纹的取源；与收纳用的同一路径）。
    private static func codexAuthURL() -> URL {
        CodexAuthFileCredentialReader.defaultAuthURL()
    }
}

// MARK: - 错误

enum AggregationManagerError: Error, Equatable {
    case profileNotFound(id: String)
    case incompleteConnection(id: String)
    case officialCannotJoin(id: String)
    /// 官方做 Codex 聚合默认但官方登录（auth.json）不在场——custom 表 +
    /// `requires_openai_auth` 依赖 OAuth 凭证，缺失时官方上游只会回 401。
    case officialLoginRequired
    case defaultMemberLocked(id: String)
}

extension AggregationManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "在当前工具下找不到供应商档案（\(id)）：可能已被删除，或属于另一个工具的同名卡"
        case .incompleteConnection(let id):
            return "供应商（\(id)）连接信息不完整，请先补全地址与密钥"
        case .officialCannotJoin(let id):
            return "官方账号只能做默认供应商，不能加入聚合（\(id)）"
        case .officialLoginRequired:
            return "OpenAI 官方做默认需要 Codex 官方登录：请先在 Codex 登录官方账号，再切换默认"
        case .defaultMemberLocked(let id):
            return "默认供应商在聚合开启期间不可移除（\(id)）"
        }
    }
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
