import Foundation
import IOKit

final class DiskSampler: DiskSampling {
    private var previous: [String: (counters: DiskIOCounters, time: TimeInterval)] = [:]
    private var sessionTotals: [String: DiskIOCounters] = [:]
    /// mountPath → diskutil 元数据缓存；isFull 表示已成功跑过完整 diskutil
    private var metadataCache: [String: (metadata: DiskSupport.DiskutilMetadata, updatedAt: TimeInterval, isFull: Bool)] = [:]
    private static let maxGap: TimeInterval = 15
    private static let metadataRefreshInterval: TimeInterval = 30
    /// 后台可复用 full 缓存上限（对齐 vorssaint / SPEC）
    private static let backgroundMetadataRefreshInterval: TimeInterval = 3600

    init() {}

    /// Pure helper: compute rates and updated session totals for one disk.
    /// - Returns rates as nil when previous is missing, elapsed is invalid, or gap exceeds maxGap.
    /// - Session totals accumulate deltas only when the sample is within maxGap; otherwise reset to zero.
    static func accumulate(
        previous: DiskIOCounters?,
        current: DiskIOCounters,
        session: DiskIOCounters,
        elapsed: TimeInterval?,
        maxGap: TimeInterval
    ) -> (rates: (read: Double?, write: Double?), session: DiskIOCounters) {
        guard let previous, let elapsed, elapsed > 0, elapsed <= maxGap else {
            return (rates: (nil, nil), session: DiskIOCounters())
        }

        var nextSession = session
        var readRate: Double?
        var writeRate: Double?

        if current.read >= previous.read {
            let delta = current.read - previous.read
            nextSession.read += delta
            readRate = Double(delta) / elapsed
        }
        if current.written >= previous.written {
            let delta = current.written - previous.written
            nextSession.written += delta
            writeRate = Double(delta) / elapsed
        }

        return (rates: (readRate, writeRate), session: nextSession)
    }

