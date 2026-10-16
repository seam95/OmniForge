import Foundation
import CryptoKit

/// Codex 陈旧客户端检测边界。
protocol CodexStaleClientDetecting: AnyObject {
    /// 记录一次目录代（写入客户端配置后调用）。
    func observe(catalogURL: URL, catalogIsOurs: Bool)
    /// 记录一次登录代（登录身份可能变了之后调用：收纳/还原前后、退出聚合后）。
    func observeLogin(authURL: URL)
    /// 用户关掉陈旧横幅：记下当前目录与登录指纹，同一份不再提示，再变才提示。
    func acknowledge(catalogURL: URL, authURL: URL)
    /// 检测当前是否有客户端拿着旧目录。非我方目录 → nil（不检测）。
    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients?
}

/// Codex 陈旧客户端检测（目录代 + 登录代 + 进程启动时间）。
/// 客户端在启动时把模型目录和登录身份读进内存；换代后再改成员/切号，老客户端手里的还是旧的。
/// 判定：进程启动时加载的代与当前不同 → 陈旧，提示重启。
/// 非 `final`：测试经子类覆写 `probeProcesses()` 注入伪 `ps` 输出（主类不持有 stub 属性）。
class CodexStaleClientDetector: CodexStaleClientDetecting {
    /// 历史上限（超出丢最旧）。
    static let historyLimit = 32
    /// 读取延迟余量：客户端可能在启动后一小会儿才读目录——启动时刻距代写入不足
    /// 该余量的代，按「启动后已读到」算，避免误判刚启动就赶上新代的客户端。
    static let marginMs: Int64 = 2_000

    /// 目录代历史文件名（对齐 cc-switch `codex_client_catalog.rs:36`）。
    static let historyFileName = "codex-catalog-history.json"
    /// 登录代历史文件名（对齐 cc-switch `:37`）。
    static let loginHistoryFileName = "codex-login-history.json"
    /// 用户确认记录文件名（对齐 cc-switch `:39`）。
    static let ackFileName = "codex-client-ack.json"

    private let historyURL: URL
    private let loginHistoryURL: URL
    private let ackURL: URL
    private let processRunner: () async -> String?
    private let fileManager: FileManager

    init(
        historyURL: URL,
        loginHistoryURL: URL? = nil,
        ackURL: URL? = nil,
        processRunner: @escaping () async -> String? = CodexStaleClientDetector.defaultProbe,
        fileManager: FileManager = .default
    ) {
        self.historyURL = historyURL
        // 缺省与目录代历史同目录（生产装配在 `<AggregationRoot>` 下显式给全三个路径）。
        let directory = historyURL.deletingLastPathComponent()
        self.loginHistoryURL = loginHistoryURL
            ?? directory.appendingPathComponent(Self.loginHistoryFileName)
        self.ackURL = ackURL ?? directory.appendingPathComponent(Self.ackFileName)
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    // MARK: - 进程探测

    /// 进程探测默认实现：`ps -ww -Ao pid=,etime=,command=`；失败/超时 → nil（进程表不可得）。
    static func defaultProbe() async -> String? {
        do {
            let output = try await BoundedProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-ww", "-Ao", "pid=,etime=,command="]
            )
            return output.stdout
        } catch {
            return nil
        }
    }

    /// 进程探测入口（子类覆写注入伪输出；生产走 `defaultProbe`）。
    func probeProcesses() async -> String? {
        await processRunner()
    }

    // MARK: - 观测与检测

    func observe(catalogURL: URL, catalogIsOurs: Bool) {
        var history = (try? loadHistory()) ?? []
        history.append(CodexCatalogGeneration(
            sinceMs: Self.nowMs(),
            fingerprint: catalogIsOurs ? Self.fingerprint(of: catalogURL) : CodexFingerprint.missing
        ))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        saveHistory(history)
    }

    /// 记录一次登录代：指纹 = auth.json 字节（缺失 → `"none"`）。指纹没变不记新代
    /// （对齐 cc-switch `record_history`：否则「从没变过」会被误判成切换过，早于首次
    /// 观察的进程会被报陈旧）。
    func observeLogin(authURL: URL) {
        var history = (try? loadLoginHistory()) ?? []
        let fingerprint = Self.fingerprint(of: authURL)
        guard history.last?.fingerprint != fingerprint else { return }
        history.append(CodexCatalogGeneration(sinceMs: Self.nowMs(), fingerprint: fingerprint))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        saveLoginHistory(history)
    }

