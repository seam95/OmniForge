import Darwin
import Foundation

/// 磁盘辅助函数与 SMART 纯计算
enum DiskSupport {
    static let nvmeDataUnitBytes: UInt64 = 512_000

    /// diskutil info -plist 解析结果（可测纯数据）
    struct DiskutilMetadata: Equatable {
        var bsdName: String?
        var wholeDisk: String?
        var ioCounterIDs: [String] = []
        var totalBytes: UInt64?
        var freeBytes: UInt64?
        var usedBytes: UInt64?
        var isInternal: Bool?
        var isRemovable: Bool?
        var isEjectable: Bool?
        var fileSystem: String?
        var mediaName: String?
        var smart: DiskSMARTReading?
    }

    /// 从 diskutil info 字典提取卷/物理盘元数据与 SMART
    static func metadata(fromDiskutilInfo info: [String: Any]) -> DiskutilMetadata {
        let bsdName = info["DeviceIdentifier"] as? String
        let parentWholeDisk = info["ParentWholeDisk"] as? String
        let physicalStore = (info["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String
        let wholeDisk = wholeDiskBSDName(from: physicalStore)
            ?? wholeDiskBSDName(from: parentWholeDisk)
            ?? wholeDiskBSDName(from: bsdName)
        let total = uint(info["APFSContainerSize"]) ?? uint(info["TotalSize"])
        let free = uint(info["APFSContainerFree"]) ?? uint(info["FreeSpace"])
        let used = uint(info["CapacityInUse"])
            ?? total.flatMap { total in free.map { total >= $0 ? total - $0 : 0 } }
        let isInternal = info["Internal"] as? Bool
        let status = info["SMARTStatus"] as? String
        let vendorKeys = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any]
        let fileSystem = (info["FilesystemType"] as? String)
            ?? (info["FilesystemName"] as? String)
        // mediaName 只用真实媒体名；禁止回退 DeviceNode（如 /dev/disk0s2）。
        // IORegistryEntryName 仅在像媒体名时采用，否则留 nil，显示侧用卷名。
        let mediaName = nonEmptyString(info["MediaName"])
            ?? reasonableMediaName(info["IORegistryEntryName"])
        return DiskutilMetadata(
            bsdName: bsdName,
            wholeDisk: wholeDisk,
            ioCounterIDs: ioCounterIDs(
                bsdName: bsdName,
                parentWholeDisk: parentWholeDisk,
                physicalStore: physicalStore,
                isInternal: isInternal ?? false
            ),
            totalBytes: total,
            freeBytes: free,
            usedBytes: used,
            isInternal: isInternal,
            isRemovable: (info["RemovableMediaOrExternalDevice"] as? Bool)
                ?? (info["Removable"] as? Bool)
                ?? (info["RemovableMedia"] as? Bool),
            isEjectable: (info["Ejectable"] as? Bool)
                ?? (info["EjectableOnly"] as? Bool),
            fileSystem: fileSystem,
            mediaName: mediaName,
            smart: smartReading(status: status, vendorKeys: vendorKeys)
        )
    }

    /// IO 候选优先级：内置 physicalWhole → parentWhole → bsdWhole → bsdName；外置 bsdName 优先
    private static func ioCounterIDs(
        bsdName: String?,
        parentWholeDisk: String?,
        physicalStore: String?,
        isInternal: Bool
    ) -> [String] {
        let physicalWhole = wholeDiskBSDName(from: physicalStore)
        let parentWhole = wholeDiskBSDName(from: parentWholeDisk)
        let bsdWhole = wholeDiskBSDName(from: bsdName)
        let raw = isInternal
            ? [physicalWhole, parentWhole, bsdWhole, bsdName]
            : [bsdName, parentWhole, physicalWhole, bsdWhole]
        var seen = Set<String>()
        return raw.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 过滤掉设备节点 / BSD 标识，避免把 /dev/disk0s2 或 disk0 当成媒体名
    private static func reasonableMediaName(_ value: Any?) -> String? {
        guard let name = nonEmptyString(value) else { return nil }
        if name.hasPrefix("/dev/") { return nil }
        // diskN / diskNsM 等 BSD 名不是媒体名
        if name.range(of: #"^disk\d+"#, options: .regularExpression) != nil { return nil }
        return name
    }

    /// 将 SMART 温度（开尔文）转换为摄氏度（历史 API）
    static func celsius(fromSMARTTemperature kelvin: Int) -> Double {
        Double(kelvin) - 273.15
    }

    /// SMART 原始温度：>150 按开尔文，否则按摄氏度
    static func celsius(fromSMARTTemperature raw: UInt64?) -> Double? {
        guard let raw else { return nil }
        let value = Double(raw)
        if value > 150 {
            let celsius = value - 273.15
            return (-40...125).contains(celsius) ? celsius : nil
        }
        return (1...125).contains(value) ? value : nil
    }

    /// NVMe DATA_UNITS_* 高低字合成字节数（单位 512_000）
    static func nvmeBytes(low: UInt64?, high: UInt64?) -> UInt64? {
        guard let low else { return nil }
        let high = high ?? 0
        guard high <= UInt64(UInt32.max) else { return nil }
        let units = low.addingReportingOverflow(high << 32)
        guard !units.overflow else { return nil }
        let bytes = units.partialValue.multipliedReportingOverflow(by: nvmeDataUnitBytes)
        return bytes.overflow ? nil : bytes.partialValue
    }

    /// NVMe PERCENTAGE_USED → 剩余健康百分比
    static func healthPercent(fromPercentageUsed used: UInt64?) -> Int? {
        guard let used else { return nil }
        return max(0, min(100, 100 - Int(used)))
    }

    /// 从 SMARTStatus + VendorSpecificSMARTKeys 解析 SMART 读数；全空时返回 nil
    static func smartReading(status: String?, vendorKeys: [String: Any]?) -> DiskSMARTReading? {
        let keys = vendorKeys ?? [:]
        var reading = DiskSMARTReading()
        reading.status = status?.isEmpty == false ? status : nil
        reading.totalReadBytes = nvmeBytes(
            low: uint(keys["DATA_UNITS_READ_0"]),
            high: uint(keys["DATA_UNITS_READ_1"])
        )
        reading.totalWrittenBytes = nvmeBytes(
            low: uint(keys["DATA_UNITS_WRITTEN_0"]),
            high: uint(keys["DATA_UNITS_WRITTEN_1"])
        )
        reading.temperatureCelsius = celsius(fromSMARTTemperature: uint(keys["TEMPERATURE"]))
        reading.healthPercent = healthPercent(fromPercentageUsed: uint(keys["PERCENTAGE_USED"]))
        reading.powerCycles = uint(keys["POWER_CYCLES_0"])
        reading.powerOnHours = uint(keys["POWER_ON_HOURS_0"])
        reading.unsafeShutdowns = uint(keys["UNSAFE_SHUTDOWNS_0"])
        reading.mediaErrors = uint(keys["MEDIA_ERRORS_0"])
        return reading.hasDetails ? reading : nil
    }

    struct IOCounters {
        let read: UInt64
        let written: UInt64
    }

    struct DiskSpeed {
        let read: Double?
        let write: Double?
    }

    /// 计算 IO 速率；计数器重置返回 nil
    static func speed(previous: IOCounters, current: IOCounters, elapsed: TimeInterval) -> DiskSpeed {
        guard elapsed > 0 else { return DiskSpeed(read: nil, write: nil) }
        let readRate: Double? = current.read >= previous.read
            ? Double(current.read - previous.read) / elapsed : nil
        let writeRate: Double? = current.written >= previous.written
            ? Double(current.written - previous.written) / elapsed : nil
        return DiskSpeed(read: readRate, write: writeRate)
    }

    /// 获取卷可用空间
    static func freeSpace(at path: String = "/") -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
        return attrs[.systemFreeSize] as? UInt64
    }

    /// 获取卷总空间
    static func totalSpace(at path: String = "/") -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
        return attrs[.systemSize] as? UInt64
    }

    /// 已挂载本地卷（容量/可用）
    struct MountedVolume: Equatable {
        var name: String
        var mountPath: String
        var totalBytes: UInt64
        var freeBytes: UInt64
        var usedBytes: UInt64
        var isInternal: Bool
        var isRemovable: Bool
        var isEjectable: Bool
        var bsdName: String?
    }

    static func mountedVolumes() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal != false,
                  let total = positiveUInt(values.volumeTotalCapacity),
                  total > 0 else { return nil }
            let free = positiveUInt(values.volumeAvailableCapacityForImportantUsage, requiringPositive: true)
                ?? positiveUInt(values.volumeAvailableCapacity, requiringPositive: true)
                ?? positiveUInt(values.volumeAvailableCapacityForImportantUsage)
                ?? positiveUInt(values.volumeAvailableCapacity)
                ?? 0
            let clampedFree = min(free, total)
            let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
            return MountedVolume(
                name: name.isEmpty ? url.path : name,
                mountPath: url.path,
                totalBytes: total,
                freeBytes: clampedFree,
                usedBytes: total - clampedFree,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                bsdName: bsdName(for: url.path)
            )
        }
    }

    static func bsdName(for mountPath: String) -> String? {
        var fs = statfs()
        guard statfs(mountPath, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: fs.f_mntfromname) { rawBuffer -> String? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return nil
            }
            let value = String(cString: base)
            let trimmed = value.replacingOccurrences(of: "/dev/", with: "")
            return trimmed.hasPrefix("disk") ? trimmed : nil
        }
    }

    /// 将 diskXsY / diskX 归一为 whole disk（diskX）
    static func wholeDiskBSDName(from identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let trimmed = identifier.replacingOccurrences(of: "/dev/", with: "")
        guard trimmed.hasPrefix("disk") else { return nil }
        var index = trimmed.index(trimmed.startIndex, offsetBy: 4)
        let numberStart = index
        while index < trimmed.endIndex, trimmed[index].isNumber {
            index = trimmed.index(after: index)
        }
        guard index > numberStart else { return nil }
        return String(trimmed[..<index])
    }

    private static func positiveUInt(_ value: Int?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    private static func positiveUInt(_ value: Int?, requiringPositive: Bool) -> UInt64? {
        guard let result = positiveUInt(value), !requiringPositive || result > 0 else { return nil }
        return result
    }

    private static func positiveUInt(_ value: Int64?, requiringPositive: Bool) -> UInt64? {
        guard let result = positiveUInt(value), !requiringPositive || result > 0 else { return nil }
        return result
    }

    private static func positiveUInt(_ value: Int64?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    /// 将卷按物理盘聚合：同 wholeDisk 去重容量与 IO，供磁盘详情页使用
    static func aggregatePhysicalDisks(from volumes: [DiskDeviceReading]) -> [PhysicalDiskReading] {
        var groups: [(key: String, volumes: [DiskDeviceReading])] = []
        var indexByKey: [String: Int] = [:]

        for volume in volumes {
            let key = volume.wholeDisk ?? volume.mountPath
            if let existing = indexByKey[key] {
                groups[existing].volumes.append(volume)
            } else {
                indexByKey[key] = groups.count
                groups.append((key: key, volumes: [volume]))
            }
        }

        let disks = groups.map { group -> PhysicalDiskReading in
            let vols = group.volumes
            let capacitySource = capacitySourceVolume(in: vols)
            let nameSource = vols.first(where: { $0.mountPath == "/" }) ?? vols[0]
            let primaryMountPath = nameSource.mountPath
            let isInternal = vols.contains(where: \.isInternal)
            let isRemovable = vols.contains(where: \.isRemovable)
            let isEjectable = vols.contains(where: \.isEjectable)
            let io = deduplicatedIO(from: vols)

            return PhysicalDiskReading(
                id: group.key,
                name: nameSource.name,
                wholeDisk: vols.first?.wholeDisk,
                isInternal: isInternal,
                primaryMountPath: primaryMountPath,
                totalBytes: capacitySource.totalBytes,
                freeBytes: capacitySource.freeBytes,
                usedBytes: capacitySource.usedBytes,
                fileSystem: capacitySource.fileSystem ?? vols.lazy.compactMap(\.fileSystem).first,
                smart: vols.lazy.compactMap(\.smart).first,
                readBytesPerSec: io.readBytesPerSec,
                writeBytesPerSec: io.writeBytesPerSec,
                totalReadBytes: io.totalReadBytes,
                totalWrittenBytes: io.totalWrittenBytes,
                volumes: vols,
                isRemovable: isRemovable,
                isEjectable: isEjectable
            )
        }

        return disks.sorted(by: sortPhysicalDisks)
    }

    /// 容量源卷：优先 root，其次 internal，否则 first；total 取组内最大
    private static func capacitySourceVolume(in volumes: [DiskDeviceReading]) -> DiskDeviceReading {
        let maxTotal = volumes.map(\.totalBytes).max() ?? 0
        let candidates = volumes.filter { $0.totalBytes == maxTotal }
        if let root = candidates.first(where: { $0.mountPath == "/" }) {
            return root
        }
        if let internalVolume = candidates.first(where: \.isInternal) {
            return internalVolume
        }
        return candidates.first ?? volumes[0]
    }

    /// 按 ioCounterID / wholeDisk / id 去重后累加 IO
    private static func deduplicatedIO(from volumes: [DiskDeviceReading]) -> (
        readBytesPerSec: Double?,
        writeBytesPerSec: Double?,
        totalReadBytes: UInt64?,
        totalWrittenBytes: UInt64?
    ) {
        var seen = Set<String>()
        var readRate: Double?
        var writeRate: Double?
        var totalRead: UInt64?
        var totalWritten: UInt64?

        for volume in volumes {
            let key = volume.ioCounterID ?? volume.wholeDisk ?? volume.id
            guard seen.insert(key).inserted else { continue }
            if let value = volume.readBytesPerSec {
                readRate = (readRate ?? 0) + value
            }
            if let value = volume.writeBytesPerSec {
                writeRate = (writeRate ?? 0) + value
            }
            if let value = volume.totalReadBytes {
                totalRead = (totalRead ?? 0) + value
            }
            if let value = volume.totalWrittenBytes {
                totalWritten = (totalWritten ?? 0) + value
            }
        }

        return (readRate, writeRate, totalRead, totalWritten)
    }

    private static func sortPhysicalDisks(_ lhs: PhysicalDiskReading, _ rhs: PhysicalDiskReading) -> Bool {
        if lhs.isInternal != rhs.isInternal {
            return lhs.isInternal && !rhs.isInternal
        }
        let lhsHasRoot = lhs.primaryMountPath == "/" || lhs.volumes.contains(where: { $0.mountPath == "/" })
        let rhsHasRoot = rhs.primaryMountPath == "/" || rhs.volumes.contains(where: { $0.mountPath == "/" })
        if lhsHasRoot != rhsHasRoot {
            return lhsHasRoot && !rhsHasRoot
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

extension DiskSupport {
    static func uint(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            let int = number.int64Value
            return int < 0 ? nil : UInt64(int)
        }
        if let string = value as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
