import XCTest
import AppKit
@testable import OmniForge

final class MenuBarMetricRendererTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 每个用例从干净水位开始，避免 compact 会话状态串扰
        MenuBarMetricLayout.resetCompactHighWaterForTesting()
    }

    func test_memoryStyle_percent_used_and_pressure() {
        var snapshot = SystemSnapshot()
        snapshot.memoryUsed = 2_000_000_000
        snapshot.memoryTotal = 8_000_000_000
        snapshot.memoryPressure = .warning

        var config = MonitorConfiguration()
        config.menuBarMemoryStyle = .percent
        let percentBlock = firstBlock(for: snapshot, metrics: [.memory], configuration: config)
        XCTAssertEqual(percentBlock.label, "RAM")
        XCTAssertEqual(percentBlock.value, "25%")
        XCTAssertEqual(percentBlock.minimumValue, "100%")

        config.menuBarMemoryStyle = .used
        let usedBlock = firstBlock(for: snapshot, metrics: [.memory], configuration: config)
        XCTAssertEqual(usedBlock.value, "1.9 GB")

        config.menuBarMemoryStyle = .pressure
        let pressureBlock = firstBlock(for: snapshot, metrics: [.memory], configuration: config)
        XCTAssertEqual(pressureBlock.value, "WARN")
    }

    func test_network_uploadFirst_ordersUploadBeforeDownload() {
        var snapshot = SystemSnapshot()
        snapshot.netDownBytesPerSec = 1_500_000
        snapshot.netUpBytesPerSec = 500_000

        var config = MonitorConfiguration()
        config.networkUploadFirst = false
        let downloadFirst = firstBlock(for: snapshot, metrics: [.network], configuration: config)
        XCTAssertEqual(downloadFirst.value, "↓1.4 MB/s")
        XCTAssertEqual(downloadFirst.secondaryValue, "↑488 KB/s")

        config.networkUploadFirst = true
        let uploadFirst = firstBlock(for: snapshot, metrics: [.network], configuration: config)
        XCTAssertEqual(uploadFirst.value, "↑488 KB/s")
        XCTAssertEqual(uploadFirst.secondaryValue, "↓1.4 MB/s")
    }

    func test_attributedTitle_joinsConfiguredGroups() {
        var snapshot = SystemSnapshot()
        snapshot.memoryUsed = 1_000_000_000
        snapshot.memoryTotal = 4_000_000_000
        snapshot.netDownBytesPerSec = 1_000
        snapshot.netUpBytesPerSec = 2_000

        var config = MonitorConfiguration()
        config.menuBarMemoryStyle = .percent
        config.networkUploadFirst = true
        config.menuBarSpacing = .compact

        let title = MenuBarMetricRenderer.attributedTitle(
            for: snapshot,
            metrics: [.memory, .network],
            configuration: config
        )
        // attachment 路径：长度 > 0 且宽度随双块 + spacer 增加
        XCTAssertGreaterThan(title.length, 0)
        XCTAssertGreaterThan(title.size().width, 0)

        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.memory, .network],
            configuration: config
        )
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].label, "RAM")
        XCTAssertEqual(blocks[0].value, "25%")
        XCTAssertEqual(blocks[1].label, "NET")
        XCTAssertEqual(blocks[1].value, "↑2.0 KB/s")
        XCTAssertEqual(blocks[1].secondaryValue, "↓1000 B/s")
    }

    /// 占位机制：会话内位数高水位——同位数宽度稳定、位数首次跨越变宽一次后回落仍稳定
    func test_metricBlockWidth_isStableWithinDigitWatermark() {
        MenuBarMetricLayout.resetCompactHighWaterForTesting()

        // 同位数（2 位）：9% 与 42% 宽度一致，秒级数值刷新不推挤相邻图标
        let nine = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "9%",
            minimumValue: "100%",
            spacing: .standard
        )
        let fortyTwo = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "42%",
            minimumValue: "100%",
            spacing: .standard
        )
        XCTAssertEqual(nine.size.width, fortyTwo.size.width, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(nine.size.width, MenuBarMetricLayout.minItemWidth)

        // 跨位数（100% 首次出现 3 位）：块变宽一次
        let hundred = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "100%",
            minimumValue: "100%",
            spacing: .standard
        )
        XCTAssertGreaterThan(hundred.size.width, nine.size.width)

        // 回落 2 位：保持 3 位峰宽（水位单调不减），此后不再跳变
        let nineAgain = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "9%",
            minimumValue: "100%",
            spacing: .standard
        )
        XCTAssertEqual(nineAgain.size.width, hundred.size.width, accuracy: 1.0)
    }

    func test_combineTemperatures_doesNotAppendTempUnlessTemperatureMetricEnabled() {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = CPUUsageReading(total: 0.42, user: 0.3, system: 0.12)
        snapshot.gpuUsage = 0.18
        snapshot.cpuTemperature = 55
        snapshot.gpuTemperature = 48

        var config = MonitorConfiguration()
        config.combineTemperatures = true

        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.cpu, .gpu],
            configuration: config
        )

        XCTAssertEqual(blocks.map(\.label), ["CPU", "GPU"])
        XCTAssertEqual(blocks[0].value, "42%")
        XCTAssertEqual(blocks[1].value, "18%")
    }

    func test_combineTemperatures_appendsTempOnlyWhenTemperatureMetricEnabled() {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = CPUUsageReading(total: 0.42, user: 0.3, system: 0.12)
        snapshot.gpuUsage = 0.18
        snapshot.cpuTemperature = 55
        snapshot.gpuTemperature = 48

        var config = MonitorConfiguration()
        config.combineTemperatures = true

        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.cpu, .cpuTemperature, .gpu, .gpuTemperature],
            configuration: config
        )

        // 合并后只保留 CPU/GPU 块，温度并入 value，不再单独出 CPU°/GPU°
        XCTAssertEqual(blocks.map(\.label), ["CPU", "GPU"])
        XCTAssertEqual(blocks[0].value, "42% 55°")
        XCTAssertEqual(blocks[1].value, "18% 48°")
    }

    func test_combineTemperatures_off_keepsSeparateTemperatureBlocks() {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = CPUUsageReading(total: 0.42, user: 0.3, system: 0.12)
        snapshot.cpuTemperature = 55

        var config = MonitorConfiguration()
        config.combineTemperatures = false

        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.cpu, .cpuTemperature],
            configuration: config
        )

        XCTAssertEqual(blocks.map(\.label), ["CPU", "CPU°"])
        XCTAssertEqual(blocks[0].value, "42%")
        XCTAssertEqual(blocks[1].value, "55°")
    }

    func test_layoutSpacingConstants_matchExpected() {
        XCTAssertEqual(MenuBarMetricLayout.compactSpacing, 2)
        XCTAssertEqual(MenuBarMetricLayout.standardSpacing, 2)
        XCTAssertEqual(MenuBarMetricLayout.minItemWidth, 28)
    }

    func test_disk_usesAggregateFreeSpaceWithDiskBytes() {
        var snapshot = SystemSnapshot()
        snapshot.disk = DiskReading(
            devices: [
                DiskDeviceReading(
                    id: "/", name: "Macintosh HD", mountPath: "/",
                    totalBytes: 1_000_000_000_000, freeBytes: 250_000_000_000, usedBytes: 750_000_000_000,
                    isInternal: true, readBytesPerSec: 0, writeBytesPerSec: 0,
                    totalReadBytes: 0, totalWrittenBytes: 0
                )
            ],
            readBytesPerSec: 0, writeBytesPerSec: 0,
            totalRead: 0, totalWritten: 0,
            freeSpace: 250_000_000_000, totalSpace: 1_000_000_000_000
        )
        let block = firstBlock(for: snapshot, metrics: [.disk], configuration: MonitorConfiguration())
        XCTAssertEqual(block.label, "DSK")
        XCTAssertEqual(block.value, MetricFormat.diskBytes(250_000_000_000))
    }

    func test_compactReserve_padsToAtLeastTwoDigits() {
        MenuBarMetricLayout.resetCompactHighWaterForTesting()
        let reserve = MenuBarMetricLayout.compactReserve(label: "CPU", value: "9%")
        // 1 位 → 补到 2 位 "88%"
        XCTAssertEqual(reserve, "88%")
        // 水位抬升后 9% 仍预留 2 位
        let again = MenuBarMetricLayout.compactReserve(label: "CPU", value: "9%")
        XCTAssertEqual(again, "88%")
        // 升到 3 位后水位保持
        let three = MenuBarMetricLayout.compactReserve(label: "CPU", value: "100%")
        XCTAssertEqual(three, "888%")
        let afterSpike = MenuBarMetricLayout.compactReserve(label: "CPU", value: "9%")
        XCTAssertEqual(afterSpike, "888%")
    }

    /// compact 与 standard 占位行为一致（位数高水位）；网速堆叠块走定宽布局不参与水位
    func test_compactMetricBlockWidth_usesDigitWatermark() {
        MenuBarMetricLayout.resetCompactHighWaterForTesting()
        let low = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "9%",
            minimumValue: "100%",
            spacing: .compact
        )
        let mid = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "42%",
            minimumValue: "100%",
            spacing: .compact
        )
        XCTAssertEqual(low.size.width, mid.size.width, accuracy: 1.0)

        // 网速堆叠块：定宽布局，任何形态宽度恒等
        MenuBarMetricLayout.resetCompactHighWaterForTesting()
        let netSlow = MenuBarMetricRenderer.metricBlockImage(
            label: "NET",
            value: "↓6.0 KB/s",
            minimumValue: "↓000.0 MB/s",
            secondaryValue: "↑0.5 KB/s",
            secondaryMinimumValue: "↑000.0 MB/s"
        )
        let netPeak = MenuBarMetricRenderer.metricBlockImage(
            label: "NET",
            value: "↓12.5 MB/s",
            minimumValue: "↓000.0 MB/s",
            secondaryValue: "↑3.2 MB/s",
            secondaryMinimumValue: "↑000.0 MB/s"
        )
        let netIdle = MenuBarMetricRenderer.metricBlockImage(
            label: "NET",
            value: "↓1023 B/s",
            minimumValue: "↓000.0 MB/s",
            secondaryValue: "↑0 B/s",
            secondaryMinimumValue: "↑000.0 MB/s"
        )
        XCTAssertEqual(netSlow.size.width, netPeak.size.width, accuracy: 0.5)
        XCTAssertEqual(netSlow.size.width, netIdle.size.width, accuracy: 0.5)
    }

    /// 网速堆叠布局（Stats 风格）：箭头固定左列、数值定宽右对齐、块宽恒定
    func test_networkStacked_layoutIsCompactAndStable() throws {
        let image = try XCTUnwrap(MenuBarMetricRenderer.metricBlockImage(
            label: "NET",
            value: "↓21 KB/s",
            minimumValue: "↓000.0 MB/s",
            secondaryValue: "↑290 KB/s",
            secondaryMinimumValue: "↑000.0 MB/s"
        ))

        // 块高与其他指标一致（21pt），保证菜单栏基线对齐
        XCTAssertEqual(image.size.height, 21)

        // 块宽恒定：数值/单位任意变化（B/KB/MB 跨段、位数跨越）宽度不变，
        // 左侧图标不再随网速波动移动
        let variants: [(String, String)] = [
            ("↓1023 B/s", "↑0 B/s"),
            ("↓9.9 KB/s", "↑888 KB/s"),
            ("↓12.5 MB/s", "↑3.2 MB/s"),
            ("↓8.8 GB/s", "↑0.9 GB/s"),
            ("↓--", "↑--"),
        ]
        for (down, up) in variants {
            let variant = MenuBarMetricRenderer.metricBlockImage(
                label: "NET",
                value: down,
                minimumValue: "↓000.0 MB/s",
                secondaryValue: up,
                secondaryMinimumValue: "↑000.0 MB/s"
            )
            XCTAssertEqual(variant.size.width, image.size.width, accuracy: 0.5, "\(down) / \(up)")
        }

        // 箭头列对齐：两行箭头起始 x 相同（渲染 2x 位图扫描首墨水列）
        XCTAssertEqual(try arrowColumnX(of: image, row: 0), try arrowColumnX(of: image, row: 1), accuracy: 1.5)
    }

    /// 渲染 2x 位图，扫描指定行（0=上行）的首个墨水列位置
    private func arrowColumnX(of image: NSImage, row: Int) throws -> CGFloat {
        let scale: CGFloat = 2
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        // row 0 = 上半（colorAt y 0..h/2），row 1 = 下半
        let yRange = row == 0 ? 0..<(h/2) : (h/2)..<h
        for x in 0..<w {
            for y in yRange {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.alphaComponent > 0.3 {
                    return CGFloat(x)
                }
            }
        }
        struct ScanError: Error {}
        throw ScanError()
    }

    /// 网速堆叠块与 label/value 块顶底对齐：渲染到 2x 位图扫描墨水行段，
    /// NET 首行顶 ≈ label 顶、末行底 ≈ value 底（容差 ±3px @2x，吸收字体微调差异）
    func test_networkStacked_verticalAlignmentMatchesLabelValueBlocks() throws {
        let cpu = MenuBarMetricRenderer.metricBlockImage(
            label: "CPU",
            value: "42%",
            minimumValue: "100%"
        )
        let net = MenuBarMetricRenderer.metricBlockImage(
            label: "NET",
            value: "↓1.4 MB/s",
            minimumValue: "↓000.0 MB/s",
            secondaryValue: "↑488 KB/s",
            secondaryMinimumValue: "↑000.0 MB/s"
        )

        func inkRows(_ image: NSImage) -> (top: Int, bottom: Int)? {
            let scale: CGFloat = 2
            let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()

            var top: Int?, bottom: Int?
            for y in 0..<h {
                for x in 0..<w {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.alphaComponent > 0.3 {
                        top = top ?? y
                        bottom = y
                        break
                    }
                }
            }
            guard let t = top, let b = bottom else { return nil }
            return (t, b)
        }

        let cpuSpan = try XCTUnwrap(inkRows(cpu))
        let netSpan = try XCTUnwrap(inkRows(net))
        XCTAssertEqual(netSpan.top, cpuSpan.top, accuracy: 3)
        XCTAssertEqual(netSpan.bottom, cpuSpan.bottom, accuracy: 3)
    }

    func test_compactAttributedTitle_cpuSameDigitWidthStable() {
        MenuBarMetricLayout.resetCompactHighWaterForTesting()
        var snapA = SystemSnapshot()
        snapA.cpuUsage = CPUUsageReading(total: 0.09, user: 0.06, system: 0.03)
        var snapB = SystemSnapshot()
        snapB.cpuUsage = CPUUsageReading(total: 0.42, user: 0.3, system: 0.12)

        var config = MonitorConfiguration()
        config.menuBarSpacing = .compact
        config.combineTemperatures = false

        let a = MenuBarMetricRenderer.attributedTitle(
            for: snapA,
            metrics: [.cpu],
            configuration: config
        )
        let b = MenuBarMetricRenderer.attributedTitle(
            for: snapB,
            metrics: [.cpu],
            configuration: config
        )
        XCTAssertEqual(a.size().width, b.size().width, accuracy: 1.0)
    }

    func test_temperatureUnit_fahrenheit_formatsStandaloneAndCombined() {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = CPUUsageReading(total: 0.42, user: 0.3, system: 0.12)
        snapshot.cpuTemperature = 100 // 212°F
        snapshot.batteryTemperature = 37

        var config = MonitorConfiguration()
        config.temperatureUnit = .fahrenheit
        config.combineTemperatures = true

        let combined = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.cpu, .cpuTemperature],
            configuration: config
        )
        XCTAssertEqual(combined.map(\.label), ["CPU"])
        XCTAssertEqual(combined[0].value, "42% 212°F")

        config.combineTemperatures = false
        let standalone = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.cpuTemperature, .batteryTemperature],
            configuration: config
        )
        XCTAssertEqual(standalone.map(\.label), ["CPU°", "BAT°"])
        XCTAssertEqual(standalone[0].value, "212°F")
        XCTAssertEqual(
            standalone[1].value,
            MetricFormat.temperature(37, unit: .fahrenheit)
        )
    }

    func test_temperatureUnit_fahrenheit_gpuCombinedAlsoFormats() {
        // 覆盖 GPU 合并温度的华氏路径（独立于 CPU 合并分支）
        var snapshot = SystemSnapshot()
        snapshot.gpuUsage = 0.18
        snapshot.gpuTemperature = 60 // 140°F

        var config = MonitorConfiguration()
        config.temperatureUnit = .fahrenheit
        config.combineTemperatures = true

        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.gpu, .gpuTemperature],
            configuration: config
        )
        XCTAssertEqual(blocks.map(\.label), ["GPU"])
        XCTAssertEqual(blocks[0].value, "18% 140°F")
    }

    func test_missingReadingsRenderPlaceholder() {
        var snapshot = SystemSnapshot()
        snapshot.issues[.cpu] = .failed("host_statistics failed")
        // gpu / network left nil without issues

        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.cpu, .gpu, .network],
            configuration: MonitorConfiguration()
        )
        XCTAssertEqual(blocks.map(\.label), ["CPU", "GPU", "NET"])
        XCTAssertEqual(blocks[0].value, "--")
        XCTAssertEqual(blocks[1].value, "--")
        XCTAssertEqual(blocks[2].value, "↓--")
        XCTAssertEqual(blocks[2].secondaryValue, "↑--")
    }

    /// 预览位图必须按指定 backing scale 光栅化，且点尺寸与像素严格对应，
    /// 否则设置页预览会被缩放采样放大导致文字发糊
    func test_rasterize_pixelDensityMatchesBackingScale() throws {
        var snapshot = SystemSnapshot()
        snapshot.memoryUsed = 1_000_000_000
        snapshot.memoryTotal = 4_000_000_000

        let title = MenuBarMetricRenderer.attributedTitle(
            for: snapshot,
            metrics: [.memory],
            configuration: MonitorConfiguration()
        )

        let rasterized = MenuBarMetricRenderer.rasterize(title, backingScale: 2)
        let titleSize = title.size()
        let expectedWidth = max(1, ceil(titleSize.width) + 4)
        let expectedHeight = max(1, ceil(titleSize.height) + 4)

        // 点尺寸保留 1:1，避免 SwiftUI 显示时缩放
        XCTAssertEqual(rasterized.size.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(rasterized.size.height, expectedHeight, accuracy: 0.5)

        // 位图实际像素 = 点尺寸 × backing scale
        let rep = try XCTUnwrap(rasterized.representations.first)
        XCTAssertEqual(rep.pixelsWide, Int(expectedWidth * 2))
        XCTAssertEqual(rep.pixelsHigh, Int(expectedHeight * 2))

        // 1x scale 也严格对应（外接屏场景）
        let lowDPI = MenuBarMetricRenderer.rasterize(title, backingScale: 1)
        let lowRep = try XCTUnwrap(lowDPI.representations.first)
        XCTAssertEqual(lowRep.pixelsWide, Int(expectedWidth))
        XCTAssertEqual(lowRep.pixelsHigh, Int(expectedHeight))
    }

    // MARK: - Helpers

    private func firstBlock(
        for snapshot: SystemSnapshot,
        metrics: [MenuBarMetric],
        configuration: MonitorConfiguration
    ) -> MenuBarMetricRenderer.MetricBlock {
        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: metrics,
            configuration: configuration
        )
        XCTAssertEqual(blocks.count, 1)
        return blocks[0]
    }
}

