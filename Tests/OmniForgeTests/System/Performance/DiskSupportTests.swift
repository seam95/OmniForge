import XCTest
@testable import OmniForge

final class DiskSupportTests: XCTestCase {
    func test_nvmeTemperatureConvertsKelvinToCelsius() {
        XCTAssertEqual(DiskSupport.celsius(fromSMARTTemperature: 303), 29.85, accuracy: 0.01)
    }

    func test_nvmeBytesCombinesHighLow() {
        // Align with Vorssaint DiskSupport.nvmeBytes (512_000 bytes per data unit)
        let bytes = DiskSupport.nvmeBytes(low: 2, high: 0)
        XCTAssertEqual(bytes, 2 * 512_000)
    }

    func test_nvmeBytesUsesHighWord() {
        let bytes = DiskSupport.nvmeBytes(low: 1, high: 1)
        XCTAssertEqual(bytes, (1 + (1 << 32)) * 512_000)
    }

    func test_healthPercentFromPercentageUsed() {
        XCTAssertEqual(DiskSupport.healthPercent(fromPercentageUsed: 12), 88)
        XCTAssertEqual(DiskSupport.healthPercent(fromPercentageUsed: 0), 100)
        XCTAssertEqual(DiskSupport.healthPercent(fromPercentageUsed: 150), 0)
        XCTAssertNil(DiskSupport.healthPercent(fromPercentageUsed: nil))
    }

    func test_mountedVolumesReturnsRoot() {
        let volumes = DiskSupport.mountedVolumes()
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertTrue(volumes.contains(where: { $0.mountPath == "/" }))
        let root = volumes.first(where: { $0.mountPath == "/" })!
        XCTAssertGreaterThan(root.totalBytes, 0)
        XCTAssertGreaterThan(root.freeBytes, 0)
        XCTAssertEqual(root.usedBytes, root.totalBytes - min(root.freeBytes, root.totalBytes))
    }

    func test_ioCounterResetReturnsNilRates() {
        let speed = DiskSupport.speed(
            previous: .init(read: 200, written: 100),
            current: .init(read: 10, written: 5),
            elapsed: 2
        )
        XCTAssertNil(speed.read)
        XCTAssertNil(speed.write)
    }

    func test_ioCounterNormalReturnsRates() {
        let speed = DiskSupport.speed(
            previous: .init(read: 100, written: 50),
            current: .init(read: 300, written: 150),
            elapsed: 2
        )
        XCTAssertEqual(speed.read, 100)
        XCTAssertEqual(speed.write, 50)
    }

    func test_freeSpaceNonNil() {
        let free = DiskSupport.freeSpace()
        XCTAssertNotNil(free)
        XCTAssertGreaterThan(free ?? 0, 0)
    }

    // MARK: - wholeDiskBSDName（多卷同盘去重核心）

    func test_wholeDiskBSDName_normalizesSliceToWhole() {
        // APFS 多卷共享同一物理盘：slice 名归一为整盘名
        XCTAssertEqual(DiskSupport.wholeDiskBSDName(from: "disk1s1"), "disk1")
        XCTAssertEqual(DiskSupport.wholeDiskBSDName(from: "disk1s1s1"), "disk1")
        XCTAssertEqual(DiskSupport.wholeDiskBSDName(from: "disk0s2"), "disk0")
    }

    func test_wholeDiskBSDName_keepsAlreadyWhole() {
        // 已是整盘名时原样返回
        XCTAssertEqual(DiskSupport.wholeDiskBSDName(from: "disk2"), "disk2")
        XCTAssertEqual(DiskSupport.wholeDiskBSDName(from: "disk10"), "disk10")
    }

    func test_wholeDiskBSDName_stripsDevPrefix() {
        XCTAssertEqual(DiskSupport.wholeDiskBSDName(from: "/dev/disk1s1"), "disk1")
    }

    func test_wholeDiskBSDName_rejectsInvalidInput() {
        XCTAssertNil(DiskSupport.wholeDiskBSDName(from: nil))
        XCTAssertNil(DiskSupport.wholeDiskBSDName(from: ""))
        XCTAssertNil(DiskSupport.wholeDiskBSDName(from: "nvme0n1"))
        XCTAssertNil(DiskSupport.wholeDiskBSDName(from: "disk"))  // 无数字
    }

    // MARK: - SMART 解析

