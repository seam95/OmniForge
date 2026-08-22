import Foundation

/// CPU 使用率采样器 — 通过 Mach host_statistics 计算四核平均非空闲占比，
/// 并拆分系统/用户态（nice 并入系统，保证 user + system == total）。
final class CPUUsageSampler: CPUUsageSampling {
    private var previousUser: UInt32 = 0
    private var previousSystem: UInt32 = 0
    private var previousNice: UInt32 = 0
    private var previousTotal: UInt32 = 0

    init() {}

    func sample() throws -> CPUUsageReading? {
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
        let total = user + system + idle + nice

        guard total > previousTotal else {
            previousUser = user
            previousSystem = system
            previousNice = nice
            previousTotal = total
            return nil
        }

        let deltaUser = user - previousUser
        let deltaSystem = system - previousSystem
        let deltaNice = nice - previousNice
        let deltaTotal = total - previousTotal

        previousUser = user
        previousSystem = system
        previousNice = nice
        previousTotal = total

        guard deltaTotal > 0 else { return nil }
        return CPUUsageReading(
            total: Double(deltaUser + deltaSystem + deltaNice) / Double(deltaTotal),
            user: Double(deltaUser) / Double(deltaTotal),
            system: Double(deltaSystem + deltaNice) / Double(deltaTotal)
        )
    }

    /// 纯静态计算 — 用于独立测试
    static func reading(previousUser: UInt32, previousSystem: UInt32, previousNice: UInt32, previousTotal: UInt32,
                        user: UInt32, system: UInt32, nice: UInt32, total: UInt32) -> CPUUsageReading? {
        guard total > previousTotal else { return nil }
        let deltaUser = user - previousUser
        let deltaSystem = system - previousSystem
        let deltaNice = nice - previousNice
        let deltaTotal = total - previousTotal
        guard deltaTotal > 0 else { return nil }
        return CPUUsageReading(
            total: Double(deltaUser + deltaSystem + deltaNice) / Double(deltaTotal),
            user: Double(deltaUser) / Double(deltaTotal),
            system: Double(deltaSystem + deltaNice) / Double(deltaTotal)
        )
    }
}