    func sample(now: TimeInterval, refreshMetadata: Bool) throws -> DiskReading {
        let volumes = DiskSupport.mountedVolumes()
        let counters = Self.readDiskCounters()
        // Per unique whole-disk / service key: rates + session
        var uniqueRates: [String: (read: Double?, write: Double?)] = [:]
        var uniqueSessions: [String: DiskIOCounters] = [:]

        for (diskID, current) in counters {
            let prev = previous[diskID]
            let elapsed: TimeInterval? = {
                guard let prev, now > prev.time else { return nil }
                return now - prev.time
            }()
            let result = Self.accumulate(
                previous: prev?.counters,
                current: current,
                session: sessionTotals[diskID] ?? DiskIOCounters(),
                elapsed: elapsed,
                maxGap: Self.maxGap
            )
            sessionTotals[diskID] = result.session
            uniqueRates[diskID] = result.rates
            uniqueSessions[diskID] = result.session
            previous[diskID] = (current, now)
        }

        // Map volumes → devices；元数据来自 diskutil（带缓存）
        var usedCounterIDs = Set<String>()
        let devices: [DiskDeviceReading] = volumes
            .map { volume in
                let meta = metadata(for: volume, now: now, refresh: refreshMetadata)
                let bsdName = meta.bsdName ?? volume.bsdName
                let wholeDisk = meta.wholeDisk
                    ?? DiskSupport.wholeDiskBSDName(from: bsdName)
                let ioCandidates: [String] = {
                    if !meta.ioCounterIDs.isEmpty {
                        return meta.ioCounterIDs
                    }
                    return [wholeDisk, bsdName].compactMap { $0 }
                }()
                let ioID = Self.bestCounterID(candidates: ioCandidates, counters: counters)
                let rates = ioID.flatMap { uniqueRates[$0] }
                let session = ioID.flatMap { uniqueSessions[$0] }
                if let ioID { usedCounterIDs.insert(ioID) }

                let isInternal = meta.isInternal ?? volume.isInternal
                let isRemovable = meta.isRemovable ?? volume.isRemovable
                let isEjectable = (meta.isEjectable ?? volume.isEjectable)
                    || (!isInternal && isRemovable)
                let capacity = Self.bestCapacity(volume: volume, metadata: meta)
                let displayName: String = {
                    if let media = meta.mediaName, !media.isEmpty { return media }
                    return volume.name
                }()

                return DiskDeviceReading(
                    id: volume.mountPath,
                    name: displayName,
                    mountPath: volume.mountPath,
                    bsdName: bsdName,
                    wholeDisk: wholeDisk,
                    ioCounterID: ioID,
                    totalBytes: capacity.total,
                    freeBytes: capacity.free,
                    usedBytes: capacity.used,
                    isInternal: isInternal,
                    isRemovable: isRemovable,
                    isEjectable: isEjectable,
                    fileSystem: meta.fileSystem,
                    smart: meta.smart,
                    readBytesPerSec: rates?.read,
                    writeBytesPerSec: rates?.write,
                    totalReadBytes: session?.read,
                    totalWrittenBytes: session?.written
                )
            }
            .sorted(by: Self.sortVolumes)

        // Aggregate unique IO (avoid double-counting multi-volume same disk)
        var readRate: Double = 0
        var writeRate: Double = 0
        var sessionRead: UInt64 = 0
        var sessionWritten: UInt64 = 0
        var seenIO = Set<String>()
        for device in devices {
            let ioKey = device.ioCounterID
                ?? device.wholeDisk
                ?? device.bsdName
                ?? device.mountPath
            guard seenIO.insert(ioKey).inserted else { continue }
            if let r = device.readBytesPerSec { readRate += r }
            if let w = device.writeBytesPerSec { writeRate += w }
            if let tr = device.totalReadBytes { sessionRead += tr }
            if let tw = device.totalWrittenBytes { sessionWritten += tw }
        }

        // Include unmapped IO drivers (no volume match) so totals stay complete
        for (diskID, rates) in uniqueRates where !usedCounterIDs.contains(diskID) {
            if let r = rates.read { readRate += r }
            if let w = rates.write { writeRate += w }
            if let session = uniqueSessions[diskID] {
                sessionRead += session.read
                sessionWritten += session.written
            }
        }

        let primary = devices.first(where: { $0.mountPath == "/" })
            ?? devices.first(where: \.isInternal)
            ?? devices.first

        let physicalDisks = DiskSupport.aggregatePhysicalDisks(from: devices)

        return DiskReading(
            devices: devices,
            physicalDisks: physicalDisks,
            readBytesPerSec: readRate,
            writeBytesPerSec: writeRate,
            totalRead: sessionRead,
            totalWritten: sessionWritten,
            freeSpace: primary?.freeBytes ?? DiskSupport.freeSpace(),
            totalSpace: primary?.totalBytes ?? DiskSupport.totalSpace()
        )
    }

    /// 元数据缓存：30s 内可复用；仅 isFull=true 的成功结果可在后台复用至 3600s。
    /// isFull=false（diskutil 失败）不得当作 full，避免后台最长 3600s 跳过重试。
    private func metadata(
        for volume: DiskSupport.MountedVolume,
        now: TimeInterval,
        refresh: Bool
    ) -> DiskSupport.DiskutilMetadata {
        if let cached = metadataCache[volume.mountPath],
           now - cached.updatedAt < Self.metadataRefreshInterval,
           cached.isFull || !refresh {
            return cached.metadata
        }
        // 后台：仅复用成功 full 缓存，避免关面板后狂跑 diskutil
        if !refresh,
           let cached = metadataCache[volume.mountPath],
           cached.isFull,
           now - cached.updatedAt < Self.backgroundMetadataRefreshInterval {
            return cached.metadata
        }
        let result = Self.diskutilMetadata(for: volume.mountPath, fallbackBSD: volume.bsdName)
        // 仅成功完整解析才 isFull=true；失败写 isFull=false，允许后台重试
        metadataCache[volume.mountPath] = (result.metadata, now, result.isFull)
        return result.metadata
    }

