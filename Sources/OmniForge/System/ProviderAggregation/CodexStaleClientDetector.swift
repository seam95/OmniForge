import Foundation
import CryptoKit

/// Codex 陈旧客户端检测边界。
protocol CodexStaleClientDetecting: AnyObject {
    /// 记录一次目录代（写入客户端配置后调用）。
    func observe(catalogURL: URL, catalogIsOurs: Bool)
    /// 检测当前是否有客户端拿着旧目录。非我方目录 → nil（不检测）。
    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients?
}

/// Codex 陈旧客户端检测（目录代 + 进程启动时间）。
/// 客户端在启动时把模型目录读进内存；目录换代后再改成员，老客户端手里的还是旧目录。
/// 判定：进程启动时加载的目录代与当前不同 → 陈旧，提示重启。
/// 非 `final`：测试经子类覆写 `probeProcesses()` 注入伪 `ps` 输出（主类不持有 stub 属性）。
class CodexStaleClientDetector: CodexStaleClientDetecting {
    /// 历史上限（超出丢最旧）。
    static let historyLimit = 32
    /// 读取延迟余量：客户端可能在启动后一小会儿才读目录——启动时刻距代写入不足
    /// 该余量的代，按「启动后已读到」算，避免误判刚启动就赶上新代的客户端。
    static let marginMs: Int64 = 2_000

    private let historyURL: URL
    private let processRunner: () async -> String?
    private let fileManager: FileManager

    init(
        historyURL: URL,
        processRunner: @escaping () async -> String? = CodexStaleClientDetector.defaultProbe,
        fileManager: FileManager = .default
    ) {
        self.historyURL = historyURL
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    // MARK: - 进程探测

    /// 进程探测默认实现：`ps -ww -Ao pid=,etime=,command=`；失败/超时按空输出处理。
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
            fingerprint: catalogIsOurs ? Self.fingerprint(of: catalogURL) : "none"
        ))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        saveHistory(history)
    }

    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? {
        guard catalogIsOurs else { return nil }
        let history = (try? loadHistory()) ?? []
        // 没有任何目录代记录 → 无从比较，不提示。
        guard !history.isEmpty else { return CodexStaleClients(daemon: false, others: false) }
        let currentFingerprint = Self.fingerprint(of: catalogURL)
        let output = await probeProcesses() ?? ""
        var daemonStale = false
        var othersStale = false
        for entry in Self.parseProcesses(output) {
            guard entry.isAppServer else { continue }
            let stale = Self.isStale(entry: entry, history: history, currentFingerprint: currentFingerprint)
            if entry.isManagedDaemon {
                daemonStale = daemonStale || stale
            } else if !entry.isInternalSubcommand {
                othersStale = othersStale || stale
            }
        }
        return CodexStaleClients(daemon: daemonStale, others: othersStale)
    }

    // MARK: - 历史持久化

    /// 读取目录代历史；文件缺失或损坏 → 空（检测降级为「不提示」）。
    func loadHistory() throws -> [CodexCatalogGeneration] {
        guard fileManager.fileExists(atPath: historyURL.path),
              let data = try? Data(contentsOf: historyURL) else {
            return []
        }
        return (try? JSONDecoder().decode([CodexCatalogGeneration].self, from: data)) ?? []
    }

    private func saveHistory(_ history: [CodexCatalogGeneration]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(history) else { return }
        try? fileManager.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? AtomicFileWriter.write(data, to: historyURL, fileManager: fileManager)
    }

    // MARK: - private

    /// 进程是否陈旧：它启动时加载的目录代与当前不同。
    /// 启动时加载的代 = `sinceMs <= startedMs + marginMs` 的最新一代（余量见 `marginMs`）；
    /// 该代缺失（启动早于全部记录代 → 持有更旧的未知目录）或指纹与当前不同 → 陈旧。
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
        guard let data = try? Data(contentsOf: url) else { return "none" }
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
