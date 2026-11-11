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

    func test_accumulateShortIntervalKeepsSessionAndNilRates() {
        // 补采与定时 tick 背靠背时 elapsed 过短：速率作废（防尖刺），
        // 但会话累计不得清零（样本仍在有效窗口内，只是间隔太短）
        let result = DiskSampler.accumulate(
            previous: .init(read: 100, written: 50),
            current: .init(read: 300, written: 150),
            session: .init(read: 1000, written: 500),
            elapsed: 0.1,
            maxGap: 15
        )
        XCTAssertNil(result.rates.read)
        XCTAssertNil(result.rates.write)
        XCTAssertEqual(result.session.read, 1000)
        XCTAssertEqual(result.session.written, 500)
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

    // MARK: - runDiskutilInfo: 有界执行器边界

    func test_runDiskutilInfo_passesCommandAndTimeoutToBoundedRunner() throws {
        // 命令拼接保持不变：diskutil info -plist <mountPath>，且必须带 8s 超时
        var capturedExecutable: URL?
        var capturedArguments: [String]?
        var capturedOptions: BoundedProcessRunner.Options?
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DeviceIdentifier</key>
            <string>disk3s5</string>
            <key>Internal</key>
            <true/>
        </dict>
        </plist>
        """
        let dict = try XCTUnwrap(DiskSampler.runDiskutilInfo("/Volumes/Data") { executable, arguments, options in
            capturedExecutable = executable
            capturedArguments = arguments
            capturedOptions = options
            return BoundedProcessOutput(exitCode: 0, stdout: plistXML, stderr: "", truncated: false)
        })
        XCTAssertEqual(capturedExecutable?.path, "/usr/sbin/diskutil")
        XCTAssertEqual(capturedArguments, ["info", "-plist", "/Volumes/Data"])
        XCTAssertEqual(capturedOptions?.timeout, 8, "diskutil 必须经带超时执行器，子进程挂起时由其 SIGKILL 回收")
        XCTAssertEqual(dict["DeviceIdentifier"] as? String, "disk3s5")
        XCTAssertEqual(dict["Internal"] as? Bool, true)
    }

    func test_runDiskutilInfo_returnsNilWhenRunnerFailsTimesOutOrOutputInvalid() {
        // 启动失败（nil）与超时 SIGKILL（退出码 9）都返回 nil：不抛错、不挂起，采样走空 metadata 回退
        XCTAssertNil(DiskSampler.runDiskutilInfo("/") { _, _, _ in nil })
        XCTAssertNil(DiskSampler.runDiskutilInfo("/") { _, _, _ in
            BoundedProcessOutput(exitCode: 9, stdout: "", stderr: "", truncated: false)
        })
        // 输出不是合法 plist 时同样返回 nil
        XCTAssertNil(DiskSampler.runDiskutilInfo("/") { _, _, _ in
            BoundedProcessOutput(exitCode: 0, stdout: "not-a-plist", stderr: "", truncated: false)
        })
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

    // MARK: - 元数据 stale-while-revalidate

    func test_needsMetadataRefresh_rules() {
        // 无缓存：恒需刷新
        XCTAssertTrue(DiskSampler.needsMetadataRefresh(cachedAt: nil, isFull: true, now: 100, isForeground: true))
        // 前台：30s 内不刷新，达到 30s 即刷新
        XCTAssertFalse(DiskSampler.needsMetadataRefresh(cachedAt: 70, isFull: true, now: 99.9, isForeground: true))
        XCTAssertTrue(DiskSampler.needsMetadataRefresh(cachedAt: 70, isFull: true, now: 100, isForeground: true))
        // 后台 isFull 缓存：3600s 内可复用（3599 未过期，达到 3600 即刷新）
        XCTAssertFalse(DiskSampler.needsMetadataRefresh(cachedAt: 100, isFull: true, now: 3699, isForeground: false))
        XCTAssertTrue(DiskSampler.needsMetadataRefresh(cachedAt: 100, isFull: true, now: 3700, isForeground: false))
        // 后台失败缓存（isFull=false）：不获长缓存，立即过期重试
        XCTAssertTrue(DiskSampler.needsMetadataRefresh(cachedAt: 100, isFull: false, now: 101, isForeground: false))
    }

    /// 线程安全的 runner 调用记录：diskutil 在元数据队列被异步调用
    private final class DiskutilCallCounter {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ arguments: [String]) {
            lock.withLock { calls.append(arguments) }
        }
        var count: Int { lock.withLock { calls.count } }
    }

    private static let metadataPlistXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>DeviceIdentifier</key>
        <string>disk3s5</string>
        <key>Internal</key>
        <true/>
    </dict>
    </plist>
    """

    func test_metadataFirstSampleDoesNotBlockAndCachesAsync() throws {
        let counter = DiskutilCallCounter()
        let sampler = DiskSampler(diskutilRunner: { _, _, _ in
            counter.record(["info"])
            return BoundedProcessOutput(exitCode: 0, stdout: Self.metadataPlistXML, stderr: "", truncated: false)
        })
        // 首次采样：无缓存，sample 立即返回回退元数据，diskutil 异步执行
        let start = Date()
        let reading = try sampler.sample(now: 10, refreshMetadata: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "sample 不得同步等待 diskutil")
        XCTAssertFalse(reading.devices.isEmpty)

        // 异步落缓存（isFull=true）
        let cached = expectation(for: NSPredicate { _, _ in
            sampler.hasCachedMetadata("/", isFull: true)
        }, evaluatedWith: nil)
        wait(for: [cached], timeout: 3)

        // 30s 阈值内再次采样：不再发起新刷新
        _ = try sampler.sample(now: 11, refreshMetadata: true)
        XCTAssertEqual(counter.count, 1)

        // 缓存过期后再次采样：重新发起刷新
        _ = try sampler.sample(now: 51, refreshMetadata: true)
        let refreshed = expectation(for: NSPredicate { _, _ in
            counter.count >= 2
        }, evaluatedWith: nil)
        wait(for: [refreshed], timeout: 3)
    }

    func test_metadataRefreshDedupesInFlightRequests() throws {
        let counter = DiskutilCallCounter()
        let sampler = DiskSampler(diskutilRunner: { _, _, _ in
            counter.record(["info"])
            Thread.sleep(forTimeInterval: 0.3) // 拉长在途窗口
            return BoundedProcessOutput(exitCode: 0, stdout: Self.metadataPlistXML, stderr: "", truncated: false)
        })
        // 第一次触发刷新（在途）；紧接着的过期采样必须被在途去重挡下
        _ = try sampler.sample(now: 10, refreshMetadata: true)
        _ = try sampler.sample(now: 100, refreshMetadata: true)

        let done = expectation(for: NSPredicate { _, _ in
            counter.count >= 1 && sampler.hasCachedMetadata("/", isFull: true)
        }, evaluatedWith: nil)
        wait(for: [done], timeout: 3)
        // 在途期间的第二次采样不得重复发起（留出迟到调用观察窗）
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(counter.count, 1, "同一卷的 diskutil 在途期间不得重复发起")
    }
}
