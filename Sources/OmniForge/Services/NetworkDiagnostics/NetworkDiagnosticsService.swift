import AppKit
import Combine
import Foundation

// MARK: - 网络诊断聚合服务
//
// 工具型特性（对齐 ColorPickerService）：进程级单例，不进 AppState、不接 FeatureFactory Manager。
// 聚合网络身份 + 端口列表 + 公网 IP 状态；采集可注入便于单测。
// 刷新策略：进入 tab 各采一次；手动刷新当前分段；切换分段不重采；不轮询。

/// 端口列表范围：LISTEN 仅状态为 LISTEN；全部为 lsof 全量。
enum PortScope: String, CaseIterable, Equatable {
    case listen
    case all
}

/// 公网 IP 行三态；失败不保留上次值，显示「—」。
enum PublicIPState: Equatable {
    case idle
    case loading
    /// 任一为 nil 时该侧显示「—」；两者皆 nil 即查询失败。
    case resolved(ipv4: String?, ipv6: String?)
}

/// 端口列表上方提示条：部分权限 / 采集失败。
enum PortPermissionHint: Equatable {
    case none
    /// 有端口占用但进程信息不全。
    case partialPermission
    /// lsof 缺失或非零失败。
    case loadFailure
}

/// Runs blocking collector work (lsof / getifaddrs / name resolve).
/// Production: background queue. Tests may inject `{ $0() }` for synchronous completion.
typealias NetworkDiagnosticsBlockingRunner = (@escaping @Sendable () -> Void) -> Void

/// Default production runner: off-main so popover spinners can paint.
nonisolated(unsafe) let networkDiagnosticsBackgroundBlockingRunner: NetworkDiagnosticsBlockingRunner = { work in
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
}

/// Immediate runner for unit tests with sync fakes.
nonisolated(unsafe) let networkDiagnosticsImmediateBlockingRunner: NetworkDiagnosticsBlockingRunner = { work in
    work()
}

@MainActor
final class NetworkDiagnosticsService: ObservableObject {
    static let shared = NetworkDiagnosticsService()

    /// 提示条展开后可复制的提权采集命令。
    static let elevatedLsofCommand = "sudo lsof -nP -iTCP -sTCP:LISTEN"

    /// Default production runner: off-main so popover spinners can paint.
    static var backgroundBlockingRunner: NetworkDiagnosticsBlockingRunner {
        networkDiagnosticsBackgroundBlockingRunner
    }

    /// Immediate runner for unit tests with sync fakes.
    static var immediateBlockingRunner: NetworkDiagnosticsBlockingRunner {
        networkDiagnosticsImmediateBlockingRunner
    }

    // MARK: Published state

    @Published private(set) var networkIdentity: NetworkIdentity?
    @Published private(set) var ports: [PortEntry] = []
    /// PID → 展示名（NSRunningApplication / proc_pidpath / COMMAND）。
    @Published private(set) var processDisplayNames: [pid_t: String] = [:]
    @Published private(set) var publicIPState: PublicIPState = .idle
    @Published var portScope: PortScope = .listen
    @Published var searchText: String = ""
    @Published private(set) var permissionHint: PortPermissionHint = .none
    @Published private(set) var isRefreshingNetwork = false
    @Published private(set) var isRefreshingPorts = false

    // MARK: Dependencies

    private let identityProvider: NetworkIdentityProviding
    private let publicIPFetcher: PublicIPFetching
    private let portProbe: PortProbing
    private let nameResolver: ProcessNameResolving
    private let terminator: ProcessTerminating
    private let writer: PasteboardWriting
    private let blockingRunner: NetworkDiagnosticsBlockingRunner

    private var publicIPTask: Task<Void, Never>?
    private var publicIPGeneration = 0
    private var networkRefreshTask: Task<Void, Never>?
    private var networkRefreshGeneration = 0
    private var portsRefreshTask: Task<Void, Never>?
    private var portsRefreshGeneration = 0

    init(
        identityProvider: NetworkIdentityProviding = NetworkIdentityProvider(),
        publicIPFetcher: PublicIPFetching = PublicIPFetcher(),
        portProbe: PortProbing = PortProbe(),
        nameResolver: ProcessNameResolving = ProcessNameResolver(),
        terminator: ProcessTerminating = ProcessTerminator(),
        writer: PasteboardWriting = SystemPasteboardWriter(),
        blockingRunner: @escaping NetworkDiagnosticsBlockingRunner = networkDiagnosticsBackgroundBlockingRunner
    ) {
        self.identityProvider = identityProvider
        self.publicIPFetcher = publicIPFetcher
        self.portProbe = portProbe
        self.nameResolver = nameResolver
        self.terminator = terminator
        self.writer = writer
        self.blockingRunner = blockingRunner
    }

    // MARK: Derived

    /// 仅按 scope 过滤（不含搜索词），供仪表盘 hero 统计与协议构成使用，
    /// 避免搜索词改变总量数字。
    var scopedPorts: [PortEntry] {
        switch portScope {
        case .listen:
            return ports.filter { $0.state?.uppercased() == "LISTEN" }
        case .all:
            return ports
        }
    }

