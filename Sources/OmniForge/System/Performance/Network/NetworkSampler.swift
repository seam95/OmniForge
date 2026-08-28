import Foundation

protocol NetworkCounterSource {
    func interfaceBytes() throws -> (received: UInt64, sent: UInt64)
}

final class RealNetworkCounterSource: NetworkCounterSource {
    func interfaceBytes() throws -> (received: UInt64, sent: UInt64) {
        let counters = Self.readCounters()
        return (counters.received, counters.sent)
    }

    static func readCounters() -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return NetworkCounters() }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return NetworkCounters() }

        var result = NetworkCounters()
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if MetricFormat.includeNetworkInterface(name) {
                            result.received += info.ifm_data.ifi_ibytes
                            result.sent += info.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }
}

final class NetworkSampler: NetworkSampling {
    private let counterSource: NetworkCounterSource
    private var previous: (counters: NetworkCounters, time: TimeInterval)?
    private var totalDown: UInt64 = 0
    private var totalUp: UInt64 = 0
    /// 上次有效速率：短间隔样本作废时沿用，避免 UI 速率闪空
    private var lastRates: (down: Double?, up: Double?) = (nil, nil)
    private static let maxGap: TimeInterval = 10
    /// 最小有效间隔：补采/手动刷新与定时 tick 背靠背时，除以极短 elapsed 会产生速率尖刺
    private static let minDeltaInterval: TimeInterval = 0.3

    init(counterSource: NetworkCounterSource = RealNetworkCounterSource()) {
        self.counterSource = counterSource
    }

    func sample(now: TimeInterval) throws -> NetworkReading {
        let (received, sent) = try counterSource.interfaceBytes()
        let current = NetworkCounters(received: received, sent: sent)
        defer { previous = (current, now) }

        guard let prev = previous, now > prev.time else {
            return NetworkReading(downBytesPerSec: nil, upBytesPerSec: nil,
                                 totalDown: totalDown, totalUp: totalUp)
        }
        let elapsed = now - prev.time
        // 间隔过短：速率样本作废并前移基线，沿用上次速率而非清空
        if elapsed < Self.minDeltaInterval {
            return NetworkReading(downBytesPerSec: lastRates.down, upBytesPerSec: lastRates.up,
                                 totalDown: totalDown, totalUp: totalUp)
        }
        guard elapsed <= Self.maxGap else {
            return NetworkReading(downBytesPerSec: nil, upBytesPerSec: nil,
                                 totalDown: totalDown, totalUp: totalUp)
        }

        let speed = MetricFormat.netSpeed(previous: prev.counters, current: current, elapsed: elapsed)
        if current.received >= prev.counters.received { totalDown += current.received - prev.counters.received }
        if current.sent >= prev.counters.sent { totalUp += current.sent - prev.counters.sent }
        lastRates = (speed.down, speed.up)
        return NetworkReading(downBytesPerSec: speed.down, upBytesPerSec: speed.up,
                             totalDown: totalDown, totalUp: totalUp)
    }
}
