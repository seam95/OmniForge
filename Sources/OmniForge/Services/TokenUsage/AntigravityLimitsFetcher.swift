import Foundation

// MARK: - 响应解码（纯函数，独立可测 — 参考 B normalizeAntigravityQuotaSummary / normalizeAntigravityResponse）

/// Antigravity 配额响应解码。
///
/// 三级来源（对齐 B fetchAntigravityLimits）：
/// ① `RetrieveUserQuotaSummary`：按 bucketId 映射四窗（3p-weekly→Cl 7d、3p-5h→Cl 5h、
///    gemini-weekly→Gm 7d、gemini-5h→Gm 5h）；
/// ② `GetUserStatus`：cascadeModelConfigData.clientModelConfigs 按模型族分组，
///    claude 族最低/最高剩余 → Cl 7d/Cl 5h，gemini 族 → Gm 7d/Gm 5h；
/// ③ `GetCommandModelConfigs`：同 ② 的形状（fallbackToConfigs）。
enum AntigravityUsageDecoder {
    /// bucketId → 窗口语义（对齐 B normalizeAntigravityQuotaSummary 的四窗顺序）。
    static let bucketWindows: [(bucketId: String, label: String)] = [
        ("3p-weekly", "Cl 7d"),
        ("3p-5h", "Cl 5h"),
        ("gemini-weekly", "Gm 7d"),
        ("gemini-5h", "Gm 5h"),
    ]

    // MARK: 来源① quota summary

    /// quota summary 解码：groups[].buckets[] 按 bucketId 平铺取四窗；
    /// 无已知 bucketId 命中 → nil（调用方降级 GetUserStatus，绝不渲染空卡）。
    static func decodeQuotaSummary(_ body: [String: Any]) -> [LabeledUsageWindow]? {
        guard antigravityCodeIsOk(body["code"]) else { return nil }
        let groups = (body["response"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        var buckets: [String: [String: Any]] = [:]
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                if let id = bucket["bucketId"] as? String {
                    buckets[id] = bucket
                }
            }
        }
        var labeled: [LabeledUsageWindow] = []
        for (bucketId, label) in bucketWindows {
            if let bucket = buckets[bucketId], let window = windowFromRemaining(bucket) {
                labeled.append(LabeledUsageWindow(label: label, window: window))
            }
        }
        return labeled.isEmpty ? nil : labeled
    }

    // MARK: 来源②/③ user status / model configs

