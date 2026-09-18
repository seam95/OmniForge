import Foundation

/// CPU 使用率采样器 — 通过 Mach host_statistics 计算四核平均非空闲占比，
/// 并拆分系统/用户态（nice 并入系统，保证 user + system == total）。
final class CPUUsageSampler: CPUUsageSampling {
    private var previousUser: UInt64 = 0
    private var previousSystem: UInt64 = 0
    private var previousNice: UInt64 = 0
    private var previousTotal: UInt64 = 0

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

        // cpu_ticks 是开机以来的 UInt32 累计值，多核高负载下数十天即可填满，
        // UInt32 直接求和/差分会溢出 trap——统一升到 UInt64 再运算。
        let user = UInt64(loadInfo.cpu_ticks.0)
        let system = UInt64(loadInfo.cpu_ticks.1)
        let idle = UInt64(loadInfo.cpu_ticks.2)
        let nice = UInt64(loadInfo.cpu_ticks.3)
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

    /// 纯静态计算 — 用于独立测试（入参保持 UInt32 机器口径，内部升位运算）
    static func reading(previousUser: UInt32, previousSystem: UInt32, previousNice: UInt32, previousTotal: UInt32,
                        user: UInt32, system: UInt32, nice: UInt32, total: UInt32) -> CPUUsageReading? {
        let user64 = UInt64(user), system64 = UInt64(system)
        let nice64 = UInt64(nice), total64 = UInt64(total)
        let prevUser = UInt64(previousUser), prevSystem = UInt64(previousSystem)
        let prevNice = UInt64(previousNice), prevTotal = UInt64(previousTotal)
        guard total64 > prevTotal else { return nil }
        let deltaUser = user64 - prevUser
        let deltaSystem = system64 - prevSystem
        let deltaNice = nice64 - prevNice
        let deltaTotal = total64 - prevTotal
        guard deltaTotal > 0 else { return nil }
        return CPUUsageReading(
            total: Double(deltaUser + deltaSystem + deltaNice) / Double(deltaTotal),
            user: Double(deltaUser) / Double(deltaTotal),
            system: Double(deltaSystem + deltaNice) / Double(deltaTotal)
        )
    }
}