    func test_smartReading_parsesNVMeVendorKeys() {
        let keys: [String: Any] = [
            "DATA_UNITS_READ_0": NSNumber(value: 2),
            "DATA_UNITS_READ_1": NSNumber(value: 0),
            "DATA_UNITS_WRITTEN_0": NSNumber(value: 4),
            "DATA_UNITS_WRITTEN_1": NSNumber(value: 0),
            "TEMPERATURE": NSNumber(value: 40),
            "PERCENTAGE_USED": NSNumber(value: 5),
            "POWER_CYCLES_0": NSNumber(value: 10),
            "POWER_ON_HOURS_0": NSNumber(value: 100),
        ]
        let smart = DiskSupport.smartReading(status: "Verified", vendorKeys: keys)
        XCTAssertEqual(smart?.status, "Verified")
        XCTAssertEqual(smart?.totalReadBytes, 2 * 512_000)
        XCTAssertEqual(smart?.totalWrittenBytes, 4 * 512_000)
        XCTAssertEqual(smart?.temperatureCelsius ?? -1, 40, accuracy: 0.01)
        XCTAssertEqual(smart?.healthPercent, 95)
        XCTAssertEqual(smart?.powerCycles, 10)
        XCTAssertEqual(smart?.powerOnHours, 100)
    }

    func test_smartReading_returnsNilWhenEmpty() {
        XCTAssertNil(DiskSupport.smartReading(status: nil, vendorKeys: nil))
        XCTAssertNil(DiskSupport.smartReading(status: "", vendorKeys: [:]))
    }

    func test_smartReading_kelvinTemperature() {
        let smart = DiskSupport.smartReading(
            status: "Verified",
            vendorKeys: ["TEMPERATURE": NSNumber(value: 313)]
        )
        XCTAssertEqual(smart?.temperatureCelsius ?? -1, 39.85, accuracy: 0.01)
    }

    // MARK: - 物理盘聚合

    func test_aggregatePhysicalDisks_mergesSameWholeDisk() {
        let v1 = DiskDeviceReading(
            id: "/", name: "Data", mountPath: "/",
            bsdName: "disk3s1", wholeDisk: "disk0", ioCounterID: "disk0",
            totalBytes: 500_000_000_000, freeBytes: 200_000_000_000, usedBytes: 300_000_000_000,
            isInternal: true, isRemovable: false, isEjectable: false,
            fileSystem: "APFS", smart: DiskSMARTReading(status: "Verified"),
            readBytesPerSec: 100, writeBytesPerSec: 50,
            totalReadBytes: 1000, totalWrittenBytes: 500
        )
        let v2 = DiskDeviceReading(
            id: "/System/Volumes/Data", name: "Data", mountPath: "/System/Volumes/Data",
            bsdName: "disk3s5", wholeDisk: "disk0", ioCounterID: "disk0",
            totalBytes: 500_000_000_000, freeBytes: 200_000_000_000, usedBytes: 300_000_000_000,
            isInternal: true, isRemovable: false, isEjectable: false,
            fileSystem: "APFS", smart: nil,
            readBytesPerSec: 100, writeBytesPerSec: 50,
            totalReadBytes: 1000, totalWrittenBytes: 500
        )
        let disks = DiskSupport.aggregatePhysicalDisks(from: [v1, v2])
        XCTAssertEqual(disks.count, 1)
        XCTAssertEqual(disks[0].id, "disk0")
        XCTAssertEqual(disks[0].totalBytes, 500_000_000_000) // 不双计
        XCTAssertEqual(disks[0].readBytesPerSec, 100) // IO 去重
        XCTAssertEqual(disks[0].smart?.status, "Verified")
        XCTAssertEqual(disks[0].primaryMountPath, "/")
        XCTAssertFalse(disks[0].canEject)
    }

    func test_aggregatePhysicalDisks_externalCanEject() {
        let ext = DiskDeviceReading(
            id: "/Volumes/USB", name: "USB", mountPath: "/Volumes/USB",
            bsdName: "disk4s1", wholeDisk: "disk4", ioCounterID: "disk4",
            totalBytes: 64_000_000_000, freeBytes: 10_000_000_000, usedBytes: 54_000_000_000,
            isInternal: false, isRemovable: true, isEjectable: true,
            fileSystem: nil, smart: nil,
            readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: 0, totalWrittenBytes: 0
        )
        let disks = DiskSupport.aggregatePhysicalDisks(from: [ext])
        XCTAssertEqual(disks.count, 1)
        XCTAssertTrue(disks[0].canEject)
        XCTAssertEqual(disks[0].ejectBSDName, "disk4")
    }

