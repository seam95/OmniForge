import XCTest
@testable import OmniForge

final class DiskProtectionServiceTests: XCTestCase {
    func test_uniqueEjectableDisks_dedupesByEjectBSDName() {
        let a = PhysicalDiskReading(
            id: "disk4", name: "USB", wholeDisk: "disk4", isInternal: false,
            primaryMountPath: "/Volumes/A", totalBytes: 1, freeBytes: 0, usedBytes: 1,
            fileSystem: nil, smart: nil, readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil, volumes: [],
            isRemovable: true, isEjectable: true
        )
        let b = PhysicalDiskReading(
            id: "disk4-vol2", name: "USB2", wholeDisk: "disk4", isInternal: false,
            primaryMountPath: "/Volumes/B", totalBytes: 1, freeBytes: 0, usedBytes: 1,
            fileSystem: nil, smart: nil, readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil, volumes: [],
            isRemovable: true, isEjectable: true
        )
        let internalDisk = PhysicalDiskReading(
            id: "disk0", name: "SSD", wholeDisk: "disk0", isInternal: true,
            primaryMountPath: "/", totalBytes: 1, freeBytes: 0, usedBytes: 1,
            fileSystem: nil, smart: nil, readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil, volumes: [],
            isRemovable: false, isEjectable: false
        )
        let unique = DiskProtectionService.uniqueEjectableDisks(from: [a, b, internalDisk])
        XCTAssertEqual(unique.map(\.ejectBSDName), ["disk4"])
    }

    func test_uniqueEjectableDisks_keepsDistinctEjectBSDNames() {
        let usb = PhysicalDiskReading(
            id: "disk4", name: "USB", wholeDisk: "disk4", isInternal: false,
            primaryMountPath: "/Volumes/A", totalBytes: 1, freeBytes: 0, usedBytes: 1,
            fileSystem: nil, smart: nil, readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil, volumes: [],
            isRemovable: true, isEjectable: true
        )
        let sd = PhysicalDiskReading(
            id: "disk5", name: "SD", wholeDisk: "disk5", isInternal: false,
            primaryMountPath: "/Volumes/SD", totalBytes: 1, freeBytes: 0, usedBytes: 1,
            fileSystem: nil, smart: nil, readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil, volumes: [],
            isRemovable: true, isEjectable: true
        )
        let unique = DiskProtectionService.uniqueEjectableDisks(from: [usb, sd])
        XCTAssertEqual(unique.map(\.ejectBSDName), ["disk4", "disk5"])
    }

    func test_uniqueEjectableDisks_skipsNonEjectable() {
        let internalDisk = PhysicalDiskReading(
            id: "disk0", name: "SSD", wholeDisk: "disk0", isInternal: true,
            primaryMountPath: "/", totalBytes: 1, freeBytes: 0, usedBytes: 1,
            fileSystem: nil, smart: nil, readBytesPerSec: nil, writeBytesPerSec: nil,
            totalReadBytes: nil, totalWrittenBytes: nil, volumes: [],
            isRemovable: false, isEjectable: false
        )
        let unique = DiskProtectionService.uniqueEjectableDisks(from: [internalDisk])
        XCTAssertTrue(unique.isEmpty)
    }
}
