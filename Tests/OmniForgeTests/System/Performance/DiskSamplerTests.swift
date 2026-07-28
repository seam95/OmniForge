import XCTest
@testable import OmniForge

final class DiskSamplerTests: XCTestCase {
    func test_diskReadingExposesDevices() {
        let device = DiskDeviceReading(
            id: "/", name: "Macintosh HD", mountPath: "/",
            totalBytes: 1_000_000_000_000, freeBytes: 200_000_000_000, usedBytes: 800_000_000_000,
            isInternal: true, readBytesPerSec: 0, writeBytesPerSec: 0,
            totalReadBytes: 0, totalWrittenBytes: 0
        )
        let reading = DiskReading(
            devices: [device],
            readBytesPerSec: 0, writeBytesPerSec: 0,
            totalRead: 0, totalWritten: 0,
            freeSpace: device.freeBytes, totalSpace: device.totalBytes
        )
        XCTAssertEqual(reading.devices.count, 1)
        XCTAssertEqual(reading.freeSpace, 200_000_000_000)
        XCTAssertEqual(reading.devices[0].usedBytes, 800_000_000_000)
    }

    func test_diskSamplerFirstSampleNoRates() throws {
        let sampler = DiskSampler()
        let reading = try sampler.sample(now: 10, refreshMetadata: true)
        XCTAssertEqual(reading.readBytesPerSec, 0)
        XCTAssertEqual(reading.writeBytesPerSec, 0)
        XCTAssertNotNil(reading.totalSpace)
        XCTAssertFalse(reading.devices.isEmpty, "sample should enumerate mounted volumes")
        XCTAssertTrue(reading.devices.contains(where: { $0.mountPath == "/" }))
        let rootFree = reading.devices.first(where: { $0.mountPath == "/" })?.freeBytes
        XCTAssertEqual(reading.freeSpace, rootFree)
    }

    func test_sessionTotalsAccumulateAcrossSamples() throws {
        let sampler = DiskSampler()
        let t1 = try sampler.sample(now: 1, refreshMetadata: true)
        // 第一次无速率
        XCTAssertEqual(t1.readBytesPerSec, 0)
        // 连续采样后 totals 应单调不减
        let t2 = try sampler.sample(now: 3, refreshMetadata: false)
        let t3 = try sampler.sample(now: 5, refreshMetadata: false)
        XCTAssertGreaterThanOrEqual(t3.totalRead, t2.totalRead)
        XCTAssertGreaterThanOrEqual(t3.totalWritten, t2.totalWritten)
    }

    func test_accumulateUsesSessionNotDeltaAsTotals() {
        let result = DiskSampler.accumulate(
            previous: .init(read: 100, written: 50),
            current: .init(read: 300, written: 150),
            session: .init(read: 1000, written: 500),
            elapsed: 2,
            maxGap: 15
        )
        XCTAssertEqual(result.session.read, 1200)
        XCTAssertEqual(result.session.written, 600)
        XCTAssertEqual(result.rates.read, 100)
        XCTAssertEqual(result.rates.write, 50)
    }

    func test_accumulateResetsSessionWhenGapExceeded() {
        let result = DiskSampler.accumulate(
            previous: .init(read: 100, written: 50),
            current: .init(read: 300, written: 150),
            session: .init(read: 1000, written: 500),
            elapsed: 20,
            maxGap: 15
        )
        XCTAssertEqual(result.session.read, 0)
        XCTAssertEqual(result.session.written, 0)
        XCTAssertNil(result.rates.read)
        XCTAssertNil(result.rates.write)
    }

    func test_accumulateResetsSessionWhenPreviousMissing() {
        let result = DiskSampler.accumulate(
            previous: nil,
            current: .init(read: 300, written: 150),
            session: .init(read: 1000, written: 500),
            elapsed: 2,
            maxGap: 15
        )
        XCTAssertEqual(result.session.read, 0)
        XCTAssertEqual(result.session.written, 0)
        XCTAssertNil(result.rates.read)
        XCTAssertNil(result.rates.write)
    }

    func test_diskSampler_populatesPhysicalDisks() throws {
        let sampler = DiskSampler()
        let reading = try sampler.sample(now: 10, refreshMetadata: true)
        XCTAssertFalse(reading.devices.isEmpty)
        XCTAssertFalse(reading.physicalDisks.isEmpty)
        // 同 wholeDisk 的卷不应导致 physicalDisks 数 > devices 数
        XCTAssertLessThanOrEqual(reading.physicalDisks.count, reading.devices.count)
    }

    func test_bestCapacity_keepsVolumeFreeZeroAsFullDisk() {
        let volume = DiskSupport.MountedVolume(
            name: "Full",
            mountPath: "/",
            totalBytes: 1000,
            freeBytes: 0,
            usedBytes: 1000,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            bsdName: "disk0s2"
        )
        var metadata = DiskSupport.DiskutilMetadata()
        metadata.totalBytes = 2000
        metadata.freeBytes = 500
        metadata.usedBytes = 1500

        let capacity = DiskSampler.bestCapacity(volume: volume, metadata: metadata)
        XCTAssertEqual(capacity.total, 1000)
        XCTAssertEqual(capacity.free, 0)
        XCTAssertEqual(capacity.used, 1000)
    }

    func test_bestCapacity_usesMetadataOnlyWhenVolumeTotalMissing() {
        let volume = DiskSupport.MountedVolume(
            name: "Unknown",
            mountPath: "/Volumes/X",
            totalBytes: 0,
            freeBytes: 0,
            usedBytes: 0,
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            bsdName: "disk4s1"
        )
        var metadata = DiskSupport.DiskutilMetadata()
        metadata.totalBytes = 2000
        metadata.freeBytes = 500
        metadata.usedBytes = 1500

        let capacity = DiskSampler.bestCapacity(volume: volume, metadata: metadata)
        XCTAssertEqual(capacity.total, 2000)
        XCTAssertEqual(capacity.free, 500)
        XCTAssertEqual(capacity.used, 1500)
    }
}
