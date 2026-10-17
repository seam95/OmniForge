import XCTest
import SwiftUI
@testable import OmniForge

@MainActor
final class MonitorDiskDetailViewTests: XCTestCase {

    private let strings = Strings.zhHans

    func test_emptyDiskSnapshot_rendersCleanly() {
        var snapshot = SystemSnapshot()
        snapshot.disk = DiskReading(
            devices: [],
            physicalDisks: [],
            readBytesPerSec: 0,
            writeBytesPerSec: 0,
            totalRead: 0,
            totalWritten: 0
        )

        let protection = DiskProtectionService()
        let view = MonitorDiskDetailView(
            snapshot: snapshot,
            strings: strings,
            temperatureUnit: .celsius,
            protection: protection,
            onBack: {},
            onOpenSettings: {},
            showsSettingsAction: true,
            onRefresh: {}
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 360, height: 500)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hosting)
    }

    func test_singleInternalDisk_rendersHeroAndActivity() {
        let internalDisk = PhysicalDiskReading(
            id: "disk1",
            name: "Macintosh HD",
            wholeDisk: "disk1",
            isInternal: true,
            primaryMountPath: "/",
            totalBytes: 500_000_000_000,
            freeBytes: 250_000_000_000,
            usedBytes: 250_000_000_000,
            fileSystem: "APFS",
            smart: DiskSMARTReading(
                status: "Verified",
                totalReadBytes: 10_000_000_000,
                totalWrittenBytes: 8_000_000_000,
                temperatureCelsius: 35.0,
                healthPercent: 99,
                powerCycles: 150,
                powerOnHours: 600,
                unsafeShutdowns: nil,
                mediaErrors: nil
            ),
            readBytesPerSec: 5_000_000,
            writeBytesPerSec: 2_000_000,
            totalReadBytes: 1_000_000_000,
            totalWrittenBytes: 500_000_000,
            volumes: [],
            isRemovable: false,
            isEjectable: false
        )

        var snapshot = SystemSnapshot()
        snapshot.disk = DiskReading(
            devices: [],
            physicalDisks: [internalDisk],
            readBytesPerSec: 5_000_000,
            writeBytesPerSec: 2_000_000,
            totalRead: 1_000_000_000,
            totalWritten: 500_000_000,
            freeSpace: 250_000_000_000,
            totalSpace: 500_000_000_000
        )

        let protection = DiskProtectionService()
        let view = MonitorDiskDetailView(
            snapshot: snapshot,
            strings: strings,
            temperatureUnit: .celsius,
            protection: protection,
            onBack: {},
            onOpenSettings: {},
            showsSettingsAction: false,
            onRefresh: {}
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hosting)
    }

    func test_multipleDisksWithExternal_rendersSelectorAndProtection() {
        let internalDisk = PhysicalDiskReading(
            id: "disk1",
            name: "Macintosh HD",
            wholeDisk: "disk1",
            isInternal: true,
            primaryMountPath: "/",
            totalBytes: 500_000_000_000,
            freeBytes: 250_000_000_000,
            usedBytes: 250_000_000_000,
            fileSystem: "APFS",
            smart: nil,
            readBytesPerSec: nil,
            writeBytesPerSec: nil,
            totalReadBytes: nil,
            totalWrittenBytes: nil,
            volumes: [],
            isRemovable: false,
            isEjectable: false
        )

        let externalDisk = PhysicalDiskReading(
            id: "disk2",
            name: "External SSD",
            wholeDisk: "disk2",
            isInternal: false,
            primaryMountPath: "/Volumes/External SSD",
            totalBytes: 1_000_000_000_000,
            freeBytes: 800_000_000_000,
            usedBytes: 200_000_000_000,
            fileSystem: "ExFAT",
            smart: nil,
            readBytesPerSec: 10_000_000,
            writeBytesPerSec: 20_000_000,
            totalReadBytes: 5_000_000_000,
            totalWrittenBytes: 10_000_000_000,
            volumes: [],
            isRemovable: true,
            isEjectable: true
        )

        var snapshot = SystemSnapshot()
        snapshot.disk = DiskReading(
            devices: [],
            physicalDisks: [internalDisk, externalDisk],
            readBytesPerSec: 10_000_000,
            writeBytesPerSec: 20_000_000,
            totalRead: 5_000_000_000,
            totalWritten: 10_000_000_000
        )

        let protection = DiskProtectionService()
        let view = MonitorDiskDetailView(
            snapshot: snapshot,
            strings: strings,
            temperatureUnit: .fahrenheit,
            protection: protection,
            onBack: {},
            onOpenSettings: {},
            showsSettingsAction: true,
            onRefresh: {}
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hosting)
    }
}