    /// userStatus / clientModelConfigs 解码：模型族分组取最忙/最闲。
    static func decodeModelConfigBody(_ body: [String: Any], fallbackToConfigs: Bool = false) -> AntigravityAccountAndWindows? {
        guard antigravityCodeIsOk(body["code"]) else { return nil }
        let userStatus = body["userStatus"] as? [String: Any]
        let configs = fallbackToConfigs
            ? (body["clientModelConfigs"] as? [[String: Any]])
            : ((userStatus?["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]])
        let allModels = parseModelConfigs(configs)
        guard !allModels.isEmpty else { return nil }

        // 只保留聊天模型（剔除 autocomplete/lite/tab_），全被剔则回退全集。
        let chatModels = allModels.filter { priority($0) != nil }
        let models = chatModels.isEmpty ? allModels : chatModels

        let claudeModels = models.filter { family($0) == .claude }
        let geminiModels = models.filter { family($0) == .geminiPro || family($0) == .geminiFlash }

        var labeled: [LabeledUsageWindow] = []
        if !claudeModels.isEmpty {
            if let window = makeWindow(pickMin(claudeModels)) {
                labeled.append(LabeledUsageWindow(label: "Cl 7d", window: window))
            }
            if let window = makeWindow(pickMax(claudeModels)) {
                labeled.append(LabeledUsageWindow(label: "Cl 5h", window: window))
            }
        }
        if !geminiModels.isEmpty {
            if let window = makeWindow(pickMin(geminiModels)) {
                labeled.append(LabeledUsageWindow(label: "Gm 7d", window: window))
            }
            if let window = makeWindow(pickMax(geminiModels)) {
                labeled.append(LabeledUsageWindow(label: "Gm 5h", window: window))
            }
        } else if claudeModels.isEmpty, let only = models.first, let window = makeWindow(only) {
            // 无任何可识别族 → 单窗兜底（对齐 B tertiary 回退 pickMin(models)）。
            labeled.append(LabeledUsageWindow(label: "Cl 7d", window: window))
        }
        guard !labeled.isEmpty else { return nil }

        return AntigravityAccountAndWindows(
            email: userStatus?["email"] as? String,
            planLabel: planLabel(from: userStatus),
            windows: labeled
        )
    }

    /// 显示套餐（planDisplayName 链回退；free/none/unknown → nil，剥前导品牌词）。
    /// 入参为 `userStatus` 字典本身。
    static func planLabel(from userStatus: [String: Any]?) -> String? {
        guard let planInfo = (userStatus?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any] else {
            return nil
        }
        let candidates: [Any?] = [
            planInfo["planDisplayName"],
            planInfo["displayName"],
            planInfo["productName"],
            planInfo["planName"],
            planInfo["planShortName"],
        ]
        guard let raw = candidates.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        let normalized = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "free", "none", "unknown", "": return nil
        case "antigravity": return nil
        default:
            // 剥前导品牌词（如 "Antigravity Pro" → "Pro"）。
            if normalized.lowercased().hasPrefix("antigravity ") {
                let rest = normalized.dropFirst("antigravity ".count).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
            return normalized
        }
    }

    // MARK: 模型条目

    struct ModelEntry {
        var label: String
        var modelID: String
        var remainingFraction: Double?
        var resetAt: Date?
    }

    enum ModelFamily {
        case claude
        case geminiPro
        case geminiFlash
        case unknown
    }

    static func parseModelConfigs(_ configs: [[String: Any]]?) -> [ModelEntry] {
        guard let configs else { return [] }
        return configs.compactMap { config in
            guard let quota = config["quotaInfo"] as? [String: Any] else { return nil }
            return ModelEntry(
                label: config["label"] as? String ?? "",
                modelID: (config["modelOrAlias"] as? [String: Any])?["model"] as? String ?? "",
                remainingFraction: numeric(quota["remainingFraction"]),
                resetAt: parseDate(quota["resetTime"])
            )
        }
    }

    /// 模型族判定（label + modelId 小写包含；对齐 B antigravityFamily）。
    static func family(_ model: ModelEntry) -> ModelFamily {
        let text = "\(model.label) \(model.modelID)".lowercased()
        if text.contains("claude") { return .claude }
        if text.contains("gemini") && text.contains("pro") { return .geminiPro }
        if text.contains("gemini") && text.contains("flash") { return .geminiFlash }
        return .unknown
    }

    /// 聊天模型优先级（nil = 剔除）：lite / autocomplete / tab_ 非聊天。
    static func priority(_ model: ModelEntry) -> Int? {
        let text = "\(model.label) \(model.modelID)".lowercased()
        if text.contains("lite") || text.contains("autocomplete") || text.contains("tab_") { return nil }
        return 0
    }

    static func pickMin(_ models: [ModelEntry]) -> ModelEntry? {
        let sorted = models.filter { $0.remainingFraction != nil }.sorted { $0.remainingFraction! < $1.remainingFraction! }
        return sorted.first ?? models.first
    }

    static func pickMax(_ models: [ModelEntry]) -> ModelEntry? {
        let sorted = models.filter { $0.remainingFraction != nil }.sorted { $0.remainingFraction! > $1.remainingFraction! }
        return sorted.first ?? models.last
    }

    static func makeWindow(_ model: ModelEntry?) -> UsageWindow? {
        guard let model else { return nil }
        let remaining = (model.remainingFraction ?? 0) * 100
        return UsageWindow(
            usedPercent: min(max(100 - remaining, 0), 100),
            resetAt: model.resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: nil
        )
    }

    /// bucket 条目 → 窗口（usedPercent = 100 − remainingFraction×100）。
    private static func windowFromRemaining(_ bucket: [String: Any]) -> UsageWindow? {
        guard let fraction = numeric(bucket["remainingFraction"]) else { return nil }
        return UsageWindow(
            usedPercent: min(max(100 - fraction * 100, 0), 100),
            resetAt: parseDate(bucket["resetTime"]),
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: nil
        )
    }

    // MARK: 工具

    /// code 字段可用性（缺失视为 ok；数字 0 或字符串 ok/success/0 通过 — 对齐 B antigravityCodeIsOk）。
    static func antigravityCodeIsOk(_ code: Any?) -> Bool {
        if code == nil { return true }
        if let number = code as? NSNumber { return number.intValue == 0 }
        if let string = code as? String {
            switch string.lowercased() {
            case "ok", "success", "0": return true
            default: return false
            }
        }
        return false
    }

    /// resetTime 数字按 unix 秒、字符串按 ISO 或数字串（对齐 B parseAntigravityDate）。
    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return number.doubleValue > 0 ? Date(timeIntervalSince1970: number.doubleValue) : nil
        }
        if let string = value as? String, !string.isEmpty {
            if let double = Double(string), double > 0 {
                return Date(timeIntervalSince1970: double)
            }
            if let fractional = isoFractional.date(from: string) { return fractional }
            return isoPlain.date(from: string)
        }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func numeric(_ value: Any?) -> Double? {
        UsageWindowParsing.numeric(value)
    }
}

/// decodeModelConfigBody 的组合结果。
struct AntigravityAccountAndWindows: Equatable {
    var email: String?
    var planLabel: String?
    var windows: [LabeledUsageWindow]
}

// MARK: - 进程探测（参考 B isAntigravityCommandLine / detectAntigravityProcess）

enum AntigravityProcessProbe {
    /// ps 行解析结果。
    struct ProcessInfo {
        var pid: Int
        var commandLine: String
    }

    struct Match {
        var pid: Int
        var csrfToken: String?
        var extensionPort: Int?
    }

    /// 命令行匹配：可执行名 agy；或 language_server* 且带 antigravity 标记
    /// （--app_data_dir…antigravity、/antigravity/、\antigravity\、--override_ide_name antigravity）。
    static func matches(_ commandLine: String) -> Bool {
        let raw = commandLine
        let lower = raw.lowercased()
        let executable = firstCommandToken(raw).split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""

        // agy CLI 二进制本身以 server 运行（basename 匹配，绝对路径不误判）。
        if executable == "agy" || executable == "agy.exe" { return true }

        // IDE language_server：必须伴随 antigravity 特征标记，避免误认 Windsurf 等兄弟产品。
        let hasLangServerBinary = executable == "language_server"
            || (executable.hasPrefix("language_server_") && executable.hasSuffix(".exe") == false)
            || executable.range(of: "^language_server(?:_[a-z0-9]+)*(?:\\.exe)?$", options: .regularExpression) != nil
        let hasMarker =
            (lower.contains("--app_data_dir") && lower.contains("antigravity")) ||
            lower.contains("/antigravity/") ||
            lower.contains("/antigravity.app/") ||
            lower.contains("\\antigravity\\") ||
            raw.range(of: "--override_ide_name(?:=|\\s+[\"']?)antigravity\\b", options: [.regularExpression, .caseInsensitive]) != nil

        return hasLangServerBinary && hasMarker
    }

    /// 从命令行提取 flag 值（`--flag value` / `--flag=value`）。
    static func extractFlag(_ commandLine: String, _ flag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)", options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(commandLine.startIndex..., in: commandLine)
        guard let match = regex.firstMatch(in: commandLine, range: range),
              let capture = Range(match.range(at: 1), in: commandLine) else {
            return nil
        }
        return String(commandLine[capture])
    }

    /// ps 输出首条匹配 → Match（pid + csrf_token + extension_server_port）。
    static func firstMatch(in output: String) -> Match? {
        for line in output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let pid = parsePID(String(trimmed)) else { continue }
            let command = commandAfterPID(String(trimmed))
            guard matches(command) else { continue }
            let extensionPort = extractFlag(command, "--extension_server_port").flatMap { Int($0) }
            return Match(
                pid: pid,
                csrfToken: extractFlag(command, "--csrf_token"),
                extensionPort: extensionPort.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return nil
    }

    /// ps `-o pid=,command=` 行：前导数字为 pid，其余为命令行。
    private static func parsePID(_ line: String) -> Int? {
        let token = line.prefix(while: { !$0.isWhitespace })
        return Int(token)
    }

    private static func commandAfterPID(_ line: String) -> String {
        guard let idx = line.firstIndex(where: \.isWhitespace) else { return "" }
        return String(line[line.index(after: idx)...])
    }

    private static func firstCommandToken(_ commandLine: String) -> String {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}

// MARK: - 取数器

/// Antigravity 限额取数器：ps 找进程 → lsof 找端口 → 本地 Connect-RPC 三级降级（参考 08/fetchAntigravityLimits）。
///
/// 状态归一：进程不在 → 靠缓存层磁盘 last-good 兜底后报「未运行」错误态；
/// 无安装证据（~/.gemini/{antigravity,antigravity-ide,antigravity-cli} 均缺）→ 未配置（nil）。
final class AntigravityLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .antigravity

    private let processRunner: (String, [String], TimeInterval) async throws -> String
    private let client: AntigravityLocalJSONPosting
    private let homeDirectory: () -> String
    /// 安装证据探测：`~/.gemini` 下候选目录名 → 是否存在目录。
    private let installEvidence: (String) -> Bool

    init(
        processRunner: @escaping (String, [String], TimeInterval) async throws -> String = AntigravityShell.run,
        client: AntigravityLocalJSONPosting = AntigravityLocalAPIClient(),
        homeDirectory: @escaping () -> String = { NSHomeDirectory() },
        installEvidence: @escaping (String) -> Bool = AntigravityLimitsFetcher.defaultInstallEvidence
    ) {
        self.processRunner = processRunner
        self.client = client
        self.homeDirectory = homeDirectory
        self.installEvidence = installEvidence
    }

    /// 生产实现：`~/.gemini/{antigravity,antigravity-ide,antigravity-cli}` 任一目录存在。
    static func defaultInstallEvidence(_ geminiHomePath: String) -> Bool {
        let names = ["antigravity", "antigravity-ide", "antigravity-cli"]
        return names.contains { name in
            let path = geminiHomePath + "/" + name
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // ① 进程探测：无匹配进程 → 安装证据决定「未配置」或「未运行」。
        let psOutput: String
        do {
            psOutput = try await processRunner("/bin/ps", ["-ax", "-o", "pid=,command="], 4)
        } catch {
            throw LimitError.network("ps failed: \(error.localizedDescription)")
        }
        guard let match = AntigravityProcessProbe.firstMatch(in: psOutput) else {
            if !hasInstallEvidence() {
                return nil
            }
            return errorLimits()
        }

        // ② 端口发现：lsof 列监听端口。
        let lsofOutput: String
        do {
            lsofOutput = try await processRunner("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(match.pid)], 4)
        } catch {
            throw LimitError.network("lsof failed: \(error.localizedDescription)")
        }
        let ports = Self.parseListeningPorts(lsofOutput)
        guard !ports.isEmpty else {
            return errorLimits()
        }

        // ③ 端口探测：https 优先；无 CSRF 时再试 http（agy CLI 双协议、免 CSRF）。
        var working: (port: Int, scheme: String)?
        for port in ports {
            if await client.probePort(scheme: "https", port: port, csrfToken: match.csrfToken) {
                working = (port, "https")
                break
            }
            if match.csrfToken == nil || match.csrfToken?.isEmpty == true {
                if await client.probePort(scheme: "http", port: port, csrfToken: nil) {
                    working = (port, "http")
                    break
                }
            }
        }
        guard let endpoint = working else {
            throw LimitError.network("no working API port found")
        }

        // ④ 三级降级取数。
        if let summary = try? await client.postJSON(
            scheme: endpoint.scheme,
            port: endpoint.port,
            path: AntigravityLocalAPIClient.servicePath + "RetrieveUserQuotaSummary",
            body: AntigravityRequestBodies.defaultBody,
            csrfToken: match.csrfToken
        ), let labeled = AntigravityUsageDecoder.decodeQuotaSummary(summary) {
            return providerLimits(labeled: labeled, email: nil, planLabel: nil)
        }

        if let status = try? await client.postJSON(
            scheme: endpoint.scheme,
            port: endpoint.port,
            path: AntigravityLocalAPIClient.servicePath + "GetUserStatus",
            body: AntigravityRequestBodies.defaultBody,
            csrfToken: match.csrfToken
        ), let result = AntigravityUsageDecoder.decodeModelConfigBody(status) {
            return providerLimits(labeled: result.windows, email: result.email, planLabel: result.planLabel)
        }

        // ⑤ GetCommandModelConfigs：优先 extensionPort，scheme 翻转规则同 B。
        let fallbackPort = (match.extensionPort.flatMap { $0 > 0 ? $0 : nil }) ?? endpoint.port
        let fallbackScheme: String = (!isCSRFPresent(match) && fallbackPort == endpoint.port)
            ? (endpoint.scheme == "https" ? "http" : "https")
            : (fallbackPort == endpoint.port ? "https" : "http")
        if let configs = try? await client.postJSON(
            scheme: fallbackScheme,
            port: fallbackPort,
            path: AntigravityLocalAPIClient.servicePath + "GetCommandModelConfigs",
            body: AntigravityRequestBodies.defaultBody,
            csrfToken: match.csrfToken
        ), let result = AntigravityUsageDecoder.decodeModelConfigBody(configs, fallbackToConfigs: true) {
            return providerLimits(labeled: result.windows, email: result.email, planLabel: result.planLabel)
        }

        throw LimitError.decoding("Antigravity quota unavailable from all sources")
    }

    // MARK: 内部

    private func isCSRFPresent(_ match: AntigravityProcessProbe.Match) -> Bool {
        !(match.csrfToken ?? "").isEmpty
    }

    private func hasInstallEvidence() -> Bool {
        installEvidence(homeDirectory() + "/.gemini")
    }

    /// 进程不在/端口不可用 → 错误快照（缓存层的 last-good 已先行兜底展示）。
    private func errorLimits() -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: .antigravity,
            configured: true,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: [:],
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: .network("not running")
        )
    }

    /// 标签窗口组装：Cl 5h→session 槽、Cl 7d→weekly 槽（菜单栏会话窗口径可用），
    /// 其余保持带标签输出（providerLimits 内完成映射）。
    private func providerLimits(
        labeled: [LabeledUsageWindow],
        email: String?,
        planLabel: String?
    ) -> ProviderUsageLimits {
        // 槽位映射：Cl 5h → session（菜单栏会话窗 %）、Cl 7d → weekly；Gm 双窗保持带标签。
        var windows: [LimitWindowKind: UsageWindow] = [:]
        var remainingLabeled: [LabeledUsageWindow] = []
        for entry in labeled {
            switch entry.label {
            case "Cl 5h":
                windows[.session] = entry.window
            case "Cl 7d":
                windows[.weekly] = entry.window
            default:
                remainingLabeled.append(entry)
            }
        }
        return ProviderUsageLimits(
            provider: .antigravity,
            configured: true,
            subscriptionStatus: planLabel != nil ? .active : .unknown,
            planLabel: planLabel,
            windows: windows,
            labeledWindows: remainingLabeled.isEmpty ? nil : remainingLabeled,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }

    /// lsof 输出解析监听端口（去重升序；对齐 B parseListeningPorts）。
    static func parseListeningPorts(_ output: String) -> [Int] {
        var seen = Set<Int>()
        for line in output.split(separator: "\n") where line.contains("LISTEN") {
            // 形如 `agyd 50001 seam 12u IPv4 0x... 0t0 TCP *:8080 (LISTEN)`；地址列取最后一个 *:port。
            let tokens = line.split(separator: " ").map(String.init)
            guard let addressIndex = tokens.lastIndex(where: { $0.contains("*:") || $0.contains("]:") }) else { continue }
            let address = tokens[addressIndex]
            let portString = address.split(separator: ":").last.map(String.init) ?? ""
            if let port = Int(portString.trimmingCharacters(in: CharacterSet(charactersIn: "]"))) {
                seen.insert(port)
            }
        }
        return seen.sorted()
    }
}

/// shell 执行适配（ps / lsof；超时由 Process 外部控制简化为直接等待）。
enum AntigravityShell {
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
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
                    continuation.resume(throwing: LimitError.network("\(launchPath) exited \(process.terminationStatus)"))
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
