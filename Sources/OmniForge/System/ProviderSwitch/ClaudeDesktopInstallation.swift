import Foundation

/// Claude Desktop 安装信息与 3P 能力诊断（SPEC 关键设计决策 8）。
/// 不设版本门槛（cc-switch 同口径）：只读版本号用于状态展示；
/// 「写入后 Desktop 未识别 3P」时用版本号给出升级提示。
struct ClaudeDesktopInstallation: Equatable {
    /// `CFBundleShortVersionString`（如 `3.6556.2`）；应用不存在 → nil。
    var version: String?
    /// 应用是否安装在标准位置。
    var isInstalled: Bool

    /// 是否可展示为「已安装」。
    var displayVersion: String? {
        guard isInstalled else { return nil }
        return version ?? "未知版本"
    }
}

/// 从磁盘读取 Claude Desktop 安装信息（纯函数，路径可注入）。
enum ClaudeDesktopInstallationReader {
    /// 标准安装路径：`/Applications/Claude.app`；另查用户级安装。
    static func candidateAppURLs(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true),
            URL(fileURLWithPath: homePath)
                .appendingPathComponent("Applications/Claude.app", isDirectory: true),
        ]
    }

    /// 读取安装信息；应用缺失 → `isInstalled: false`、`version: nil`。
    static func read(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> ClaudeDesktopInstallation {
        for appURL in candidateAppURLs(homePath: homePath) {
            let infoPlist = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
            guard fileManager.fileExists(atPath: infoPlist.path) else { continue }
            let version = (NSDictionary(contentsOf: infoPlist)?["CFBundleShortVersionString"] as? String)
            return ClaudeDesktopInstallation(version: version, isInstalled: true)
        }
        return ClaudeDesktopInstallation(version: nil, isInstalled: false)
    }
}

/// Desktop 3P 写入后「Desktop 是否真的认了」的诊断结果（决策 8：不设门槛，只提示）。
enum ClaudeDesktopSetupDiagnosis: Equatable {
    /// 一切正常：我们是 appliedId 且网关地址匹配。
    case active
    /// 写入成功但我们没生效（appliedId 被别的 profile 占用）→ 提示在 Desktop 内切换或重启。
    case notApplied
    /// 写入成功、appliedId 是我们，但 Desktop 版本过旧可能不识别 3P → 提示升级。
    case possiblyUnsupported(version: String?)
    /// Desktop 未安装 → 提示安装。
    case notInstalled

    /// 诊断一句话（供 UI/日志）。
    var summary: String {
        switch self {
        case .active:
            return "Claude Desktop 已在使用当前供应商配置"
        case .notApplied:
            return "配置已写入，但 Claude Desktop 尚未应用：请重启应用或在设置中切换配置"
        case .possiblyUnsupported(let version):
            let suffix = version.map { "（当前 \($0)）" } ?? ""
            return "配置已写入，但未在 Claude Desktop 中生效\(suffix)：请升级到最新版本后重启"
        case .notInstalled:
            return "未检测到 Claude Desktop：请先安装后再切换"
        }
    }
}

/// 诊断判定（纯函数，可单测）：结合安装信息与写入后的状态。
enum ClaudeDesktopSetupDiagnoser {
    /// - Parameters:
    ///   - state: 写入后的 4 文件状态。
    ///   - expectedBaseURL: 期望生效的网关地址（直连卡的 baseURL 或聚合代理的投影地址）。
    ///   - installation: 安装信息。
    static func diagnose(
        state: ClaudeDesktopState,
        expectedBaseURL: String,
        installation: ClaudeDesktopInstallation
    ) -> ClaudeDesktopSetupDiagnosis {
        guard installation.isInstalled else { return .notInstalled }
        guard state.isOurProfileApplied else { return .notApplied }
        guard state.inferenceGatewayBaseUrl == expectedBaseURL else {
            // appliedId 是我们但网关地址不是期望值：写入被外部改动，按未生效处理。
            return .notApplied
        }
        return .active
    }

    /// 「可能不支持 3P」判定：写入正确但仍未生效时，用版本号提示升级。
    /// 不设硬门槛（cc-switch 同口径），仅在有安装而无生效时归入该态。
    static func fallbackForUnapplied(
        installation: ClaudeDesktopInstallation
    ) -> ClaudeDesktopSetupDiagnosis {
        .possiblyUnsupported(version: installation.version)
    }
}
