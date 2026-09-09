import AppKit
import CoreGraphics
import Foundation
import os.log

/// 多钉图注册表：仅持有控制器强引用与稳定 id，不保存拖拽/手势临时状态。
/// 托盘管理 API 形状冻结于此，T14 只接线菜单。
@MainActor
final class PinnedScreenshotRegistry {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "PinnedScreenshot")

    /// 复制/保存路径：默认走 T3 管线。
    private let pipeline: ScreenshotResultPipeline
    private let now: () -> Date
    private var controllers: [UUID: PinnedScreenshotWindowController] = [:]

    /// 当前选中的钉图；仅它可响应 ESC。新建钉图与直接点击钉图会选中它。
    private var selectedId: UUID?
    /// ESC 监听：钉图存在期间安装，全部关闭后卸载（零常驻副作用）。
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    /// 指针监听：点击非钉图区域时取消选中，避免 ESC 误删后台贴图。
    private var pointerLocalMonitor: Any?
    private var pointerGlobalMonitor: Any?

    init(
        pipeline: ScreenshotResultPipeline = ScreenshotResultPipeline(),
        now: @escaping () -> Date = Date.init
    ) {
        self.pipeline = pipeline
        self.now = now
    }

    /// T15 L10n 注入；Factory 设置后，新建钉图控制器沿用运行时语言。
    var stringsProvider: () -> Strings = { .en }
    /// 外观偏好注入（组合根接线）；nil=未接线，窗口跟随系统。
    weak var appearance: AppearanceSettings?

    // MARK: - 创建

    /// 从截图结果创建钉图；失败明确抛错，不伪造成功空窗。
    @discardableResult
    func pin(result: ScreenshotResult, at origin: NSPoint? = nil) throws -> PinnedScreenshotHandle {
        try pin(
            image: result.pixelImage,
            pointPixelScale: result.targetScreen.pointPixelScale,
            preferredScreenFrame: result.targetScreen.frameInAppKitPoints,
            baseResult: result,
            preferredOrigin: origin
        )
    }

    /// 标注导出等入口：可仅有合成图 + 可选 baseResult。
    /// - Parameter preferredOrigin: 可选的屏幕原点（AppKit 坐标）。非 nil 时按原位钉住，
    ///   仅 clamp 到可见区，不强制居中（参照 capcap `PinLauncher.pin(image:at:)`）。
    @discardableResult
    func pin(
        image: CGImage,
        pointPixelScale: CGFloat,
        preferredScreenFrame: CGRect?,
        baseResult: ScreenshotResult?,
        preferredOrigin: NSPoint? = nil
    ) throws -> PinnedScreenshotHandle {
        guard image.width > 0, image.height > 0 else {
            throw PinnedScreenshotError.invalidImage
        }
        // 显式 scale 优先；无效时尝试 baseResult；仍无效则明确失败（不静默回退 1）。
        let scale: CGFloat
        if pointPixelScale > 0 {
            scale = pointPixelScale
        } else if let baseScale = baseResult?.targetScreen.pointPixelScale, baseScale > 0 {
            scale = baseScale
        } else {
            throw PinnedScreenshotError.invalidGeometry
        }

        let id = UUID()
        let controller = PinnedScreenshotWindowController(
            id: id,
            image: image,
            pointPixelScale: scale,
            baseResult: baseResult,
            pipeline: pipeline,
            createdAt: now(),
            onClose: { [weak self] closedID in
                self?.handleControllerClosed(closedID)
            }
        )
        controller.stringsProvider = stringsProvider
        controller.onTouch = { [weak self] id in
            self?.markTouched(id)
        }
        controller.appearance = appearance
        try controller.present(preferredScreenFrame: preferredScreenFrame, preferredOrigin: preferredOrigin)
        controllers[id] = controller
        // 新钉图默认选中，允许用户立即按 ESC 撤销本次贴图。
        selectedId = id
        ensureEventMonitors()
        Self.logger.info("pinned screenshot id=\(id.uuidString, privacy: .public)")
        return controller.handle
    }

    // MARK: - 查询与管理 API（T14 托盘消费）

    func allPinned() -> [PinnedScreenshotHandle] {
        controllers.values
            .map(\.handle)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func handle(for id: UUID) -> PinnedScreenshotHandle? {
        controllers[id]?.handle
    }

    func setLocked(_ id: UUID, _ locked: Bool) throws {
        try controller(for: id).setLocked(locked)
    }

    func setClickThrough(_ id: UUID, _ clickThrough: Bool) throws {
        try controller(for: id).setClickThrough(clickThrough)
    }

    func setOpacity(_ id: UUID, _ opacity: CGFloat) throws {
        try controller(for: id).setOpacity(opacity)
    }

    func copy(_ id: UUID) throws {
        try controller(for: id).copyImage()
    }

    func save(_ id: UUID) throws {
        try controller(for: id).saveImage()
    }

    func close(_ id: UUID) throws {
        let c = try controller(for: id)
        c.close()
        // 统一收尾在 handleControllerClosed 完成
    }

    func closeAll() {
        let ids = Array(controllers.keys)
        for id in ids {
            controllers[id]?.close()
        }
        // 每个 close 触发各自的 handleControllerClosed
    }

    var count: Int { controllers.count }

    private func controller(for id: UUID) throws -> PinnedScreenshotWindowController {
        guard let c = controllers[id] else {
            throw PinnedScreenshotError.notFound(id)
        }
        guard !c.isClosed else {
            controllers.removeValue(forKey: id)
            throw PinnedScreenshotError.alreadyClosed(id)
        }
        return c
    }

    // MARK: - ESC 关闭（选中钉图）

    /// 标记用户刚交互的钉图，作为唯一的 ESC 关闭目标。
    func markTouched(_ id: UUID) {
        guard controllers[id] != nil else { return }
        selectedId = id
    }

    /// 取消当前选中状态。点击贴图以外的区域后调用，ESC 不再影响任何贴图。
    func clearSelectedPin() {
        selectedId = nil
    }

    /// 统一收尾：移除已关闭的 controller，清除对应选中状态，必要时卸载监听。
    private func handleControllerClosed(_ closedID: UUID) {
        controllers.removeValue(forKey: closedID)
        if selectedId == closedID {
            selectedId = nil
        }
        if controllers.isEmpty {
            removeEventMonitors()
        }
    }

    /// 关闭当前选中的钉图；返回值用于决定本地 ESC 是否需要被吞掉。
    @discardableResult
    func closeSelectedPin() -> Bool {
        guard let id = selectedId, controllers[id] != nil else { return false }
        controllers[id]?.close()
        return true
    }

    private func ensureEventMonitors() {
        guard escLocalMonitor == nil,
              escGlobalMonitor == nil,
              pointerLocalMonitor == nil,
              pointerGlobalMonitor == nil,
              !controllers.isEmpty else {
            return
        }
        // 本地：仅已选中钉图时吞掉 ESC，避免系统蜂鸣或把按键传给其他控件。
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.closeSelectedPin() == true { // ESC
                return nil
            }
            return event
        }
        // 全局：仅保留刚创建或已点击选中的钉图可关闭；不会阻止目标应用收到 ESC。
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.closeSelectedPin()
            }
        }

        let pointerEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // 本应用内只有点击钉图面板才保留选中；点击任何其他窗口会取消选中。
        pointerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            self?.updateSelection(forLocalPointerDown: event)
            return event
        }
        // 全局点击必定发生在其他应用，故应取消选中。点击穿透的贴图也走这里，不能误选。
        pointerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
            Task { @MainActor in
                self?.clearSelectedPin()
            }
        }
    }

    private func updateSelection(forLocalPointerDown event: NSEvent) {
        guard let id = controllers.first(where: { $0.value.owns(event.window) })?.key else {
            clearSelectedPin()
            return
        }
        markTouched(id)
    }

    private func removeEventMonitors() {
        if let escLocalMonitor {
            NSEvent.removeMonitor(escLocalMonitor)
            self.escLocalMonitor = nil
        }
        if let escGlobalMonitor {
            NSEvent.removeMonitor(escGlobalMonitor)
            self.escGlobalMonitor = nil
        }
        if let pointerLocalMonitor {
            NSEvent.removeMonitor(pointerLocalMonitor)
            self.pointerLocalMonitor = nil
        }
        if let pointerGlobalMonitor {
            NSEvent.removeMonitor(pointerGlobalMonitor)
            self.pointerGlobalMonitor = nil
        }
    }
}

