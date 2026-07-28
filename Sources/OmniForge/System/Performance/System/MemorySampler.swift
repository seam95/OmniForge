import Foundation

/// 内存采样器 — 通过 Mach host_statistics 读取物理内存压力和用量
final class MemorySampler: MemorySampling {
    init() {}

    func sample() throws -> MemoryReading {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var vmInfo = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MetricSamplingError.systemCall("host_statistics64 failed: \(result)")
        }

        let total = ProcessInfo.processInfo.physicalMemory
        let used = MetricFormat.memoryUsed(
            totalBytes: total,
            pageSize: UInt64(vm_kernel_page_size),
            freePages: UInt64(vmInfo.free_count),
            speculativePages: UInt64(vmInfo.speculative_count),
            fileBackedPages: UInt64(vmInfo.external_page_count)
        )
        return MemoryReading(used: used, total: total, pressure: Self.readMemoryPressure())
    }

    private static func readMemoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressure(kernelLevel: level)
    }
}
