import Foundation

/// Claude Desktop 聚合的网关 token — Desktop profile 持它访问本地代理
/// `/claude-desktop/*`，代理据此鉴权（不匹配一律 401，SPEC 功能 C）。
/// 独立文件持久化（0600，不入 UserDefaults，SPEC 决策 7）；缺失时生成并落盘。
final class DesktopGatewayTokenStore {
    /// token 前缀（对齐 cc-switch `ccs-` 形态）。
    static let tokenPrefix = "ccs-"

    private let tokenURL: URL
    private let fileManager: FileManager

    init(tokenURL: URL, fileManager: FileManager = .default) {
        self.tokenURL = tokenURL
        self.fileManager = fileManager
    }

    /// 生产装配。
    static func production(applicationSupportRoot: URL, fileManager: FileManager = .default) -> DesktopGatewayTokenStore {
        DesktopGatewayTokenStore(
            tokenURL: ProviderSwitchPaths.desktopGatewayTokenURL(applicationSupportRoot: applicationSupportRoot),
            fileManager: fileManager
        )
    }

    /// 读取既有 token；文件缺失/空白时生成新 token 并落盘（幂等：已存在原样返回）。
    func loadOrCreate() throws -> String {
        if let existing = try? load(), !existing.isEmpty {
            return existing
        }
        let token = Self.tokenPrefix + UUID().uuidString.lowercased()
        try fileManager.createDirectory(
            at: tokenURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.write(Data(token.utf8), to: tokenURL, fileManager: fileManager)
        return token
    }

    /// 只读（不生成）；文件缺失/空白 → nil。
    func load() throws -> String? {
        guard fileManager.fileExists(atPath: tokenURL.path),
              let data = try? Data(contentsOf: tokenURL),
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
