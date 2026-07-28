import AppKit
import Carbon
import SwiftUI

// MARK: - 可测状态机（不注册全局热键、不触碰 KeyboardShortcuts）

enum KeepAwakeHotkeyRecorderPhase: Equatable {
    case idle
    case recording
}

/// 本地按键录制状态；只编辑 HotkeyDefinition，不创建全局注册。
@MainActor
final class KeepAwakeHotkeyRecorderState: ObservableObject {
    @Published private(set) var phase: KeepAwakeHotkeyRecorderPhase = .idle
    @Published private(set) var hotkey: HotkeyDefinition

    private let apply: (HotkeyDefinition) -> Void

    init(initial: HotkeyDefinition, apply: @escaping (HotkeyDefinition) -> Void) {
        self.hotkey = initial
        self.apply = apply
    }

    func beginRecording() {
        phase = .recording
    }

    func cancel() {
        phase = .idle
    }

    /// 清除录制态；不调用 apply（由 View/设置层清空配置）。
    func clear() {
        phase = .idle
    }

    /// 处理本地 keyDown。返回 true 表示已消费并结束录制。
    @discardableResult
    func consume(_ event: NSEvent) -> Bool {
        guard phase == .recording else { return false }

        let keyCode = Int(event.keyCode)
        if keyCode == Int(kVK_Escape) {
            phase = .idle
            return true
        }

        let modifierCodes: Set<Int> = [
            Int(kVK_Command), Int(kVK_RightCommand),
            Int(kVK_Shift), Int(kVK_RightShift),
            Int(kVK_Option), Int(kVK_RightOption),
            Int(kVK_Control), Int(kVK_RightControl),
            Int(kVK_Function),
        ]
        if modifierCodes.contains(keyCode) {
            // modifier-only：保持 recording，不完成
            return false
        }

        let definition = HotkeyDefinition(
            keyCode: keyCode,
            modifiers: HotkeyModifiers(eventFlags: event.modifierFlags)
        )
        hotkey = definition
        phase = .idle
        apply(definition)
        return true
    }
}

// MARK: - SwiftUI 薄封装

struct KeepAwakeHotkeyRecorderView: View {
    @ObservedObject var state: KeepAwakeHotkeyRecorderState
    let strings: Strings

    var body: some View {
        HStack(spacing: 8) {
            Text(displayText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(phase == .recording ? strings.keepAwakeCancelRecording : strings.keepAwakeRecord) {
                if phase == .recording {
                    state.cancel()
                } else {
                    state.beginRecording()
                }
            }
            .buttonStyle(.bordered)
        }
        .background(KeepAwakeLocalKeyMonitor(isActive: phase == .recording) { event in
            _ = state.consume(event)
        })
    }

    private var phase: KeepAwakeHotkeyRecorderPhase { state.phase }

    private var displayText: String {
        phase == .recording ? "…" : state.hotkey.displayString
    }
}

/// 仅在录制时安装本地 keyDown monitor；不注册全局热键。
private struct KeepAwakeLocalKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.parent = self
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator {
        var parent: KeepAwakeLocalKeyMonitor
        private var monitor: Any?

        init(parent: KeepAwakeLocalKeyMonitor) {
            self.parent = parent
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func setActive(_ active: Bool) {
            if active {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.parent.onKey(event)
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
