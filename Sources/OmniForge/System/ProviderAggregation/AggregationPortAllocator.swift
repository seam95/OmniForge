import Foundation
import Network

/// 聚合代理端口分配 — 默认 15721，占用则向上顺延（对齐 cc-switch 行为，
/// 同时避免与 cc-switch 抢占——两个 App 同装时后起者让位）。
/// **实际端口持久化**：顺延后的端口必须记住，否则重启后顺延结果漂移、
/// 客户端配置里的地址失效。
enum AggregationPortAllocator {
    static let preferredPort: UInt16 = 15721
    static let maxAttempts = 10
    static let portDefaultsKey = "providerAggregation.port"

    /// 端口是否可绑定（试绑即放）。
    static func isAvailable(_ port: UInt16) -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: endpoint)
        } catch {
            return false
        }
        let stateChanged = DispatchSemaphore(value: 0)
        var available = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                available = true
                stateChanged.signal()
            case .failed:
                available = false
                stateChanged.signal()
            case .cancelled:
                stateChanged.signal()
            default:
                break
            }
        }
        // 探测期间若有连接进来立即关掉——只借端口探活，不承接流量。
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        _ = stateChanged.wait(timeout: .now() + 2)
        if available {
            // cancel 是异步的：等 .cancelled 落地再返回。否则端口尚未释放，
            // 紧接着的 resolve/真实绑定会把它误判成「被占」而顺延漂移。
            listener.cancel()
            _ = stateChanged.wait(timeout: .now() + 2)
        }
        return available
    }

    /// 从 preferred 起逐个探测（最多 maxAttempts 个），返回第一个可用的；全被占返回 nil。
    static func resolve(preferred: UInt16 = preferredPort, maxAttempts: Int = maxAttempts) -> UInt16? {
        for offset in 0..<maxAttempts {
            let candidate = Int(preferred) + offset
            guard candidate <= Int(UInt16.max) else { return nil }
            if isAvailable(UInt16(candidate)) {
                return UInt16(candidate)
            }
        }
        return nil
    }

    /// 先试持久化端口（非 0 且可用 → 原样拿回，不写回）；否则从 preferred 顺延，成功后持久化。
    /// 顺延结果与客户端配置里的地址不一致时，由编排层负责重写配置。
    static func resolvePersisted(defaults: UserDefaults) -> UInt16? {
        let persisted = defaults.integer(forKey: portDefaultsKey)
        if persisted != 0, let port = UInt16(exactly: persisted), isAvailable(port) {
            return port
        }
        guard let resolved = resolve() else { return nil }
        persist(resolved, defaults: defaults)
        return resolved
    }

    static func persist(_ port: UInt16, defaults: UserDefaults) {
        defaults.set(Int(port), forKey: portDefaultsKey)
    }
}
