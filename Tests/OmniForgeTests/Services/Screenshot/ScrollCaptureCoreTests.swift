import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

/// 长截图引擎（机制对齐重写版）决策流测试。
/// 行为规格：docs/active/2026-09-08-长截图引擎对齐/SPEC.md。
@MainActor
final class ScrollCaptureCoreTests: XCTestCase {

    // MARK: - 会话生命周期

    func test_startSession_settlesFirstFrame_andEmitsPreview() async {
        // 每次返回同内容新实例：TIFF 字节级相等 → 首帧立即 settle。
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            Self.makeSolidCGImage(width: 40, height: 40, color: .red)
        }

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            scaleFactor: 1,
            capture: capture
        )
        let previewArrived = expectation(description: "preview-emitted")
        capturer.onPreviewUpdated = { _ in previewArrived.fulfill() }

        await capturer.startSession()

        XCTAssertTrue(capturer.isActive)
        XCTAssertEqual(capturer.stripCount, 1, "首帧算第一条内容")
        XCTAssertEqual(capturer.stitchedPixelSize, CGSize(width: 40, height: 40))
        await fulfillment(of: [previewArrived], timeout: 5)
        capturer.cancelSession()
    }

    func test_startSession_firstFrameFailure_deliversNil() async {
        let capture: ScrollCapturer.RegionCapture = { _, _ in nil }

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            scaleFactor: 1,
            capture: capture
        )
        let done = expectation(description: "session-done")
        capturer.onSessionDone = { image in
            XCTAssertNil(image)
            done.fulfill()
        }

        await capturer.startSession()
        XCTAssertFalse(capturer.isActive)
        await fulfillment(of: [done], timeout: 5)
    }

    func test_cancelSession_neverDeliversImage() async {
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            Self.makeSolidCGImage(width: 40, height: 40, color: .red)
        }
        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            scaleFactor: 1,
            capture: capture
        )
        capturer.onSessionDone = { _ in
            XCTFail("取消路径不得交付任何图像")
        }

        await capturer.startSession()
        capturer.cancelSession()
        XCTAssertFalse(capturer.isActive)
        // 取消后 settle 轮询立即退出，不得再拼入内容。
        await capturer.processSettledFrame()
    }

    func test_stopSession_deliversImageWithPointSize() async {
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            Self.makeSolidCGImage(width: 40, height: 80, color: .red)
        }
        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 80),
            scaleFactor: 2,
            capture: capture
        )
        await capturer.startSession()

        var delivered: NSImage?
        let done = expectation(description: "session-done")
        capturer.onSessionDone = { image in
            delivered = image
            done.fulfill()
        }
        capturer.stopSession()
        await fulfillment(of: [done], timeout: 5)

        // 像素 40×80 ÷ backingScale 2 → point 20×40。
        XCTAssertEqual(delivered?.size.width ?? 0, 20, accuracy: 0.5)
        XCTAssertEqual(delivered?.size.height ?? 0, 40, accuracy: 0.5)
    }

    // MARK: - 位移规则（minShift 累积 + 遮缝 -1 + 负偏移丢弃）

    func test_immediateFrame_accumulatesBelowMinShift_thenMergesWithSeamBias() async {
        // 帧高 100 → minShift = 10。第一次 offset 8（不足，不拼也不更新基线），
        // 第二次 offset 50 → 拼入 safeOffset 49，总高 100 + 49 = 149。
        let offsets: [CGFloat] = [8, 50]
        let alignment = Self.makeScriptedAlignment(offsets)

        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            // 阶段 1-2：首帧 settle（红红）；之后立即帧给不同内容色。
            let stage = counter.next()
            if stage < 3 {
                return Self.makeSolidCGImage(width: 40, height: 100, color: .red)
            }
            return stage == 3
                ? Self.makeSolidCGImage(width: 40, height: 100, color: .blue)
                : Self.makeSolidCGImage(width: 40, height: 100, color: .green)
        }

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            capture: capture,
            alignment: alignment
        )
        await capturer.startSession()
        XCTAssertEqual(capturer.stripCount, 1)

        // offset 8 < minShift 10：丢弃且基线不前移（位移累积）。
        await capturer.processImmediateFrame()
        XCTAssertEqual(capturer.stripCount, 1, "低于门槛的位移不得拼接")

        // offset 50：拼入，遮缝 1px → 新增 49 行。
        await capturer.processImmediateFrame()
        XCTAssertEqual(capturer.stripCount, 2)

        var delivered: NSImage?
        let done = expectation(description: "session-done")
        capturer.onSessionDone = { image in
            delivered = image
            done.fulfill()
        }
        capturer.stopSession()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(delivered?.size.height ?? 0, 149, accuracy: 1.0, "100 + (50-1) 遮缝")
    }

    func test_negativeShift_dropsFrameWithoutTrimming() async {
        // 向上滚动：基线前移、帧丢弃，拼接结果不受影响（无回裁）。
        let alignment = Self.makeScriptedAlignment([-30])

        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            let stage = counter.next()
            return stage < 3
                ? Self.makeSolidCGImage(width: 40, height: 100, color: .red)
                : Self.makeSolidCGImage(width: 40, height: 100, color: .blue)
        }

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            capture: capture,
            alignment: alignment
        )
        await capturer.startSession()
        await capturer.processImmediateFrame()
        XCTAssertEqual(capturer.stripCount, 1, "负偏移只丢帧，不回裁")
        XCTAssertEqual(capturer.stitchedPixelSize.height, 100)

        capturer.cancelSession()
    }

    // MARK: - settle 路径与零位移自动停止

    func test_settledFrame_autoStopsAfterConsecutiveZeroShifts() async {
        // 一次成功滚动后连续 6 次配准失败 → 自动停止并交付。
        let offsets: [CGFloat] = [60, 0, 0, 0, 0, 0, 0]
        let alignment = Self.makeScriptedAlignment(offsets)

        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            // 阶段 1-2：红（首帧 settle）。阶段 3-4：蓝（第一次 settled 比较的两帧）。
            // 之后全部绿（后续 settle 两帧相等）。
            let stage = counter.next()
            if stage < 3 { return Self.makeSolidCGImage(width: 40, height: 100, color: .red) }
            if stage < 5 { return Self.makeSolidCGImage(width: 40, height: 100, color: .blue) }
            return Self.makeSolidCGImage(width: 40, height: 100, color: .green)
        }

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            capture: capture,
            alignment: alignment
        )
        var delivered: NSImage?
        let done = expectation(description: "auto-stop-delivers")
        capturer.onSessionDone = { image in
            delivered = image
            done.fulfill()
        }

        await capturer.startSession()
        // 第一次 settle 比较：offset 60 → 拼入。
        _ = await capturer.processSettledFrame()
        XCTAssertEqual(capturer.stripCount, 2)

        // 之后 6 次零位移 → 触底自动停止。
        for _ in 0..<6 {
            if capturer.isActive {
                _ = await capturer.processSettledFrame()
            }
        }
        XCTAssertFalse(capturer.isActive, "连续零位移达阈值后会话应自动停止")
        await fulfillment(of: [done], timeout: 5)
        // 100 + (60-1) = 159。
        XCTAssertEqual(delivered?.size.height ?? 0, 159, accuracy: 1.0)
    }

    /// 回归：首帧 settle 进行中（启动阶段）点停止，必须无图交付且会话
    /// 不得在 settle 完成后复活（曾导致停止后编辑器卡在长截图状态）。
    func test_stopSessionDuringStartup_deliversNilAndPreventsRevival() async {
        // 制造 0.4s 的首帧采集窗口，期间触发停止。
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            Thread.sleep(forTimeInterval: 0.4)
            return Self.makeSolidCGImage(width: 40, height: 40, color: .red)
        }

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            scaleFactor: 1,
            capture: capture
        )
        let done = expectation(description: "startup-stop-delivers")
        capturer.onSessionDone = { image in
            XCTAssertNil(image, "启动阶段停止应无图交付")
            done.fulfill()
        }

        let startTask = Task { await capturer.startSession() }
        // 等 startSession 进入启动阶段（settle 正在进行）。
        try? await Task.sleep(nanoseconds: 150_000_000)
        capturer.stopSession()

        XCTAssertFalse(capturer.isActive)
        await fulfillment(of: [done], timeout: 5)

        // settle 完成后不得复活（isCancelled 拦截）。
        await startTask.value
        XCTAssertFalse(capturer.isActive, "启动期停止后 settle 完成不得复活会话")
    }

    // MARK: - 像素缓冲所有权与行跨度（R02）

    /// 带行尾对齐填充的图（bytesPerRow > width*4）参与滚动条/头部检测不越界、不串行。
    func test_frozenDetection_survivesPaddedRows() async {
        // 两帧左区不同（滚动内容），右缘 8 列也不同（模拟滚动条动区）。
        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            let stage = counter.next()
            return stage < 3
                ? Self.makePaddedImage(width: 60, height: 100, leftColor: .red, scrollbarColor: .gray)
                : Self.makePaddedImage(width: 60, height: 100, leftColor: .blue, scrollbarColor: .white)
        }
        let alignment = Self.makeScriptedAlignment([60])
        let config = ScrollCapturer.SessionConfig(frozenDetectionEnabled: true)

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 60, height: 100),
            scaleFactor: 1,
            config: config,
            capture: capture,
            alignment: alignment
        )
        await capturer.startSession()
        await capturer.processImmediateFrame()
        // 主要验收：填充行跨度下像素访问不崩溃且拼接照常完成。
        XCTAssertEqual(capturer.stripCount, 2, "行填充图不影响拼接")
        capturer.cancelSession()
    }

    /// 非 32bpp 图像走受控 BGRA 转换路径，检测与拼接照常。
    func test_frozenDetection_convertsNon32bppImages() async {
        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            let stage = counter.next()
            return stage < 3
                ? Self.makeGray8Image(width: 40, height: 100, white: 0.2)
                : Self.makeGray8Image(width: 40, height: 100, white: 0.8)
        }
        let alignment = Self.makeScriptedAlignment([50])

        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            config: .init(frozenDetectionEnabled: true),
            capture: capture,
            alignment: alignment
        )
        await capturer.startSession()
        await capturer.processImmediateFrame()
        XCTAssertEqual(capturer.stripCount, 2, "8bpp 灰度图经转换路径仍可拼接")
        capturer.cancelSession()
    }

    // MARK: - 高度与字节预算（R09）

    /// 帧间位移跨越高度上限：最后一条只接收预算内行、到上限自动完成并交付。
    func test_merge_truncatesAtMaxScrollHeightAndAutoStops() async {
        // 首帧 100 高，maxScrollHeight=150；offset 60（safe 59）截断为 50 → 总高 150 触发自动停止。
        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            let stage = counter.next()
            return stage < 3
                ? Self.makeSolidCGImage(width: 40, height: 100, color: .red)
                : Self.makeSolidCGImage(width: 40, height: 100, color: .blue)
        }
        let alignment = Self.makeScriptedAlignment([60])
        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            config: .init(maxScrollHeight: 150),
            capture: capture,
            alignment: alignment
        )
        var delivered: NSImage?
        let done = expectation(description: "budget-auto-stop")
        capturer.onSessionDone = { image in
            delivered = image
            done.fulfill()
        }

        await capturer.startSession()
        await capturer.processImmediateFrame()

        XCTAssertFalse(capturer.isActive, "到高度上限应自动完成")
        XCTAssertEqual(capturer.stripCount, 2, "截断的一条仍计入")
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(delivered?.size.height ?? 0, 150, accuracy: 1.0, "100 + 截断 50 = 150")
    }

    /// 字节预算构成第二道防线：宽图的允许高度由 maxTotalBytes 决定。
    func test_merge_truncatesAtByteBudget() async {
        // 40px 宽 → bytesPerRow=160；预算 160×130 → 允许高 130。
        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            let stage = counter.next()
            return stage < 3
                ? Self.makeSolidCGImage(width: 40, height: 100, color: .red)
                : Self.makeSolidCGImage(width: 40, height: 100, color: .blue)
        }
        let alignment = Self.makeScriptedAlignment([60])
        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            config: .init(maxScrollHeight: 30_000, maxTotalBytes: 160 * 130),
            capture: capture,
            alignment: alignment
        )
        var delivered: NSImage?
        let done = expectation(description: "byte-budget-auto-stop")
        capturer.onSessionDone = { image in
            delivered = image
            done.fulfill()
        }

        await capturer.startSession()
        await capturer.processImmediateFrame()

        XCTAssertFalse(capturer.isActive, "到字节预算应自动完成")
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(delivered?.size.height ?? 0, 130, accuracy: 1.0, "100 + 截断 30 = 130")
    }

    /// 预算已耗尽后再有位移：不合并、不计数、不崩溃。
    func test_merge_budgetExhaustedSkipsMergeWithoutCounting() async {
        let counter = CallCounter()
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            let stage = counter.next()
            return Self.makeSolidCGImage(width: 40, height: 100, color: .red)
        }
        let alignment = Self.makeScriptedAlignment([60])
        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            config: .init(maxScrollHeight: 100),
            capture: capture,
            alignment: alignment
        )
        await capturer.startSession()

        let merged = await capturer.processImmediateFrame()
        XCTAssertFalse(merged, "首帧已占满预算，后续位移不得再合并")
        XCTAssertEqual(capturer.stripCount, 1, "预算耗尽的合并不计数")
        XCTAssertTrue(capturer.isActive, "预算外单次合并不结束会话（未触达上限合并）")
        capturer.cancelSession()
    }

    /// 首帧本身超预算（视口高 > 上限）：裁剪到预算内仍可交付。
    func test_startSession_capsFirstFrameToBudget() async {
        let capture: ScrollCapturer.RegionCapture = { _, _ in
            Self.makeSolidCGImage(width: 40, height: 100, color: .red)
        }
        let capturer = ScrollCapturer(
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 100),
            scaleFactor: 1,
            config: .init(maxScrollHeight: 60),
            capture: capture
        )
        var delivered: NSImage?
        let done = expectation(description: "first-frame-capped")
        capturer.onSessionDone = { image in
            delivered = image
            done.fulfill()
        }

        await capturer.startSession()
        XCTAssertEqual(capturer.stitchedPixelSize.height, 60, "首帧裁剪到预算内高度")
        capturer.stopSession()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(delivered?.size.height ?? 0, 60, accuracy: 1.0)
    }

    // MARK: - 窗口排除列表

    func test_scrollCaptureExclusion_includesHostOverlayWindowFirst() {
        let ids = ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: 42,
            hudWindowNumber: 7,
            previewWindowNumber: 9,
            toastWindowNumber: 11
        )
        XCTAssertEqual(ids.first, 42, "host overlay 必须排首位：引擎按首个排除窗口之下采集")
        XCTAssertEqual(ids, [42, 7, 9, 11])
    }

    func test_scrollCaptureExclusion_skipsNonPositiveAndDedupes() {
        let ids = ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: 0,
            hudWindowNumber: 5,
            previewWindowNumber: 5,
            toastWindowNumber: -1
        )
        XCTAssertEqual(ids, [5])
    }

    // MARK: - HUD 视图冒烟

    func test_hudView_updatesDimensionsAndAutoScrollState() {
        let hud = ScrollCaptureHUDView(title: "长截图", stopTitle: "停止")
        hud.update(
            pixelSize: CGSize(width: 800, height: 1200),
            backingScale: 2
        )
        XCTAssertEqual(hud.frame.height, 36, accuracy: 0.5)

        hud.update(
            pixelSize: CGSize(width: 800, height: 2400),
            backingScale: 2
        )
        XCTAssertEqual(hud.frame.height, 36, accuracy: 0.5)
    }

    /// 回归：进度更新使 HUD 内容变宽后，窗口宽度必须跟随重摆，
    /// 否则最右侧的停止按钮会被窗口 bounds 裁掉（真机截断 bug）。
    func test_hudWindow_resizesWithContentAfterUpdates() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("无屏环境无法定位 HUD 窗口")
        }

        let window = ScrollCaptureHUDWindow(
            title: "长截图",
            stopTitle: "停止",
            onStop: {}
        )
        let selection = NSRect(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.midY, width: 400, height: 300)
        window.position(relativeTo: selection, on: screen)

        // 初始：窗口宽度 == 内容宽度（标题已 sizeToFit，不再是零宽排布）。
        XCTAssertEqual(window.frame.width, window.hudView.frame.width, accuracy: 1.0)
        XCTAssertGreaterThan(window.hudView.frame.width, 100, "标题宽度应计入初始布局")

        // 首帧进度 + 更长尺寸文本。
        window.update(pixelSize: CGSize(width: 1600, height: 2400), backingScale: 2)
        window.update(pixelSize: CGSize(width: 1600, height: 9600), backingScale: 2)

        // 视图右边缘不得超出窗口（截断回归断言），窗口仍水平夹在屏内。
        XCTAssertEqual(window.frame.width, window.hudView.frame.width, accuracy: 1.0)
        XCTAssertLessThanOrEqual(window.hudView.frame.maxX, window.frame.width + 0.5)
        XCTAssertGreaterThanOrEqual(window.frame.minX, screen.visibleFrame.minX - 0.5)
        XCTAssertLessThanOrEqual(window.frame.maxX, screen.visibleFrame.maxX + 0.5)

        window.dismiss()
    }

    // MARK: - Helpers

    /// 线程安全的自增计数（@Sendable 采集闭包内使用）。
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        /// 返回自增后的调用序号（从 1 开始）。
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// 按调用序吐出脚本项目；耗尽后重复末项。
    private static func makeScriptedAlignment(_ offsets: [CGFloat]) -> ScrollCapturer.AlignmentFinder {
        let counter = CallCounter()
        return { _, _ in
            let call = counter.next() - 1
            return offsets[min(call, offsets.count - 1)]
        }
    }

    /// 纯色 CGImage（CGContext 绘制，可在任意线程调用）。
    private nonisolated static func makeSolidCGImage(width: Int, height: Int, color: NSColor) -> CGImage {
        let srgb = color.usingColorSpace(.sRGB) ?? .red
        let cgColor = CGColor(
            srgbRed: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: 1
        )
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 带行尾对齐填充的图：主区双色（左主色 + 右缘滚动条色），bytesPerRow 故意大于 width*4。
    private nonisolated static func makePaddedImage(
        width: Int,
        height: Int,
        leftColor: NSColor,
        scrollbarColor: NSColor
    ) -> CGImage {
        let bytesPerRow = width * 4 + 16 // 行尾 16 字节对齐填充
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(leftColor.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 右缘 8 列用滚动条色（两帧不同色 → 判为动区，宽度 8 合法）。
        context.setFillColor(scrollbarColor.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(x: width - 8, y: 0, width: 8, height: height))
        return context.makeImage()!
    }

    /// 8bpp 灰度图（非 32bpp，触发受控转换路径）。
    private nonisolated static func makeGray8Image(width: Int, height: Int, white: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(CGColor(gray: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