    func test_aggregatePhysicalDisks_sortsInternalAndRootFirst() {
        let ext = DiskDeviceReading(
            id: "/Volumes/USB", name: "USB", mountPath: "/Volumes/USB",
            bsdName: "disk4s1", wholeDisk: "disk4", ioCounterID: "disk4",
            totalBytes: 1, freeBytes: 0, usedBytes: 1,
            isInternal: false, isRemovable: true, isEjectable: true,
            fileSystem: nil, smart: nil,
            readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil
        )
        let root = DiskDeviceReading(
            id: "/", name: "Macintosh HD", mountPath: "/",
            bsdName: "disk3s1", wholeDisk: "disk0", ioCounterID: "disk0",
            totalBytes: 1, freeBytes: 0, usedBytes: 1,
            isInternal: true, isRemovable: false, isEjectable: false,
            fileSystem: nil, smart: nil,
            readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil
        )
        let disks = DiskSupport.aggregatePhysicalDisks(from: [ext, root])
        XCTAssertEqual(disks.map(\.id), ["disk0", "disk4"])
    }

    // MARK: - diskutil 元数据解析

    func test_metadataFromDiskutilInfo_mapsPhysicalStoreAndSMART() {
        let info: [String: Any] = [
            "DeviceIdentifier": "disk3s1",
            "ParentWholeDisk": "disk3",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
            "APFSContainerSize": NSNumber(value: 500_000_000_000),
            "APFSContainerFree": NSNumber(value: 200_000_000_000),
            "FilesystemType": "apfs",
            "MediaName": "APPLE SSD",
            "Internal": true,
            "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "PERCENTAGE_USED": NSNumber(value: 5),
                "TEMPERATURE": NSNumber(value: 40),
            ] as [String: Any],
        ]
        let meta = DiskSupport.metadata(fromDiskutilInfo: info)
        XCTAssertEqual(meta.wholeDisk, "disk0")
        XCTAssertEqual(meta.mediaName, "APPLE SSD")
        XCTAssertEqual(meta.fileSystem?.uppercased(), "APFS")
        XCTAssertEqual(meta.smart?.status, "Verified")
        XCTAssertEqual(meta.smart?.healthPercent, 95)
        XCTAssertTrue(meta.ioCounterIDs.contains("disk0"))
    }

    func test_metadataFromDiskutilInfo_externalIOPriorityUsesBSDFirst() {
        let info: [String: Any] = [
            "DeviceIdentifier": "disk4s1",
            "ParentWholeDisk": "disk4",
            "Internal": false,
            "Removable": true,
            "Ejectable": true,
            "MediaName": "USB Drive",
            "FilesystemName": "ExFAT",
        ]
        let meta = DiskSupport.metadata(fromDiskutilInfo: info)
        XCTAssertEqual(meta.wholeDisk, "disk4")
        XCTAssertEqual(meta.bsdName, "disk4s1")
        XCTAssertEqual(meta.isInternal, false)
        XCTAssertEqual(meta.isRemovable, true)
        XCTAssertEqual(meta.isEjectable, true)
        // 外置：io 候选优先 bsdName
        XCTAssertEqual(meta.ioCounterIDs.first, "disk4s1")
        XCTAssertTrue(meta.ioCounterIDs.contains("disk4"))
        XCTAssertEqual(meta.fileSystem, "ExFAT")
        XCTAssertEqual(meta.mediaName, "USB Drive")
    }

    func test_metadataFromDiskutilInfo_doesNotUseDeviceNodeAsMediaName() {
        let info: [String: Any] = [
            "DeviceIdentifier": "disk0s2",
            "DeviceNode": "/dev/disk0s2",
            "IORegistryEntryName": "disk0s2",
            "Internal": true,
        ]
        let meta = DiskSupport.metadata(fromDiskutilInfo: info)
        XCTAssertNil(meta.mediaName)
    }

    func test_metadataFromDiskutilInfo_acceptsReasonableIORegistryEntryName() {
        let info: [String: Any] = [
            "DeviceIdentifier": "disk0s2",
            "IORegistryEntryName": "APPLE SSD AP0512Z",
            "Internal": true,
        ]
        let meta = DiskSupport.metadata(fromDiskutilInfo: info)
        XCTAssertEqual(meta.mediaName, "APPLE SSD AP0512Z")
    }
}
