import AppKit
import Combine

// MARK: - 取色器服务
//
// 工具型特性（与 cleaner / uninstaller 一致）：进程级单例，不进 AppState、不接 FeatureFactory Manager 注册。
// 包装 macOS 系统 `NSColorSampler`：放大镜 / 十字准星 / 点击确认 / ESC 取消全部由系统提供，本服务只负责
// 持有会话状态、接收回调、把拾取的颜色写入剪贴板。
//
// 零权限：`NSColorSampler` 由系统进程读取像素，调用方不需要屏幕录制 / 辅助功能权限。

/// 抽象系统取色器调用，便于单测注入。
protocol ColorSampling {
    /// 唤起系统取色器；用户点击确认回调返回颜色，按 ESC 取消返回 nil。
    func show(selectionHandler: @escaping (NSColor?) -> Void)
}

extension NSColorSampler: ColorSampling {}

@MainActor
final class ColorPickerService: ObservableObject {
    static let shared = ColorPickerService()

    /// 最近一次拾取的颜色；nil 表示本会话尚未取色。不持久化（不保留历史）。
    @Published private(set) var currentColor: NSColor?

    /// 是否正在系统取色流程中；为 true 时禁止重复触发。
    @Published private(set) var isPicking = false

    private let sampler: ColorSampling
    private let writer: PasteboardWriting

    init(
        sampler: ColorSampling = NSColorSampler(),
        writer: PasteboardWriting = SystemPasteboardWriter()
    ) {
        self.sampler = sampler
        self.writer = writer
    }

    /// 唤起系统取色器。取色进行中再次调用直接忽略。
    func startPicking() {
        guard !isPicking else { return }
        isPicking = true
        sampler.show(selectionHandler: { [weak self] picked in
            // NSColorSampler 回调在主线程，但仍按 MainActor 约束显式派发，保证隔离安全。
            MainActor.assumeIsolated {
                self?.handlePicked(picked)
            }
        })
    }

    /// 把指定格式字符串写入剪贴板（仅写不粘贴）。供详情页「点击某格式即复制」复用。
    func copy(_ formatted: String) {
        writer.clearContents()
        writer.setString(formatted, forType: .string)
    }

    private func handlePicked(_ picked: NSColor?) {
        isPicking = false
        guard let picked else { return }  // 用户 ESC 取消，静默返回
        currentColor = picked
        // 取色成功后默认复制 HEX（最通用格式）；其余格式由详情页按需复制。
        copy(ColorFormat.hex(from: picked))
    }
}
