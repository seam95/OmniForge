import AppKit
import CoreGraphics
import Foundation
import os.log
import Vision

/// 长截图采集与拼接引擎。
///
/// 行为规格见 docs/active/2026-09-08-长截图引擎对齐/SPEC.md，要点：
/// - 按需单帧采集：每帧都是合成器输出的完整快照，无流管理、无陈旧帧。
/// - TIFF 字节级 settle：连续两帧完全相等才认定内容停止渲染，零容忍。
/// - 手动模式事件驱动双速率：滚动中 0.15s 节流立即抓帧（不等 settle），
///   滚动停止后 0.25s 补拍一张全 settle 帧。
/// - 自动模式：合成滚轮事件驱动页面滚动，触底自动停止。
/// - 整帧 Vision 平移配准；配准前裁掉吸顶头部与滚动条。
/// - 1px 遮缝（新帧多覆盖一行）+ 立即增量合并（不保留帧序列）。
@MainActor
final class ScrollCapturer {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "ScrollCapturer")

    // MARK: - 回调（主线程触发）

    /// 每合入一条新内容后回调（首帧也算一条），参数为当前条数。
    var onStripAdded: ((Int) -> Void)?
    /// 会话结束交付拼接结果；取消路径不触发。nil 表示会话无产出。
    var onSessionDone: ((NSImage?) -> Void)?
    /// 自动滚动启动时回调（含会话按设置直入自动模式）。
    var onAutoScrollStarted: (() -> Void)?
    /// 拼接图更新（含首帧），主线程回调。
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - 采集与配准注入（测试钩子）

    /// 同步按需采集：返回 `rect`（全局 CG 坐标）区域的合成器快照。
    typealias RegionCapture = @Sendable (_ rect: CGRect, _ excludingWindowIDs: [CGWindowID]) -> CGImage?
    /// 整帧平移配准：返回 current 相对 previous 的垂直位移（ty）。
    typealias AlignmentFinder = @Sendable (_ current: CGImage, _ previous: CGImage) -> CGFloat?

    // MARK: - 会话配置

    struct SessionConfig: Sendable {
        /// 会话直入自动滚动（HUD 按钮仍可切换）。
        var autoScrollEnabled = false
        /// 自动滚动速度 1...4。
        var autoScrollSpeed = 3
        /// 反转自动滚动方向（适配外接鼠标/滚动方向偏好与默认相反的环境）。
        var autoScrollReversed = false
        /// 拼接图高度上限（px），达到即自动停止。
        var maxScrollHeight = 30_000
        /// 吸顶头部/滚动条检测开关。
        var frozenDetectionEnabled = true

        static let standard = SessionConfig()
    }

    // MARK: - 公开状态

    private(set) var stripCount = 0
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive = false
    private(set) var autoScrollActive = false
    private var isCancelled = false
    /// startSession 首帧 settle 进行中（此阶段 isActive 尚未置位）。
    private var isSessionStarting = false

    /// 拼接结果当前总高（pt），HUD 进度用。
    var estimatedTotalHeightPoints: CGFloat {
        guard let mergedImage else { return 0 }
        return CGFloat(mergedImage.height) / backingScale
    }

    // MARK: - 私有状态

    private let captureRect: CGRect
    private let backingScale: CGFloat
    private let excludedWindowIDs: [CGWindowID]
    private let config: SessionConfig
    private let capture: RegionCapture
    private let findAlignment: AlignmentFinder
    private let diagnosticID: String

    /// 重计算（TIFF 生成 / Vision / 合并 / 像素检测）串行队列。
    private nonisolated let computeQueue = DispatchQueue(
        label: "com.omniforge.scroll-capture",
        qos: .userInitiated
    )

    // 帧状态
    private var shotA: CGImage?
    private var mergedImage: CGImage?

    // 固定元素检测
    private var headerHeightPx = 0
    private var headerDetectionDone = false
    private var rightMarginPx = 0
    private var rightMarginDetected = false

    // 自动停止计数
    private var matchNotFoundCount = 0
    private var consecutiveZeroShifts = 0
    private var hasScrolledOnce = false
    private let maxMatchNotFound = 8
    private let maxZeroShiftsBeforeStop = 6

    // 手动滚动监听与节流
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal: Any?
    private let manualCaptureInterval: TimeInterval = 0.15
    private var lastCaptureTime: TimeInterval = 0
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25

    /// 单帧在飞互斥：立即抓帧与 settle 补拍不并发。
    private var isProcessingFrame = false

    // 自动滚动
    private var autoScrollTask: Task<Void, Never>?
    /// 合成滚轮事件的目标（激活用）。
    private var targetAppPID: pid_t = 0

    // MARK: - Init

    init(
        captureRect: CGRect,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID] = [],
        config: SessionConfig = .standard,
        capture: RegionCapture? = nil,
        alignment: AlignmentFinder? = nil,
        diagnosticID: String? = nil
    ) {
        self.captureRect = captureRect
        self.backingScale = max(1, scaleFactor)
        self.excludedWindowIDs = excludingWindowIDs
        self.config = config
        self.diagnosticID = diagnosticID ?? String(UUID().uuidString.prefix(8))
        self.capture = capture ?? Self.defaultCapture
        self.findAlignment = alignment ?? Self.findAlignmentViaVision
    }

    /// 按需单帧采集：取排除列表首个窗口之下的合成器快照。
    /// 传入 rect 为全局 CG 坐标（顶左原点），与 CGWindowList 系 API 一致。
    private static let defaultCapture: RegionCapture = { rect, excludingWindowIDs in
        let listOption: CGWindowListOption = [.optionOnScreenBelowWindow]
        let windowID = excludingWindowIDs.first ?? kCGNullWindowID
        return CGWindowListCreateImage(rect, listOption, windowID, [.boundsIgnoreFraming])
    }

    /// 整帧 Vision 平移配准，返回 ty（正=底部露出新内容）。
    private static let findAlignmentViaVision: AlignmentFinder = { current, previous in
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        let handler = VNImageRequestHandler(cgImage: current, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return observation.alignmentTransform.ty
    }

    // MARK: - 会话生命周期

    func startSession() async {
        guard !isActive, !isCancelled, !isSessionStarting else { return }
        isSessionStarting = true
        defer { isSessionStarting = false }

        // 首帧 settle（冷启动容忍多轮重试）。
        guard let firstFrame = await captureSettledFrame() else {
            guard !isCancelled else { return }
            log("session-start-first-frame-failed")
            onSessionDone?(nil)
            return
        }
        guard !isCancelled else { return }

        isActive = true
        shotA = nil
        mergedImage = firstFrame
        headerHeightPx = 0
        headerDetectionDone = false
        rightMarginPx = 0
        rightMarginDetected = false
        matchNotFoundCount = 0
        consecutiveZeroShifts = 0
        hasScrolledOnce = false
        stripCount = 1
        stitchedPixelSize = CGSize(width: firstFrame.width, height: firstFrame.height)

        resolveTargetApp()
        log(
            "session-start",
            metadata: [
                "pixelSize": "\(firstFrame.width)x\(firstFrame.height)",
                "autoScroll": config.autoScrollEnabled,
            ]
        )
        emitPreview()
        onStripAdded?(stripCount)

        if config.autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    /// 停止会话并交付拼接结果。首帧 settle 进行中（启动阶段）同样有效：
    /// 无图交付 nil，并置取消标志防止启动完成后会话复活。
    func stopSession() {
        guard isActive || isSessionStarting else { return }
        isCancelled = true
        isActive = false
        teardownDrivers()

        let finalImage = deliverableImage()
        log(
            "session-stop",
            metadata: [
                "strips": stripCount,
                "pixelSize": "\(Int(stitchedPixelSize.width))x\(Int(stitchedPixelSize.height))",
                "hasImage": finalImage != nil,
            ]
        )
        onSessionDone?(finalImage)
    }

    /// 取消会话：拆掉一切驱动，不交付任何图像。首帧 settle 进行中同样有效。
    func cancelSession() {
        isCancelled = true
        isActive = false
        teardownDrivers()
        log("session-cancel")
    }

    /// HUD 切换自动/手动滚动。切向自动的权限门由编排层负责。
    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            stopManualScrollMonitors()
            startAutoScroll()
        }
    }

    private func teardownDrivers() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollActive = false
        settlementTimer?.invalidate()
        settlementTimer = nil
        stopManualScrollMonitors()
    }

    /// 交付包装：像素尺寸换算 point 尺寸。
    private func deliverableImage() -> NSImage? {
        guard let mergedImage else { return nil }
        let ptSize = NSSize(
            width: CGFloat(mergedImage.width) / backingScale,
            height: CGFloat(mergedImage.height) / backingScale
        )
        return NSImage(cgImage: mergedImage, size: ptSize)
    }

    /// 选区中心命中窗口的所属进程（自动滚动前激活目标 app）。
    private func resolveTargetApp() {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return }

        let center = CGPoint(x: captureRect.midX, y: captureRect.midY)
        let excluded = Set(excludedWindowIDs)

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID)),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            if CGRect(x: x, y: y, width: w, height: h).contains(center) {
                targetAppPID = pid
                return
            }
        }
    }

    // MARK: - 手动滚动（事件驱动双速率）

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onManualScrollEvent()
            }
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            Task { @MainActor [weak self] in
                self?.onManualScrollEvent()
            }
            return event
        }
    }

    private func stopManualScrollMonitors() {
        if let scrollMonitorGlobal {
            NSEvent.removeMonitor(scrollMonitorGlobal)
            self.scrollMonitorGlobal = nil
        }
        if let scrollMonitorLocal {
            NSEvent.removeMonitor(scrollMonitorLocal)
            self.scrollMonitorLocal = nil
        }
        settlementTimer?.invalidate()
        settlementTimer = nil
    }

    /// 滚动事件到达：立即路径节流抓帧 + 重置 settlement 补拍定时器。
    private func onManualScrollEvent() {
        guard isActive, !autoScrollActive else { return }

        // 滚动停止后补一张全 settle 帧（每次事件重置倒计时）。
        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processSettledFrame()
            }
        }

        // 滚动进行中：固定节流立即抓帧，不等待 settle——小选区下一次手势
        // 就可能滚过整个视口，等稳定会丢内容。
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= manualCaptureInterval else { return }
        lastCaptureTime = now
        Task { @MainActor [weak self] in
            await self?.processImmediateFrame()
        }
    }

    /// 当前比较基线：上一帧，或（会话首比较）拼接图顶部同高裁切。
    private func baselineFrame(matchingHeight height: Int) -> CGImage? {
        if let shotA { return shotA }
        guard let merged = mergedImage else { return nil }
        return merged.cropping(
            to: CGRect(x: 0, y: 0, width: merged.width, height: min(height, merged.height))
        )
    }

    /// 手动滚动中的立即抓帧：拿来当前画面直接尝试拼接（测试驱动点）。
    func processImmediateFrame() async {
        guard isActive, !isProcessingFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        guard let currentFrame = captureFrame() else { return }
        guard let previousFrame = baselineFrame(matchingHeight: currentFrame.height) else {
            shotA = currentFrame
            return
        }
        _ = await processFrame(current: currentFrame, previous: previousFrame, settled: false)
    }

    /// 停止后的全 settle 补拍；维护零位移自动停止计数（测试驱动点）。
    @discardableResult
    func processSettledFrame() async -> Bool {
        guard isActive, !isProcessingFrame else { return false }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        guard let currentFrame = await captureSettledFrame() else { return false }
        guard let previousFrame = baselineFrame(matchingHeight: currentFrame.height) else {
            shotA = currentFrame
            return false
        }
        let matched = await processFrame(current: currentFrame, previous: previousFrame, settled: true)

        // 零位移自动停止判定（触底后页面不再变化）。
        if !matched {
            consecutiveZeroShifts += 1
            if hasScrolledOnce, consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
                log("auto-stop-zero-shifts", metadata: ["count": consecutiveZeroShifts])
                stopSession()
            }
        }
        return matched
    }

    // MARK: - 自动滚动

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        // 光标移到选区中心并激活目标 app，让合成滚轮事件落在正确窗口上。
        CGWarpMouseCursorPosition(CGPoint(x: captureRect.midX, y: captureRect.midY))
        if targetAppPID != 0 {
            NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
        }

        let linesPerTick: Int32
        let burstCount: Int
        switch config.autoScrollSpeed {
        case 1: linesPerTick = 1; burstCount = 1
        case 2: linesPerTick = 1; burstCount = 2
        case 4: linesPerTick = 2; burstCount = 4
        default: linesPerTick = 1; burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.isActive, self.autoScrollActive else { return }
            await self.autoScrollLoop(linesPerTick: linesPerTick, burstCount: burstCount)
        }
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    /// 自动滚动主循环：发滚轮 → settle 比较 → 检查自动停止。
    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int) async {
        // 默认 wheel1 为负 = 向下滚动；开启反转则翻符号。
        let direction: Int32 = config.autoScrollReversed ? 1 : -1
        let wheel1 = direction * linesPerTick

        while isActive, autoScrollActive {
            for _ in 0..<burstCount {
                if let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: wheel1,
                    wheel2: 0,
                    wheel3: 0
                ) {
                    // 打本进程合成标记：滚动反转/平滑滚动的 tap 须直通，
                    // 否则自动滚轮会被自家滚轮方向偏好翻转成反向。
                    event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.ours)
                    event.post(tap: .cghidEventTap)
                }
            }

            // 等待滚动动画起效再进入 settle 轮询。
            try? await Task.sleep(nanoseconds: 50_000_000)
            let matched = await autoScrollCompareOnce()

            if !matched {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    log("auto-stop-match-not-found", metadata: ["count": matchNotFoundCount])
                    stopSession()
                    return
                }
            } else {
                matchNotFoundCount = 0
            }

            if let mergedImage, config.maxScrollHeight > 0, mergedImage.height >= config.maxScrollHeight {
                log("auto-stop-max-height", metadata: ["height": mergedImage.height])
                stopSession()
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 自动循环的比较体：复用手动 settle 路径（含零位移自动停止）。
    private func autoScrollCompareOnce() async -> Bool {
        guard isActive, autoScrollActive else { return false }
        return await processSettledFrame()
    }

    // MARK: - 采集与 settle

    private func captureFrame() -> CGImage? {
        capture(captureRect, excludedWindowIDs)
    }

    /// 轮询抓帧直到连续两帧 TIFF 表示字节级完全相等（内容真正停止渲染），
    /// 或重试耗尽返回最后一帧。重试 30 次，10ms 起 ×1.5 退避至 80ms。
    private func captureSettledFrame() async -> CGImage? {
        var previousTIFF: Data?
        var previousFrame: CGImage?
        var waitNs: UInt64 = 10_000_000

        for _ in 0..<30 {
            guard !isCancelled, isSessionStarting || isActive else { return nil }

            guard let frame = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiff = await computeOnQueue {
                NSBitmapImageRep(cgImage: frame).tiffRepresentation
            }
            guard let currentTIFF = tiff else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let previousTIFF, currentTIFF == previousTIFF {
                return frame
            }

            previousTIFF = currentTIFF
            previousFrame = frame
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        return previousFrame
    }

    // MARK: - 帧处理核心

    /// 单帧比较与合入。返回是否成功拼入新内容。
    private func processFrame(current: CGImage, previous: CGImage, settled: Bool) async -> Bool {
        if !rightMarginDetected {
            detectRightMargin(current: current, previous: previous)
        }

        guard let shift = await visionShift(current: current, previous: previous) else {
            // 配准失败：基线前移，丢弃该帧。
            shotA = current
            return false
        }

        let offsetPx = Int(round(shift))
        guard offsetPx > 0 else {
            // 向上滚/无位移：基线前移、丢弃（不支持回裁）。
            shotA = current
            return false
        }

        // 最小位移门槛：不足则不拼也不更新基线，让位移累积到下一帧。
        let minShift = current.height / 10
        if offsetPx < minShift {
            return false
        }

        consecutiveZeroShifts = 0
        hasScrolledOnce = true

        if config.frozenDetectionEnabled, !headerDetectionDone {
            detectHeader(current: current, previous: previous, shiftPx: offsetPx)
        }

        // 1px 遮缝：新条多覆盖一行，遮住接缝处的亚像素渲染差。
        let safeOffset = max(1, offsetPx - 1)
        mergeNewContent(currentFrame: current, offsetPx: safeOffset)

        shotA = current
        stripCount += 1
        log(
            "frame-merged",
            metadata: [
                "offsetPx": offsetPx,
                "safeOffset": safeOffset,
                "settled": settled,
                "strips": stripCount,
            ]
        )
        emitPreview()
        onStripAdded?(stripCount)
        return true
    }

    /// 整帧 Vision 平移配准；配准前裁掉吸顶头部与滚动条（快照检测状态
    /// 后在队列上执行裁剪与配准）。
    private func visionShift(current: CGImage, previous: CGImage) async -> CGFloat? {
        let maxCropY = current.height / 5
        let cropY = headerDetectionDone ? min(headerHeightPx, maxCropY) : 0
        let cropW = current.width - rightMarginPx
        let cropH = current.height - cropY
        let shouldCrop = cropY > 0 || rightMarginPx > 0
        let alignment = findAlignment

        return await computeOnQueue { () -> CGFloat? in
            guard !shouldCrop else {
                guard cropH > 20, cropW > 20 else { return nil }
                let cropRect = CGRect(x: 0, y: cropY, width: cropW, height: cropH)
                guard let croppedCurrent = current.cropping(to: cropRect),
                      let croppedPrevious = previous.cropping(to: cropRect)
                else { return nil }
                return alignment(croppedCurrent, croppedPrevious)
            }
            return alignment(current, previous)
        }
    }

    // MARK: - 固定元素检测

    /// 滚动条检测（一次性）：右缘向左逐列 SAD，列均值差 >8 记为动区；
    /// 宽度 3...40px 合法，生效宽度 = 检出宽 + 4px 余量。
    private func detectRightMargin(current: CGImage, previous: CGImage) {
        rightMarginDetected = true
        guard let result = detectRightMarginValue(current: current, previous: previous) else {
            log("scrollbar-detection", metadata: ["committedWidth": 0])
            return
        }
        rightMarginPx = result
        log("scrollbar-detection", metadata: ["committedWidth": result])
    }

    private nonisolated func detectRightMarginValue(current: CGImage, previous: CGImage) -> Int? {
        computeQueue.sync {
            guard current.width == previous.width,
                  current.height == previous.height,
                  let curData = rawPixelData(current),
                  let prevData = rawPixelData(previous)
            else { return nil }

            let w = current.width
            let h = current.height
            let bytesPerRow = w * 4

            let rowStart = h * 2 / 10
            let rowEnd = h * 8 / 10
            let rowStep = max(1, (rowEnd - rowStart) / 40)

            var scrollbarWidth = 0
            let maxScanCols = min(50, w / 8)

            for colOffset in 0..<maxScanCols {
                let col = w - 1 - colOffset
                var sad: UInt64 = 0
                var samples = 0

                for row in stride(from: rowStart, to: rowEnd, by: rowStep) {
                    let idx = row * bytesPerRow + col * 4
                    guard idx + 2 < h * bytesPerRow else { continue }
                    sad += UInt64(
                        abs(Int(curData[idx]) - Int(prevData[idx]))
                            + abs(Int(curData[idx + 1]) - Int(prevData[idx + 1]))
                            + abs(Int(curData[idx + 2]) - Int(prevData[idx + 2]))
                    )
                    samples += 1
                }
                guard samples > 0 else { continue }
                if sad / UInt64(samples) > 8 {
                    scrollbarWidth = colOffset + 1
                } else if scrollbarWidth > 0 {
                    break
                }
            }

            guard scrollbarWidth >= 3, scrollbarWidth <= 40 else { return nil }
            return scrollbarWidth + 4
        }
    }

    /// 吸顶头部检测（单次采纳）：有效位移 >5 触发；自顶向下逐行 SAD，
    /// 首个动行为冻结区下界；行数 ≥10 且 <60% 帧高即采纳。
    private func detectHeader(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard shiftPx > 5 else { return }
        guard let frozenRows = detectHeaderValue(
            current: current,
            previous: previous,
            rightMarginPx: rightMarginPx
        ) else {
            // 整帧冻结（两帧无可区分内容）：留待下次再测。
            return
        }

        headerDetectionDone = true
        if frozenRows >= 10, frozenRows < (current.height * 6 / 10) {
            headerHeightPx = frozenRows
            log("header-detection", metadata: ["frozenRows": frozenRows, "committed": true])
        } else {
            // 冻结区过小（无头部）或占帧高六成以上（不可信）都按无头部处理。
            headerHeightPx = 0
            log("header-detection", metadata: ["frozenRows": frozenRows, "committed": false])
        }
    }

    /// 返回自顶向下的首个动行（整帧无动行返回 nil）。行内横向每 4 像素采样。
    private nonisolated func detectHeaderValue(
        current: CGImage,
        previous: CGImage,
        rightMarginPx: Int
    ) -> Int? {
        computeQueue.sync {
            guard current.width == previous.width,
                  current.height == previous.height,
                  let curData = rawPixelData(current),
                  let prevData = rawPixelData(previous)
            else { return nil }

            let w = current.width
            let h = current.height
            let bytesPerRow = w * 4
            let compareBytes = max(4, w - rightMarginPx) * 4
            let colByteStep = 4 * 4 // 每 4 像素采样一列

            for row in 0..<h {
                var rowSAD: UInt64 = 0
                var samples = 0
                let rowOffset = row * bytesPerRow
                for col in stride(from: 0, to: compareBytes, by: colByteStep) {
                    guard rowOffset + col + 2 < h * bytesPerRow else { continue }
                    rowSAD += UInt64(
                        abs(Int(curData[rowOffset + col]) - Int(prevData[rowOffset + col]))
                            + abs(Int(curData[rowOffset + col + 1]) - Int(prevData[rowOffset + col + 1]))
                            + abs(Int(curData[rowOffset + col + 2]) - Int(prevData[rowOffset + col + 2]))
                    )
                    samples += 1
                }
                guard samples > 0 else { continue }
                if rowSAD / UInt64(samples) > 8 {
                    return row
                }
            }
            return nil
        }
    }

    /// CGImage 原始像素字节（BGRA）。
    private nonisolated func rawPixelData(_ image: CGImage) -> UnsafePointer<UInt8>? {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data
        else { return nil }
        return CFDataGetBytePtr(data)
    }

    // MARK: - 增量合并

    /// 立即增量合并：旧图在上、新内容在下。检出吸顶头部时只贴底部新条，
    /// 否则整帧绘制（自然覆盖重叠区）。新条高度为 `offsetPx` 行。
    private func mergeNewContent(currentFrame: CGImage, offsetPx: Int) {
        guard let existing = mergedImage else {
            mergedImage = currentFrame
            stitchedPixelSize = CGSize(width: currentFrame.width, height: currentFrame.height)
            return
        }

        let width = currentFrame.width
        let existingHeight = existing.height
        let newRows = offsetPx
        guard newRows > 0, newRows <= currentFrame.height else { return }

        let stripsHeaderOnly = headerDetectionDone && headerHeightPx > 0
        guard let merged = renderMerged(
            existing: existing,
            currentFrame: currentFrame,
            width: width,
            existingHeight: existingHeight,
            newRows: newRows,
            stripsHeaderOnly: stripsHeaderOnly
        ) else { return }

        mergedImage = merged
        stitchedPixelSize = CGSize(width: width, height: existingHeight + newRows)
    }

    private nonisolated func renderMerged(
        existing: CGImage,
        currentFrame: CGImage,
        width: Int,
        existingHeight: Int,
        newRows: Int,
        stripsHeaderOnly: Bool
    ) -> CGImage? {
        computeQueue.sync {
            let totalHeight = existingHeight + newRows
            let colorSpace = existing.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }

            // CGContext 原点在左下：旧图画在高位（顶部），新内容在低位（底部）。
            context.draw(existing, in: CGRect(x: 0, y: newRows, width: width, height: existingHeight))

            if stripsHeaderOnly {
                // 有吸顶头部：只把新帧底部新行贴入，头部区不重复拼接。
                let stripY = currentFrame.height - newRows
                if let strip = currentFrame.cropping(
                    to: CGRect(x: 0, y: stripY, width: width, height: newRows)
                ) {
                    context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: newRows))
                }
            } else {
                context.draw(
                    currentFrame,
                    in: CGRect(x: 0, y: 0, width: width, height: currentFrame.height)
                )
            }

            return context.makeImage()
        }
    }

    // MARK: - 预览

    private func emitPreview() {
        guard let mergedImage else { return }
        let ptSize = NSSize(
            width: CGFloat(mergedImage.width) / backingScale,
            height: CGFloat(mergedImage.height) / backingScale
        )
        onPreviewUpdated?(NSImage(cgImage: mergedImage, size: ptSize))
    }

    // MARK: - 队列桥与日志

    /// 把重计算派发到串行队列（TIFF/Vision/合并/像素检测），返回结果值。
    private nonisolated func computeOnQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            computeQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func log(_ event: String, metadata: [String: Any] = [:]) {
        var fields = metadata
        fields["session"] = diagnosticID
        fields["strips"] = stripCount
        let summary = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        Self.logger.debug("scroll-capture \(event, privacy: .public) \(summary, privacy: .public)")
    }
}