// MARK: - 钉图创建协议（管线 / 标注导出注入）

@MainActor
protocol PinnedScreenshotPinning: AnyObject {
    @discardableResult
    func pin(result: ScreenshotResult, at origin: NSPoint?) throws -> PinnedScreenshotHandle

    @discardableResult
    func pin(
        image: CGImage,
        pointPixelScale: CGFloat,
        preferredScreenFrame: CGRect?,
        baseResult: ScreenshotResult?,
        preferredOrigin: NSPoint?
    ) throws -> PinnedScreenshotHandle
}

extension PinnedScreenshotRegistry: PinnedScreenshotPinning {}

// MARK: - Pipeline 桥接（非 MainActor 管线 → MainActor 注册表）

/// 供 `ScreenshotResultPipeline.pinService` 注入；保证钉图创建在主线程执行。
final class PinnedScreenshotPipelineBridge: ScreenshotPinning {
    private let registry: PinnedScreenshotRegistry

    init(registry: PinnedScreenshotRegistry) {
        self.registry = registry
    }

    func pinFromPipeline(result: ScreenshotResult, at origin: NSPoint?) throws -> UUID {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                try registry.pin(result: result, at: origin).id
            }
        }
        var handle: Result<UUID, Error>!
        DispatchQueue.main.sync {
            handle = Result {
                try MainActor.assumeIsolated {
                    try registry.pin(result: result, at: origin).id
                }
            }
        }
        return try handle.get()
    }
}
