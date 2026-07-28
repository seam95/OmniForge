import AppKit
import Carbon
import Foundation

protocol PasteboardWriting {
    func clearContents()
    /// 返回写入是否成功（对齐 `NSPasteboard.setString`）。
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    /// 返回写入是否成功（对齐 `NSPasteboard.setData`）。
    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool
    /// 返回写入是否成功（对齐 `NSPasteboard.writeObjects`）。
    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

final class SystemPasteboardWriter: PasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setString(string, forType: type)
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setData(data, forType: type)
    }

    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        pasteboard.writeObjects(objects)
    }
}

protocol KeyEventPosting {
    func postCommandV(targetPID: pid_t?)
}

final class SystemKeyEventPoster: KeyEventPosting {
    func postCommandV(targetPID: pid_t?) {
        // 注意：使用 CGEvent 模拟按键需要在「系统设置 -> 隐私与安全性 -> 辅助功能」中授予权限，
        // 否则这里的 Cmd+V 事件不会生效。
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand

        if let targetPID {
            keyDown?.postToPid(targetPID)
            keyUp?.postToPid(targetPID)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}

final class ClipboardPasteService {
    private let writer: PasteboardWriting
    private let keyPoster: KeyEventPosting
    private let pasteDelay: TimeInterval
    private let maxWaitForDeactivate: TimeInterval
    private let pollInterval: TimeInterval
    private let isAppActive: () -> Bool

    init(
        writer: PasteboardWriting = SystemPasteboardWriter(),
        keyPoster: KeyEventPosting = SystemKeyEventPoster(),
        pasteDelay: TimeInterval = 0.08,
        maxWaitForDeactivate: TimeInterval = 1.2,
        pollInterval: TimeInterval = 0.02,
        isAppActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.writer = writer
        self.keyPoster = keyPoster
        self.pasteDelay = pasteDelay
        self.maxWaitForDeactivate = maxWaitForDeactivate
        self.pollInterval = pollInterval
        self.isAppActive = isAppActive
    }

    func paste(
        entry: ClipboardEntry,
        close: (() -> Void)?,
        isReadyToPaste: (() -> Bool)? = nil,
        targetPID: pid_t? = nil
    ) {
        guard writeEntry(entry) else { return }

        close?()

        let ready = isReadyToPaste ?? { !self.isAppActive() }
        waitForDeactivateAndPaste(startTime: Date(), isReadyToPaste: ready, targetPID: targetPID)
    }

    private func waitForDeactivateAndPaste(
        startTime: Date,
        isReadyToPaste: @escaping () -> Bool,
        targetPID: pid_t?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            self?.attemptPaste(startTime: startTime, isReadyToPaste: isReadyToPaste, targetPID: targetPID)
        }
    }

    private func attemptPaste(
        startTime: Date,
        isReadyToPaste: @escaping () -> Bool,
        targetPID: pid_t?
    ) {
        if isReadyToPaste() {
            // 就绪后优先走系统分发，兼容性更高；超时后再回落到定向 PID。
            keyPoster.postCommandV(targetPID: nil)
            return
        }

        if Date().timeIntervalSince(startTime) >= maxWaitForDeactivate {
            keyPoster.postCommandV(targetPID: targetPID)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.attemptPaste(startTime: startTime, isReadyToPaste: isReadyToPaste, targetPID: targetPID)
        }
    }

    private func writeEntry(_ entry: ClipboardEntry) -> Bool {
        switch entry.content {
        case .text(nil), .image(nil), .rtf(nil), .unknown(nil):
            return false
        default:
            break
        }

        writer.clearContents()
        switch entry.content {
        case .text(let text?):
            writer.setString(text, forType: .string)
        case .url(let url):
            writer.setString(url.absoluteString, forType: .string)
            writer.setString(url.absoluteString, forType: .URL)
            writer.writeObjects([url as NSURL])
        case .files(let urls):
            writer.writeObjects(urls as [NSURL])
        case .image(let data?):
            if let image = NSImage(data: data) {
                writer.writeObjects([image])
            } else {
                writer.setData(data, forType: .png)
            }
        case .rtf(let data?):
            writer.setData(data, forType: .rtf)
        case .unknown(let data?):
            writer.setData(data, forType: NSPasteboard.PasteboardType("public.data"))
        case .text(nil), .image(nil), .rtf(nil), .unknown(nil):
            preconditionFailure("写入前已验证剪贴板内容必须完整加载")
        }
        return true
    }
}
