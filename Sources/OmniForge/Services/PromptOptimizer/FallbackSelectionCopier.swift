import AppKit
import Foundation

/// ⌘C 兜底取词边界：AX 路径失败（终端 TUI 等 systemWide 焦点 noValue 的宿主）后，
/// 模拟拷贝读选中文本；带剪贴板快照备份恢复与自家历史采集暂停窗口（零污染）。
@MainActor
protocol SelectionCopying: AnyObject {
    /// 模拟 ⌘C 并读取写入的选中文本；无选中文本 / 应用不响应 / 超时 → nil。
    /// 返回后用户剪贴板内容与历史采集均已恢复。
    func copySelectionAndRead() async -> String?
}

/// 自家剪贴板历史采集的暂停窗口边界（`ClipboardHistoryManager` 实现）。
@MainActor
protocol ClipboardCaptureSuspending: AnyObject {
    func suspendCapture()
    func resumeCapture()
}

/// 运行时动态解析剪贴板历史 Manager 的暂停器（install 顺序无关；历史功能停用时优雅降级为无暂停）。
@MainActor
final class RuntimeClipboardCaptureSuspender: ClipboardCaptureSuspending {
    private var historyManager: ClipboardHistoryManager? {
        FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)
    }

    func suspendCapture() {
        historyManager?.suspendCapture()
    }

    func resumeCapture() {
        historyManager?.resumeCapture()
    }
}

/// 剪贴板快照：写入型临时操作的备份/恢复单元。
/// 按条目保存全部可读类型的原始数据；动态/承诺类型不可读取，静默丢弃（业界通行限制）。
struct PasteboardSnapshot {
    private let itemsData: [[NSPasteboard.PasteboardType: Data]]

    init(of pasteboard: NSPasteboard) {
        var collected: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // 动态类型 data(forType:) 可能触发昂贵解析或失败；失败即放弃该类型。
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            if !itemData.isEmpty {
                collected.append(itemData)
            }
        }
        itemsData = collected
    }

    /// 原样写回（clearContents + 逐条目逐类型重建）；空快照只清不写。
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !itemsData.isEmpty else { return }
        let items = itemsData.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data {
                item.setData(value, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

/// ⌘C 兜底实现：备份 → 暂停自家历史 → 注入 ⌘C → 轮询等待写入 → 读文本 → 恢复剪贴板与采集。
@MainActor
final class FallbackSelectionCopier: SelectionCopying {
    private let pasteboard: NSPasteboard
    private let keyPoster: KeyEventPosting
    private let captureSuspender: ClipboardCaptureSuspending?
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval

    init(
        pasteboard: NSPasteboard = .general,
        keyPoster: KeyEventPosting = SystemKeyEventPoster(),
        captureSuspender: ClipboardCaptureSuspending? = nil,
        pollInterval: TimeInterval = 0.02,
        timeout: TimeInterval = 0.6
    ) {
        self.pasteboard = pasteboard
        self.keyPoster = keyPoster
        self.captureSuspender = captureSuspender
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    func copySelectionAndRead() async -> String? {
        let snapshot = PasteboardSnapshot(of: pasteboard)
        captureSuspender?.suspendCapture()
        defer {
            // 先恢复剪贴板再恢复采集：resumeCapture 把变更基线拉平，恢复动作不进历史。
            snapshot.restore(to: pasteboard)
            captureSuspender?.resumeCapture()
        }

        let countBefore = pasteboard.changeCount
        keyPoster.postCommandC()

        // 轮询等待目标应用响应拷贝（写入会使 changeCount 前进）。
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != countBefore { break }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        guard pasteboard.changeCount != countBefore else { return nil }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}
