import Foundation

/// 单条端口/连接占用记录（由 `lsof` 解析得到）。
struct PortEntry: Equatable, Identifiable {
    enum Proto: String, Equatable {
        case tcp
        case tcp6
        case udp
        case udp6

        /// 列表展示用：TCP / TCP6 / UDP / UDP6
        var displayName: String {
            switch self {
            case .tcp: return "TCP"
            case .tcp6: return "TCP6"
            case .udp: return "UDP"
            case .udp6: return "UDP6"
            }
        }

        var isTCP: Bool {
            self == .tcp || self == .tcp6
        }
    }

    let proto: Proto
    let localIP: String
    let localPort: Int
    let remoteIP: String?
    let remotePort: Int?
    /// TCP 状态（LISTEN / ESTABLISHED 等）；UDP 无状态为 nil。
    let state: String?
    let pid: pid_t
    /// lsof COMMAND 列（可能含 `\x20` 已还原的空格）。
    let command: String

    var id: String {
        "\(proto.rawValue)|\(localIP)|\(localPort)|\(remoteIP ?? "")|\(remotePort.map(String.init) ?? "")|\(state ?? "")|\(pid)|\(command)"
    }

    /// 列表/无障碍用端口文本：十进制原始数字，永不使用千分位。
    var localPortDisplay: String { String(localPort) }

    /// 复制用 `host:port`；IPv6 本地地址加方括号。
    var hostPortCopyText: String {
        let host: String
        if localIP.contains(":") && !localIP.hasPrefix("[") {
            host = "[\(localIP)]"
        } else {
            host = localIP
        }
        return "\(host):\(localPort)"
    }
}
