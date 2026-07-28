import Darwin
import Foundation
import IOKit

final class ProcessUsageSampler: ProcessUsageSampling {
    private let lock = NSLock()
    private var previousGPUSample: (time: TimeInterval, perPid: [pid_t: Double])?
    private var networkDeltaTracker = NetworkProcessDeltaTracker()

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        switch kind {
        case .cpu: return try topCPU(limit: limit)
        case .memory: return try topMemory(limit: limit)
        case .gpu: return topGPU(limit: limit)
        case .energy: return topEnergy(limit: limit)
        case .network: return topNetwork(limit: limit)
        }
    }

    func stop(_ kind: ProcessMetricKind) {
        switch kind {
        case .network:
            lock.lock()
            networkDeltaTracker.reset()
            lock.unlock()
        case .gpu:
            lock.lock()
            previousGPUSample = nil
            lock.unlock()
        case .cpu, .memory, .energy:
            break
        }
    }

    // MARK: - Baseline priming

    /// 提前为 delta 类指标建立基线，避免首次展开只返回空。结果被丢弃。
    func primeProcessBaselines(for kinds: [ProcessMetricKind]) {
        for kind in kinds {
            switch kind {
            case .gpu:
                _ = topGPU(limit: 0)
            case .network:
                _ = topNetwork(limit: 0)
            case .cpu, .memory, .energy:
                break
            }
        }
    }

    /// 下次 `sample` 是否能产出真实数据。delta 类指标在建立基线前返回 false。
    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .gpu:
            lock.lock()
            let previous = previousGPUSample
            lock.unlock()
            guard let previous else { return false }
            return now > previous.time && now - previous.time < 30
        case .network:
            lock.lock()
            let has = networkDeltaTracker.hasBaseline(now: now)
            lock.unlock()
            return has
        case .cpu, .memory, .energy:
            return true
        }
    }

    // MARK: - CPU

    private func topCPU(limit: Int) throws -> [ProcessUsage] {
        let result = Shell.run("/bin/ps", ["-Aceo", "pid,pcpu,comm", "-r"])
        guard result.status == 0 else { throw MetricSamplingError.systemCall("ps failed") }
        let rows = parsePS(result.output, maxRows: rawProcessRowLimit(for: limit)) { Double($0) ?? 0 }
        return Array(groupedByApp(rows).prefix(limit))
    }

    // MARK: - Memory

    private func topMemory(limit: Int) throws -> [ProcessUsage] {
        let result = Shell.run("/bin/ps", ["-Aceo", "pid,rss,comm", "-m"])
        guard result.status == 0 else { throw MetricSamplingError.systemCall("ps failed") }
        // ps ranks candidates by rss; display value uses phys_footprint when available
        // (Activity Monitor Memory column), falling back to rss bytes.
        let rows = parsePS(result.output, maxRows: rawProcessRowLimit(for: limit)) {
            (Double($0) ?? 0) * 1024
        }.map { row in
            guard let footprint = Self.physicalFootprint(of: row.pid) else { return row }
            return ProcessUsage(pid: row.pid, name: row.name, value: footprint)
        }
        return Array(groupedByApp(rows).prefix(limit))
    }

    /// Kernel physical memory footprint. Nil when the process died between
    /// the ps snapshot and this call (or for an invalid pid).
    static func physicalFootprint(of pid: pid_t) -> Double? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard status == 0, info.ri_phys_footprint > 0 else { return nil }
        return Double(info.ri_phys_footprint)
    }

    // MARK: - GPU

    /// Per-process GPU share since the previous call. The first call only primes
    /// the baseline and returns [].
    private func topGPU(limit: Int) -> [ProcessUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        let current = Self.gpuTimePerPid()

        lock.lock()
        let previous = previousGPUSample
        previousGPUSample = (now, current)
        lock.unlock()

        guard let previous,
              now > previous.time,
              now - previous.time < 30 // stale baseline => re-prime
        else { return [] }

        let elapsedNs = (now - previous.time) * 1_000_000_000
        var rows: [ProcessUsage] = []
        for (pid, total) in current {
            guard let before = previous.perPid[pid], total > before else { continue }
            let percent = (total - before) / elapsedNs * 100
            guard percent >= 0.05 else { continue }
            rows.append(ProcessUsage(pid: pid, name: "pid \(pid)", value: min(percent, 100)))
        }
        return Array(groupedByApp(rows).prefix(limit))
    }

    // MARK: - Energy

    private func topEnergy(limit: Int) -> [ProcessUsage] {
        let cpu = (try? topCPU(limit: max(limit * 3, 12))) ?? []
        let gpu = topGPU(limit: max(limit * 3, 12))
        var scores: [pid_t: (name: String, value: Double)] = [:]
        for row in cpu + gpu {
            var score = scores[row.pid] ?? (row.name, 0)
            score.value += row.value
            if score.name.hasPrefix("pid ") { score.name = row.name }
            scores[row.pid] = score
        }
        return scores
            .filter { _, score in score.value >= 2 }
            .sorted { $0.value.value > $1.value.value }
            .prefix(limit)
            .map { pid, score in
                ProcessUsage(pid: pid, name: score.name, value: score.value)
            }
    }

    // MARK: - Network

    private func topNetwork(limit: Int) -> [ProcessUsage] {
        let samples = NetworkProcessSupport.currentActivitySamples()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let rates = networkDeltaTracker.rates(from: samples, now: now)
        lock.unlock()
        return Array(groupedNetworkByApp(rates).prefix(limit))
    }

    // MARK: - Consolidation

    private func groupedByApp(_ rows: [ProcessUsage]) -> [ProcessUsage] {
        var totals: [pid_t: Double] = [:]
        var fallbackNames: [pid_t: String] = [:]

        for row in rows {
            let owner = ResponsibleProcess.owner(of: row.pid)
            totals[owner, default: 0] += row.value
            if fallbackNames[owner] == nil {
                fallbackNames[owner] = row.name
            }
        }

        return totals
            .sorted { $0.value > $1.value }
            .map { owner, value in
                ProcessUsage(
                    pid: owner,
                    name: ResponsibleProcess.displayName(
                        pid: owner,
                        fallback: fallbackNames[owner] ?? "pid \(owner)"
                    ),
                    value: value
                )
            }
    }

    private func groupedNetworkByApp(_ samples: [NetworkProcessSample]) -> [ProcessUsage] {
        var totals: [pid_t: (down: Double, up: Double)] = [:]
        var fallbackNames: [pid_t: String] = [:]

        for sample in samples {
            let owner = ResponsibleProcess.owner(of: sample.pid)
            var total = totals[owner] ?? (0, 0)
            total.down += sample.bytesIn
            total.up += sample.bytesOut
            totals[owner] = total
            if fallbackNames[owner] == nil {
                fallbackNames[owner] = sample.name
            }
        }

        return totals
            .map { owner, value in
                ProcessUsage(
                    pid: owner,
                    name: ResponsibleProcess.displayName(
                        pid: owner,
                        fallback: fallbackNames[owner] ?? "pid \(owner)"
                    ),
                    value: value.down + value.up,
                    networkDownBytesPerSec: value.down,
                    networkUpBytesPerSec: value.up
                )
            }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    // MARK: - Helpers

    private func parsePS(
        _ output: String,
        maxRows: Int,
        transform: (String) -> Double
    ) -> [ProcessUsage] {
        var rows: [ProcessUsage] = []
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count == 3, let pid = pid_t(columns[0]) else { continue }
            let value = transform(String(columns[1]))
            guard value > 0 else { continue }
            rows.append(
                ProcessUsage(
                    pid: pid,
                    name: String(columns[2]).trimmingCharacters(in: .whitespaces),
                    value: value
                )
            )
            if rows.count >= maxRows { break }
        }
        return rows
    }

    private func rawProcessRowLimit(for limit: Int) -> Int {
        max(limit * 10, 120)
    }

    private static func gpuTimePerPid() -> [pid_t: Double] {
        var perPid: [pid_t: Double] = [:]

        var accelIterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &accelIterator
        ) == kIOReturnSuccess else { return perPid }
        defer { IOObjectRelease(accelIterator) }

        var accelerator = IOIteratorNext(accelIterator)
        while accelerator != 0 {
            defer {
                IOObjectRelease(accelerator)
                accelerator = IOIteratorNext(accelIterator)
            }

            var clients = io_iterator_t()
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == kIOReturnSuccess
            else { continue }
            defer { IOObjectRelease(clients) }

            var client = IOIteratorNext(clients)
            while client != 0 {
                defer {
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }

                guard let creatorRef = IORegistryEntryCreateCFProperty(
                    client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0
                ),
                let creator = creatorRef.takeRetainedValue() as? String,
                let pid = pid(fromCreator: creator)
                else { continue }

                guard let usageRef = IORegistryEntryCreateCFProperty(
                    client, "AppUsage" as CFString, kCFAllocatorDefault, 0
                ),
                let usage = usageRef.takeRetainedValue() as? [[String: Any]]
                else { continue }

                for entry in usage {
                    if let time = entry["accumulatedGPUTime"] as? Double {
                        perPid[pid, default: 0] += time
                    } else if let time = entry["accumulatedGPUTime"] as? Int64 {
                        perPid[pid, default: 0] += Double(time)
                    }
                }
            }
        }
        return perPid
    }

    private static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
