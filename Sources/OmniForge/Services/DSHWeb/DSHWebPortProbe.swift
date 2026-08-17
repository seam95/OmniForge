import Foundation
import Network

// MARK: - 端口探测协议

/// TCP 探测指定端口是否可连。
protocol DSHWebPortProbing {
    /// 端口可连返回 true（对已占用端口同样返回 true）。
    func isPortOpen(_ port: UInt16) -> Bool
}

// MARK: - 生产实现

/// NWConnection 本地 TCP 探测：300ms 超时，阻塞调用（本地 connect 通常毫秒级）。
final class NWConnectionPortProbe: DSHWebPortProbing {
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 300_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func isPortOpen(_ port: UInt16) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let connection = NWConnection(
            host: "127.0.0.1",
            port: endpointPort,
            using: .tcp
        )
        var result = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        _ = semaphore.wait(timeout: .now() + .nanoseconds(Int(timeoutNanoseconds)))
        connection.cancel()
        return result
    }
}
