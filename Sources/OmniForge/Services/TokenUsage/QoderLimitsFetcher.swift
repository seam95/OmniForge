import Foundation
import Network

// MARK: - 解析纯函数

/// qoder RPC `credit/usage` 归一化 — 纯函数（参考 normalizeQoderRpcUsage）。
enum QoderLimitsParsing {
    /// RPC 响应 → credits 窗口；缺 userQuota → nil。
    static func creditWindow(from response: [String: Any]?) -> (window: UsageWindow, planLabel: String?)? {
        guard let response, let quota = response["userQuota"] as? [String: Any] else {
            return nil
        }
        let used = number(quota["used"])
        let total = number(quota["total"])
        let remaining = number(quota["remaining"])
        guard let used, let total else { return nil }
        let reported = number(response["totalUsagePercentage"]) ?? number(quota["percentage"])
        let usedPercent: Double
        if total == 0 {
            usedPercent = 0
        } else if response["isQuotaExceeded"] as? Bool == true {
            usedPercent = 100
        } else if let reported {
            usedPercent = reported
        } else {
            usedPercent = used / total * 100
        }
        // Qoder 用 9999-12-31 作 Free 账户无过期哨兵 → 不显示重置时间。
        var resetAt: Date?
        if let expiryRaw = response["expiresAt"] as? String {
            let date = isoFractional.date(from: expiryRaw) ?? isoPlain.date(from: expiryRaw)
            if let date, date < Date(timeIntervalSince1970: 4_102_444_800) { // < 2100
                resetAt = date
            }
        }
        let window = UsageWindow(
            usedPercent: min(max(usedPercent, 0), 100),
            resetAt: resetAt,
            limit: total,
            used: used,
            remaining: remaining,
            unit: (quota["unit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "credits",
            windowSeconds: nil
        )
        let planLabel = (response["userType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (window, planLabel)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}

// MARK: - IPC 客户端（JSON-RPC over unix socket）

/// Qoder 本地服务的 JSON-RPC 客户端：`Content-Length` 帧 + Unix domain socket。
/// 协议参考 TokenTracker qoderRpcRequest；TokenTracker 私有协议（R5）——
/// 连接/响应异常一律 fail-soft 抛错，由 fetcher 走磁盘缓存兜底。
enum QoderRPCClient {
    static func request(
        method: String,
        socketPath: String,
        timeout: TimeInterval = 2
    ) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": [String: Any](),
        ])
        let header = "Content-Length: \(body.count)\r\n\r\n"

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            var buffer = Data()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if !resumed {
                    resumed = true
                    connection.cancel()
                    continuation.resume(throwing: LimitError.network("Qoder local service request timed out"))
                }
            }
            timer.resume()

            func finish(_ result: Result<[String: Any], Error>) {
                guard !resumed else { return }
                resumed = true
                timer.cancel()
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in })
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.receiveMessage { data, _, _, error in
                guard let data, error == nil else {
                    finish(.failure(error ?? LimitError.network("Qoder local service connection closed")))
                    return
                }
                buffer.append(data)
                parseFramed(buffer, finish: finish)
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    /// 累积缓冲 → 找 `Content-Length` 头 + 完整 body。
    private static func parseFramed(
        _ buffer: Data,
        finish: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return // 头未完整：继续收
        }
        let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .ascii) ?? ""
        guard let match = header.range(of: #"Content-Length:\s*(\d+)"#, options: .regularExpression),
              let digits = header[match].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              let bodyLength = Int(digits), bodyLength >= 0, bodyLength <= 4 * 1024 * 1024 else {
            finish(.failure(LimitError.decoding("Qoder local service returned an invalid response")))
            return
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count >= bodyStart + bodyLength else {
            return // body 未完整：继续收
        }
        let bodyData = buffer.subdata(in: bodyStart..<(bodyStart + bodyLength))
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            finish(.failure(LimitError.decoding("Qoder local service returned invalid JSON")))
            return
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            finish(.failure(LimitError.network(message)))
            return
        }
        finish(.success((json["result"] as? [String: Any]) ?? json))
    }
}

// MARK: - Fetcher

/// qoder 限额：本地 IPC（`SharedClientCache/.info.json` 的 `ipcServerPath`）JSON-RPC
/// `credit/usage` → credits 窗口；`auth/status` 补套餐名。失败 → 7 天磁盘缓存
/// （`~/.omniforge/qoder-limits-cache.json`）。
///
/// 说明（范围收敛）：activity 端点（big_model_credits 次要窗口）本期不接（R5：
/// TokenTracker 私有协议漂移风险）；RPC 主路径 + 缓存兜底已覆盖「今日/周/月」限额卡。
final class QoderLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .qoder

    static let cacheTTL: TimeInterval = 7 * 24 * 3600
    static let unknownResetTTL: TimeInterval = 12 * 3600
    static let cacheFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".omniforge/qoder-limits-cache.json")

