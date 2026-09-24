import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit + CGWindowList 实现的屏幕捕获客户端。
final class ScreenCaptureKitClient: ScreenCaptureClient {
    private let preflightAccess: () -> Bool
    /// 枚举来源；生产为 `SCShareableContent.current`，测试注入计数器。
    private let contentProvider: () async throws -> SCShareableContent
    /// 枚举结果缓存：TTL 内复用 + 并发单飞。
    private let contentCache: TTLResultCache<SCShareableContent>

    init(
        preflightAccess: @escaping () -> Bool = { true },
        contentProvider: @escaping () async throws -> SCShareableContent = {
            try await SCShareableContent.current
        },
        contentCacheTTL: TimeInterval = 2.0
    ) {
        self.preflightAccess = preflightAccess
        self.contentProvider = contentProvider
        self.contentCache = TTLResultCache(ttl: contentCacheTTL)
    }

    /// 取可共享内容枚举：TTL 内直接复用缓存；已有枚举在飞时挂上去等同一份结果，
    /// 不起第二次枚举。
    ///
    /// 为什么必须复用：`SCShareableContent.current` 要枚举系统全部窗口，成本随窗口数
    /// 线性上升——本机实测 ~1.05s（3222 个窗口，其中 CursorUIViewService 2855 个），
    /// 而真正的 `SCScreenshotManager.captureImage` 只要 ~60ms。截图会话里冻屏与
    /// 「选区先于冻屏就绪」的实时回退各枚举一次，这 1s 就被吃两遍：用户手快时标注
    /// 工具栏要等第二次枚举 + 捕获，凭空多出一两秒。
    private func shareableContent() async throws -> SCShareableContent {
        try await contentCache.value(contentProvider)
    }

    // MARK: - ScreenCaptureClient

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        guard preflightAccess() else { throw ScreenCaptureError.permissionDenied }

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.invalidDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.captureResolution = .best

        let displayBounds = CGDisplayBounds(displayID)
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        config.width = max(Int(ceil(displayBounds.width * scale)), 1)
        config.height = max(Int(ceil(displayBounds.height * scale)), 1)

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func captureRegion(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage {
        guard preflightAccess() else { throw ScreenCaptureError.permissionDenied }
        guard rect.width > 0, rect.height > 0 else { throw ScreenCaptureError.invalidRect }

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.invalidDisplay
        }

        let excludedWindows: [SCWindow]
        if excludingWindowIDs.isEmpty {
            excludedWindows = []
        } else {
            let idSet = Set(excludingWindowIDs)
            excludedWindows = content.windows.filter { idSet.contains($0.windowID) }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        // sourceRect 必须在显示器的本地坐标系中（该显示器的左上原点），
        // 而非全局 CG 坐标系。扩展屏的 CGDisplayBounds.origin 非零时，
        // 传入全局坐标会捕获错误区域。
        let displayBounds = CGDisplayBounds(displayID)
        let localRect = CGRect(
            x: rect.origin.x - displayBounds.origin.x,
            y: rect.origin.y - displayBounds.origin.y,
            width: rect.width,
            height: rect.height
        )

        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        let scale = max(scaleFactor, 1)
        config.width = max(Int(ceil(rect.width * scale)), 1)
        config.height = max(Int(ceil(rect.height * scale)), 1)
        config.capturesAudio = false
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func captureSnapshot(
        displayID: CGDirectDisplayID,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage {
        guard preflightAccess() else { throw ScreenCaptureError.permissionDenied }

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.invalidDisplay
        }

        // 排除 overlay 等已显示的遮罩窗口：冻屏发生在遮罩 orderFront 之后，
        // 不排除会把暗化遮罩烤进底图。与 captureDisplay 排除逻辑一致。
        let excludedWindows: [SCWindow]
        if excludingWindowIDs.isEmpty {
            excludedWindows = []
        } else {
            let idSet = Set(excludingWindowIDs)
            excludedWindows = content.windows.filter { idSet.contains($0.windowID) }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.captureResolution = .best

        let displayBounds = CGDisplayBounds(displayID)
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        config.width = max(Int(ceil(displayBounds.width * scale)), 1)
        config.height = max(Int(ceil(displayBounds.height * scale)), 1)

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - 从 CGImage 裁剪选区

extension CGImage {
    /// 从全屏快照中裁剪选区（全局坐标 → 本地坐标 → 像素坐标）。
    func croppingToSelection(globalRect: CGRect, displayID: CGDirectDisplayID) -> CGImage? {
        let displayBounds = CGDisplayBounds(displayID)
        let localRect = CGRect(
            x: globalRect.origin.x - displayBounds.origin.x,
            y: globalRect.origin.y - displayBounds.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let scaleX = CGFloat(width) / displayBounds.width
        let scaleY = CGFloat(height) / displayBounds.height
        let imageRect = CGRect(
            x: localRect.origin.x * scaleX,
            y: localRect.origin.y * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        )
        return cropping(to: imageRect)
    }
}

// MARK: - TTL 结果缓存 + 并发单飞

/// 带时效的结果缓存，并在生产者在飞时让后来者挂靠同一份结果（单飞）。
///
/// 用途：`SCShareableContent.current` 这类「贵且可短期复用」的系统调用。截图会话里
/// 冻屏与实时回退会在几十毫秒内接连请求同一份枚举，各查一次就把成本翻倍。
final class TTLResultCache<Value> {
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cached: (value: Value, at: CFAbsoluteTime)?
    private var inFlight: Task<Value, Error>?

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// 取缓存值；过期或空缺时用 `produce` 生产一份，并让并发调用共享该次生产。
    func value(_ produce: @escaping () async throws -> Value) async throws -> Value {
        lock.lock()
        if let cached, CFAbsoluteTimeGetCurrent() - cached.at < ttl {
            lock.unlock()
            return cached.value
        }
        if let inFlight {
            lock.unlock()
            return try await inFlight.value
        }
        let task = Task { try await produce() }
        inFlight = task
        lock.unlock()

        do {
            let value = try await task.value
            lock.lock()
            cached = (value, CFAbsoluteTimeGetCurrent())
            inFlight = nil
            lock.unlock()
            return value
        } catch {
            // 失败不写缓存，并清掉在飞引用：后来者重新发起生产，
            // 而不是继承一个已经终结的失败（已挂靠在本次生产上的调用共同承担该错误）。
            lock.lock()
            inFlight = nil
            lock.unlock()
            throw error
        }
    }
}