    /// 用户关掉陈旧横幅：把当前目录与登录指纹记成「已确认」，之后同一份不再提示。
    func acknowledge(catalogURL: URL, authURL: URL) {
        saveAck(CodexStaleClientAck(
            catalog: Self.fingerprint(of: catalogURL),
            login: Self.fingerprint(of: authURL)
        ))
    }

    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? {
        guard catalogIsOurs else { return nil }
        let catalogHistory = (try? loadHistory()) ?? []
        // 没有任何目录代记录 → 无从比较，不提示。
        guard !catalogHistory.isEmpty else {
            return CodexStaleClients(daemon: false, others: false)
        }
        let authURL = Self.authURL(forCatalogURL: catalogURL)
        let currentCatalog = Self.fingerprint(of: catalogURL)
        let currentLogin = Self.fingerprint(of: authURL)
        let loginHistory = (try? loadLoginHistory()) ?? []
        let ack = try? loadAck()
        // 进程表读不出来 → 降级：不知道有没有客户端开着（cc-switch 的 Windows 同款）。
        let table = await probeProcesses()
        var daemonStale = false
        var othersStale = false
        var loginChanged = false
        if let table {
            for entry in Self.parseProcesses(table) {
                guard entry.isAppServer else { continue }
                let stale = Self.isStale(
                    entry: entry, history: catalogHistory, currentFingerprint: currentCatalog
                )
                // 登录代次：至少记录过一次切换才判（首次观察不是切号，对齐 cc-switch `:366`）。
                let loginStale = loginHistory.count > 1 && Self.isStale(
                    entry: entry, history: loginHistory, currentFingerprint: currentLogin
                )
                if entry.isManagedDaemon {
                    daemonStale = daemonStale || stale
                } else if !entry.isInternalSubcommand {
                    othersStale = othersStale || stale
                }
                loginChanged = loginChanged || loginStale
            }
            // 判陈旧前比对 ack：用户确认过且指纹没再变 → 不报（关闭横幅的语义）。
            if let ack {
                if ack.catalog == currentCatalog {
                    daemonStale = false
                    othersStale = false
                }
                if ack.login == currentLogin {
                    loginChanged = false
                }
            }
        } else if let ack, ack.catalog != currentCatalog || ack.login != currentLogin {
            // 没有进程表：`others` 只表示「用户上次确认后目录或登录变了」，不知是否开着。
            // 从没确认过 → 把现在这份当基准，不猜（对齐 cc-switch `:380-397`）。
            othersStale = true
            loginChanged = ack.login != currentLogin
        }
        return CodexStaleClients(
            daemon: daemonStale,
            others: othersStale,
            loginChanged: loginChanged,
            unverified: table == nil
        )
    }

    // MARK: - 历史持久化

    /// 读取目录代历史；文件缺失或损坏 → 空（检测降级为「不提示」）。
    func loadHistory() throws -> [CodexCatalogGeneration] {
        try loadGenerations(at: historyURL)
    }

    /// 读取登录代历史；文件缺失或损坏 → 空（登录不判陈旧）。
    func loadLoginHistory() throws -> [CodexCatalogGeneration] {
        try loadGenerations(at: loginHistoryURL)
    }

    /// 读取用户确认记录；文件缺失或损坏 → nil（没确认过 → 不抑制）。
    func loadAck() throws -> CodexStaleClientAck? {
        guard fileManager.fileExists(atPath: ackURL.path),
              let data = try? Data(contentsOf: ackURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexStaleClientAck.self, from: data)
    }

    private func loadGenerations(at url: URL) throws -> [CodexCatalogGeneration] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([CodexCatalogGeneration].self, from: data)) ?? []
    }

    private func saveHistory(_ history: [CodexCatalogGeneration]) {
        saveGenerations(history, to: historyURL)
    }

    private func saveLoginHistory(_ history: [CodexCatalogGeneration]) {
        saveGenerations(history, to: loginHistoryURL)
    }

    private func saveGenerations(_ history: [CodexCatalogGeneration], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(history) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? AtomicFileWriter.write(data, to: url, fileManager: fileManager)
    }

    private func saveAck(_ ack: CodexStaleClientAck) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ack) else { return }
        try? fileManager.createDirectory(
            at: ackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? AtomicFileWriter.write(data, to: ackURL, fileManager: fileManager)
    }

    // MARK: - private

    /// 登录身份文件与目录同住 Codex home（对齐 cc-switch：`get_codex_auth_path()` 与
    /// `get_codex_model_catalog_path()` 同源于配置目录）。
    static func authURL(forCatalogURL catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent()
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    /// 进程是否陈旧：它启动时加载的代与当前不同。
    /// 启动时加载的代 = `sinceMs <= startedMs + marginMs` 的最新一代（余量见 `marginMs`）；
    /// 该代缺失（启动早于全部记录代 → 持有更旧的未知内容）或指纹与当前不同 → 陈旧。
    private static func isStale(
        entry: PsEntry,
        history: [CodexCatalogGeneration],
        currentFingerprint: String
    ) -> Bool {
        let loadedAt = entry.startedMs + marginMs
        guard let loaded = history.last(where: { $0.sinceMs <= loadedAt }) else { return true }
        return loaded.fingerprint != currentFingerprint
    }

    /// `ps` 行解析（`pid=,etime=,command=` 形态：行首两列后整行是命令）。
    private static func parseProcesses(_ output: String) -> [PsEntry] {
        var entries: [PsEntry] = []
        let now = Self.nowMs()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let elapsed = elapsedSeconds(String(parts[1])) else {
                continue
            }
            entries.append(PsEntry(
                pid: String(parts[0]),
                startedMs: now - elapsed * 1_000,
                command: parts[2...].map(String.init).joined(separator: " ")
            ))
        }
        return entries
    }

    /// etime 解析（`[[dd-]hh:]mm:ss`）→ 秒。
    private static func elapsedSeconds(_ etime: String) -> Int64? {
        var rest = etime
        var days: Int64 = 0
        if let dash = rest.firstIndex(of: "-") {
            days = Int64(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds: Int64 = 0
        for part in parts {
            guard let value = Int64(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    /// 目录字节的 SHA256 十六进制；文件缺失/不可读 → `"none"`。
    static func fingerprint(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return CodexFingerprint.missing }
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

/// 一条 `ps` 记录的结构化形态。
private struct PsEntry {
    let pid: String
    let startedMs: Int64
    let command: String

    var isAppServer: Bool { command.contains("app-server") }

    /// 托管守护进程：app-server 且带 `--managed-daemon`（该参数是权威标记；
    /// `daemon.pid` 文件只作佐证，不作为必要条件——避免为主类引入 Codex home I/O）。
    var isManagedDaemon: Bool { isAppServer && command.contains("--managed-daemon") }

    /// Codex 内部子命令（插件/守护/代理形态）——不算面向用户的客户端，不进 others。
    var isInternalSubcommand: Bool {
        command.contains("/plugins/")
            || command.contains("app-server daemon")
            || command.contains("app-server proxy")
    }
}
