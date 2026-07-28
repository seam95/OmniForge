import Foundation
import IOKit

/// GPU 使用率采样器 — 通过 IORegistry 读取 IOAccelerator PerformanceStatistics
final class GPUUsageSampler: GPUUsageSampling {
    init() {}

    func sample() throws -> Double? {
        let port = kIOMainPortDefault
        // IOAccelerator covers AGX and other accelerators (align with Vorssaint)
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(port, matching, &iterator)
        guard kr == kIOReturnSuccess else {
            throw MetricSamplingError.systemCall("IOAccelerator lookup failed: \(kr)")
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            // Fetch ONLY PerformanceStatistics, not the whole property tree
            guard let ref = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            ),
            let stats = ref.takeRetainedValue() as? [String: Any],
            let utilization = Self.utilization(from: stats)
            else { continue }
            return utilization
        }
        return nil
    }

    /// 从性能统计字典中提取利用率
    static func utilization(from stats: [String: Any]) -> Double? {
        if let raw = stats["Device Utilization %"] as? Int {
            return Double(raw) / 100.0
        }
        return nil
    }
}