// MARK: - 风扇块

final class MenuBarMetricFanBlockTests: XCTestCase {
    func test_fanBlock_joinsAllFanRPMs() {
        var snapshot = SystemSnapshot()
        snapshot.fans = [
            FanReading(id: 0, currentRPM: 3200, minRPM: 1200, maxRPM: 5800, targetRPM: 3200, isManualMode: false),
            FanReading(id: 1, currentRPM: 3400, minRPM: 1200, maxRPM: 5900, targetRPM: 3400, isManualMode: false)
        ]
        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.fan],
            configuration: MonitorConfiguration()
        )
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "FAN")
        XCTAssertEqual(blocks[0].value, "3200/3400", "全部风扇单行拼接")
    }

    func test_fanBlock_singleFan_showsPlainRPM() {
        var snapshot = SystemSnapshot()
        snapshot.fans = [
            FanReading(id: 0, currentRPM: 3200, minRPM: 1200, maxRPM: 5800, targetRPM: 3200, isManualMode: false)
        ]
        let blocks = MenuBarMetricRenderer.blocks(
            for: snapshot,
            metrics: [.fan],
            configuration: MonitorConfiguration()
        )
        XCTAssertEqual(blocks[0].value, "3200")
    }

    func test_fanBlock_noDataOrIssue_showsPlaceholder() {
        let empty = MenuBarMetricRenderer.blocks(
            for: SystemSnapshot(),
            metrics: [.fan],
            configuration: MonitorConfiguration()
        )
        XCTAssertEqual(empty[0].value, "--")

        var failed = SystemSnapshot()
        failed.issues[.fan] = .failed("FNum unreadable")
        let issue = MenuBarMetricRenderer.blocks(
            for: failed,
            metrics: [.fan],
            configuration: MonitorConfiguration()
        )
        XCTAssertEqual(issue[0].value, "--", "读取失败显示占位而非 0")
    }
}
