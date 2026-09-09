import AppKit
import ApplicationServices
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
    func postCommandV()
    func postCommandC()
}

/// 模拟 Cmd+V / Cmd+C 注入到当前会话（对齐 Maccy 的 Clipboard.paste 实现）。
final class SystemKeyEventPoster: KeyEventPosting {
    /// 低位 0x8 为区分左/右修饰键的设备依赖标志位，部分应用要求其存在才响应合成 Cmd 组合键。
    private static let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)

    func postCommandV() {
        postCommand(keyCode: CGKeyCode(kVK_ANSI_V))
    }

    func postCommandC() {
        postCommand(keyCode: CGKeyCode(kVK_ANSI_C))
    }

    private func postCommand(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // 粘贴瞬间抑制本地物理键盘事件，防止用户物理按键（如回车的 keyUp）与合成 Cmd+V 竞态混入。
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = Self.commandFlags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = Self.commandFlags
        // 必须走 session tap：macOS 26 起 WindowServer 校验合成事件来源，
        // HID tap 注入的合成事件在部分分发路径被静默丢弃（需「辅助功能」权限，否则同样不生效）。
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}

final class ClipboardPasteService {
    private let writer: PasteboardWriting
    private let keyPoster: KeyEventPosting
    private let isAccessibilityGranted: () -> Bool
    private let onAccessibilityDenied: () -> Void

    init(
        writer: PasteboardWriting = SystemPasteboardWriter(),
        keyPoster: KeyEventPosting = SystemKeyEventPoster(),
        isAccessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        onAccessibilityDenied: @escaping () -> Void = {
            // 触发系统授权弹窗（自带「打开系统设置」入口）；仅用 C API 以规避严格并发限制。
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    ) {
        self.writer = writer
        self.keyPoster = keyPoster
        self.isAccessibilityGranted = isAccessibilityGranted
        self.onAccessibilityDenied = onAccessibilityDenied
    }

    /// 写入系统剪贴板并注入 Cmd+V 粘贴回原输入框。
    ///
    /// 前提：剪贴板面板为 nonactivating（呼出期间原应用从未失去键盘焦点），
    /// 因此 close（面板 orderOut）后立即注入即可命中原输入框，无需任何焦点恢复与等待。
    func paste(entry: ClipboardEntry, close: (() -> Void)?) {
        guard writeEntry(entry) else { return }

        close?()

        // 无「辅助功能」权限时合成按键会静默失效：此时剪贴板内容已写入（可手动 Cmd+V 补救），改为引导授权。
        guard isAccessibilityGranted() else {
            onAccessibilityDenied()
            return
        }
        keyPoster.postCommandV()
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