    /// 按 scope + searchText 过滤后的端口列表。
    var filteredPorts: [PortEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedPorts }
        return scopedPorts.filter { entry in
            if String(entry.localPort).contains(query) { return true }
            if entry.pid > 0, String(entry.pid).contains(query) { return true }
            let display = processDisplayName(for: entry)
            if display.localizedCaseInsensitiveContains(query) { return true }
            if entry.command.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    func processDisplayName(for entry: PortEntry) -> String {
        if let name = processDisplayNames[entry.pid], !name.isEmpty {
            return name
        }
        let fallback = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "—" : fallback
    }

    func canTerminate(_ entry: PortEntry) -> Bool {
        terminator.canTerminate(pid: entry.pid, name: processDisplayName(for: entry))
    }

    // MARK: Refresh

    /// 刷新本机网络身份，并异步查询公网 IP（失败静默）。
    /// 身份采集（getifaddrs / scutil）在后台执行，避免主线程卡死导致 spinner 无法绘制。
    func refreshNetwork() {
        isRefreshingNetwork = true
        networkRefreshGeneration += 1
        let networkGeneration = networkRefreshGeneration

        publicIPGeneration += 1
        let ipGeneration = publicIPGeneration
        publicIPState = .loading
        publicIPTask?.cancel()
        networkRefreshTask?.cancel()

        networkRefreshTask = Task { [weak self] in
            guard let self else { return }

            let provider = self.identityProvider
            let identity = await self.runBlocking {
                provider.makeIdentity(publicIPv4: nil, publicIPv6: nil)
            }
            guard !Task.isCancelled, self.networkRefreshGeneration == networkGeneration else { return }
            self.networkIdentity = identity
            self.isRefreshingNetwork = false

            async let ipv4Task = self.publicIPFetcher.fetchIPv4()
            async let ipv6Task = self.publicIPFetcher.fetchIPv6()
            let (ipv4, ipv6) = await (ipv4Task, ipv6Task)
            guard !Task.isCancelled, self.publicIPGeneration == ipGeneration else { return }
            self.publicIPState = .resolved(ipv4: ipv4, ipv6: ipv6)
            if let current = self.networkIdentity {
                self.networkIdentity = NetworkIdentity(
                    hostname: current.hostname,
                    interfaces: current.interfaces,
                    defaultRoute: current.defaultRoute,
                    dnsServers: current.dnsServers,
                    publicIPv4: ipv4,
                    publicIPv6: ipv6
                )
            }
        }
        publicIPTask = networkRefreshTask
    }

    /// 刷新端口占用列表（用户权限 lsof）；解析进程显示名；更新权限提示条。
    /// lsof / 进程名解析在后台执行，避免主线程阻塞冻结 popover。
    func refreshPorts() {
        isRefreshingPorts = true
        portsRefreshGeneration += 1
        let generation = portsRefreshGeneration
        portsRefreshTask?.cancel()
        portsRefreshTask = Task { [weak self] in
            guard let self else { return }

            let probe = self.portProbe
            let resolver = self.nameResolver
            let outcome: Result<([PortEntry], [pid_t: String]), Error> = await self.runBlocking {
                do {
                    let raw = try probe.probe()
                    var names: [pid_t: String] = [:]
                    for entry in raw {
                        if names[entry.pid] == nil {
                            names[entry.pid] = resolver.resolveDisplayName(
                                pid: entry.pid,
                                fallbackCommand: entry.command
                            )
                        }
                    }
                    return .success((raw, names))
                } catch {
                    return .failure(error)
                }
            }

            guard !Task.isCancelled, self.portsRefreshGeneration == generation else { return }
            switch outcome {
            case let .success((raw, names)):
                self.ports = raw
                self.processDisplayNames = names
                self.permissionHint = Self.computePermissionHint(from: raw)
            case .failure:
                self.ports = []
                self.processDisplayNames = [:]
                self.permissionHint = .loadFailure
            }
            self.isRefreshingPorts = false
        }
    }

    /// Hop off MainActor for blocking collectors, then resume on the service's actor.
    private func runBlocking<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            blockingRunner {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: Terminate / copy

    /// 结束进程；UI 确认框由 PortSegmentView 负责。
    @discardableResult
    func terminate(
        _ entry: PortEntry,
        signal: TerminationSignal = .term
    ) -> Result<TerminationOutcome, TerminationError> {
        terminator.terminate(
            pid: entry.pid,
            name: processDisplayName(for: entry),
            signal: signal
        )
    }

    /// 写入剪贴板（仅写不粘贴），复用取色器同款 PasteboardWriting。
    func copy(_ text: String) {
        writer.clearContents()
        writer.setString(text, forType: .string)
    }

    // MARK: Hint

    /// 端口在用但拿不到进程（pid≤0 或 COMMAND 空）→ 部分权限；空列表且非失败 → 无提示。
    static func computePermissionHint(from entries: [PortEntry]) -> PortPermissionHint {
        guard !entries.isEmpty else { return .none }
        let incomplete = entries.contains { entry in
            entry.pid <= 0
                || entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return incomplete ? .partialPermission : .none
    }
}