    var rpcTimeout: TimeInterval = 2
    /// 测试注入：覆盖 `.info.json` 路径（默认 Qoder data root）。
    var infoJSONURLOverride: URL?
    /// 测试注入：RPC 请求实现（默认走 unix socket JSON-RPC）。
    var rpcRequest: (String, String, TimeInterval) async throws -> [String: Any] = QoderRPCClient.request
    /// 测试注入：覆盖磁盘缓存路径。
    var cacheFileURLOverride: URL?

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 1. IPC 端点：SharedClientCache/.info.json。
        guard let socketPath = ipcSocketPath() else {
            return cachedLimits() // 服务未运行 → last-good 缓存
        }
        // 2. 主路径：credit/usage。
        do {
            let usage = try await rpcRequest("credit/usage", socketPath, rpcTimeout)
            guard let (window, rpcPlanLabel) = QoderLimitsParsing.creditWindow(from: usage) else {
                return nil
            }
            var planLabel = rpcPlanLabel
            // 3. auth/status 补套餐名（失败不影响主窗口）。
            if planLabel == nil,
               let auth = try? await rpcRequest("auth/status", socketPath, rpcTimeout),
               let userType = (auth["userType"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                planLabel = userType
            }
            let limits = makeLimits(window: window, planLabel: planLabel, stale: false)
            writeCache(limits)
            return limits
        } catch {
            // 4. 失败 → 磁盘缓存兜底。
            if let cached = cachedLimits() {
                return cached
            }
            throw error
        }
    }

    // MARK: - IPC 端点

    private func ipcSocketPath() -> String? {
        let root = QoderUsageCollector.defaultDatabaseURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = infoJSONURLOverride ?? root.appendingPathComponent("SharedClientCache/.info.json")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let path = (info["ipcServerPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    // MARK: - 磁盘缓存

    private struct CachePayload: Codable {
        var planLabel: String?
        var cachedAt: Double
        var window: CachedWindow

        struct CachedWindow: Codable {
            var usedPercent: Double
            var limit: Double
            var used: Double
            var remaining: Double?
            var resetAt: Double?
            var unit: String
        }
    }

    private func makeLimits(window: UsageWindow, planLabel: String?, stale: Bool) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: planLabel,
            windows: [.credits: window],
            confidence: .official,
            capturedAt: Date(),
            stale: stale,
            issue: nil
        )
    }

    private var effectiveCacheURL: URL { cacheFileURLOverride ?? Self.cacheFileURL }

    private func writeCache(_ limits: ProviderUsageLimits) {
        guard let window = limits.windows[.credits] else { return }
        let payload = CachePayload(
            planLabel: limits.planLabel,
            cachedAt: Date().timeIntervalSince1970,
            window: CachePayload.CachedWindow(
                usedPercent: window.usedPercent,
                limit: window.limit ?? 0,
                used: window.used ?? 0,
                remaining: window.remaining,
                resetAt: window.resetAt?.timeIntervalSince1970,
                unit: window.unit ?? "credits"
            )
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? fileManager.createDirectory(
            at: effectiveCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: effectiveCacheURL, options: [.atomic])
    }

    private func cachedLimits() -> ProviderUsageLimits? {
        guard let data = try? Data(contentsOf: effectiveCacheURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return nil
        }
        let now = Date()
        let age = now.timeIntervalSince1970 - payload.cachedAt
        guard age >= 0, age < Self.cacheTTL else { return nil }
        let resetAt = payload.window.resetAt.map { Date(timeIntervalSince1970: $0) }
        if let resetAt, resetAt <= now { return nil }
        if payload.window.resetAt == nil, age > Self.unknownResetTTL { return nil }
        let window = UsageWindow(
            usedPercent: payload.window.usedPercent,
            resetAt: resetAt,
            limit: payload.window.limit,
            used: payload.window.used,
            remaining: payload.window.remaining,
            unit: payload.window.unit,
            windowSeconds: nil
        )
        return makeLimits(window: window, planLabel: payload.planLabel, stale: true)
    }
}