import Foundation

/// 聚合投影在客户端配置里的形态特征——写入端（两个 writer）与识别端
/// （`ProviderSwitchManager.detectActive`）共用的唯一事实源。
///
/// 识别端需要它：聚合投影把配置指向本机代理，`detectActive` 若只按
/// 「匹配不到 profile 即未托管」判定，会把代理地址锁进激活态缓存，
/// 退出聚合恢复文件后仍显示「未托管配置」横幅（2026-10-17 实测）。
enum AggregationProjectionSignature {
    /// 占位凭证字面量——代理按目标替换为真实凭证，客户端侧只见此值。
    static let placeholderToken = "PROXY_MANAGED"

    /// 回环主机集合：写入端固定写 `127.0.0.1`，收录其余形态防用户手改/历史残留误判。
    private static let loopbackHosts: Set<String> = [
        "127.0.0.1",
        "localhost",
        "::1",
        "[::1]",
        "0:0:0:0:0:0:0:1",
    ]

    /// 判定 base URL 是否为聚合代理投影（仅看主机，端口不限——端口按可用性分配）。
    static func isProjectedBaseURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else {
            return false
        }
        return loopbackHosts.contains(host)
    }

    /// Claude Desktop 的聚合投影形态：回环主机 + `/claude-desktop` 路径前缀。
    /// 写入端（Desktop 投影 writer）与识别端（`detectActive` 的 Desktop 分支）共用。
    static func isDesktopProjectedBaseURL(_ urlString: String) -> Bool {
        guard isProjectedBaseURL(urlString),
              let components = URLComponents(string: urlString) else {
            return false
        }
        return components.path.hasPrefix("/claude-desktop")
    }
}
