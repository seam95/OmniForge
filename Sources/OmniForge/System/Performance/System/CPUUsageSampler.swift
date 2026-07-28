import Foundation

/// CPU 使用率采样器 — 通过 Mach host_statistics 计算四核平均非空闲占比
final class CPUUsageSampler: CPUUsageSampling {
    private var previousBusy: UInt32 = 0
    private var previousTotal: UInt32 = 0

    init() {}

    func sample() throws -> Double? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var loadInfo = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        guard result == KERN_SUCCESS else {
            throw MetricSamplingError.systemCall("host_statistics failed: \(result)")
        }

        let user = loadInfo.cpu_ticks.0
        let system = loadInfo.cpu_ticks.1
        let idle = loadInfo.cpu_ticks.2
        let nice = loadInfo.cpu_ticks.3
        let busy = user + system + nice
        let total = user + system + idle + nice

        guard total > previousTotal else {
            previousBusy = busy
            previousTotal = total
            return nil
        }

        let deltaBusy = busy - previousBusy
        let deltaTotal = total - previousTotal

        previousBusy = busy
        previousTotal = total

        guard deltaTotal > 0 else { return nil }
        return Double(deltaBusy) / Double(deltaTotal)
    }

    /// 纯静态计算 — 用于独立测试
    static func usage(previousBusy: UInt32, previousTotal: UInt32,
                      busy: UInt32, total: UInt32) -> Double? {
        guard total > previousTotal else { return nil }
        let deltaBusy = busy - previousBusy
        let deltaTotal = total - previousTotal
        guard deltaTotal > 0 else { return nil }
        return Double(deltaBusy) / Double(deltaTotal)
    }
}