    /// 跑 diskutil；失败时返回带 bsd 回退的空 metadata（isFull=false），不中断采样
    private static func diskutilMetadata(
        for mountPath: String,
        fallbackBSD: String?
    ) -> (metadata: DiskSupport.DiskutilMetadata, isFull: Bool) {
        guard let info = runDiskutilInfo(mountPath) else {
            var empty = DiskSupport.DiskutilMetadata()
            empty.bsdName = fallbackBSD
            empty.wholeDisk = DiskSupport.wholeDiskBSDName(from: fallbackBSD)
            empty.ioCounterIDs = [empty.wholeDisk, fallbackBSD].compactMap { $0 }
            return (empty, false)
        }
        var meta = DiskSupport.metadata(fromDiskutilInfo: info)
        if meta.bsdName == nil {
            meta.bsdName = fallbackBSD
        }
        if meta.wholeDisk == nil {
            meta.wholeDisk = DiskSupport.wholeDiskBSDName(from: meta.bsdName ?? fallbackBSD)
        }
        if meta.ioCounterIDs.isEmpty {
            meta.ioCounterIDs = [meta.wholeDisk, meta.bsdName ?? fallbackBSD].compactMap { $0 }
        }
        return (meta, true)
    }

    private static func runDiskutilInfo(_ mountPath: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", mountPath]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let dict = plist as? [String: Any] else { return nil }
        return dict
    }

    /// 容量：优先 FileManager 卷值。freeBytes==0 是合法“已满”状态，不得用 APFSContainerFree 覆盖。
    /// 仅当卷 total 不可用（==0）时，才回退 diskutil 容器容量字段。
    static func bestCapacity(
        volume: DiskSupport.MountedVolume,
        metadata: DiskSupport.DiskutilMetadata
    ) -> (total: UInt64, free: UInt64, used: UInt64) {
        if volume.totalBytes > 0 {
            let total = volume.totalBytes
            let free = min(volume.freeBytes, total)
            return (total, free, total - free)
        }
        let total = metadata.totalBytes ?? 0
        let free = min(metadata.freeBytes ?? 0, total)
        if let metadataUsed = metadata.usedBytes {
            return (total, free, min(metadataUsed, total))
        }
        return (total, free, total >= free ? total - free : 0)
    }

    private static func bestCounterID(candidates: [String], counters: [String: DiskIOCounters]) -> String? {
        for id in candidates {
            if counters[id] != nil { return id }
        }
        return nil
    }

    private static func sortVolumes(_ lhs: DiskDeviceReading, _ rhs: DiskDeviceReading) -> Bool {
        if lhs.isInternal != rhs.isInternal { return lhs.isInternal && !rhs.isInternal }
        if lhs.mountPath == "/" { return true }
        if rhs.mountPath == "/" { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// IOBlockStorageDriver counters keyed by whole-disk BSD name when available.
    private static func readDiskCounters() -> [String: DiskIOCounters] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == kIOReturnSuccess else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [String: DiskIOCounters] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                let read = DiskSupport.uint(stats["Bytes (Read)"]) ?? 0
                let written = DiskSupport.uint(stats["Bytes (Write)"]) ?? 0
                let key = wholeDiskBSDName(descendingFrom: service) ?? String(describing: service)
                // Prefer first whole-disk entry; avoid overwriting with zeros later
                if result[key] == nil {
                    result[key] = DiskIOCounters(read: read, written: written)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    private static func wholeDiskBSDName(descendingFrom entry: io_registry_entry_t) -> String? {
        if let whole = property("Whole", from: entry) as? Bool,
           whole,
           let name = property("BSD Name", from: entry) as? String {
            return DiskSupport.wholeDiskBSDName(from: name) ?? name
        }

        var childIterator = io_iterator_t()
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        var child = IOIteratorNext(childIterator)
        while child != 0 {
            if let name = wholeDiskBSDName(descendingFrom: child) {
                IOObjectRelease(child)
                return name
            }
            IOObjectRelease(child)
            child = IOIteratorNext(childIterator)
        }
        return nil
    }

    private static func property(_ key: String, from entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
