import AppKit
import Carbon
import SwiftUI
import KeyboardShortcuts

enum HotkeyRecorderPhase: Equatable {
    case idle
    case recording
}

@MainActor
final class HotkeyRecorderState: ObservableObject {
    @Published private(set) var phase: HotkeyRecorderPhase = .idle
    @Published private(set) var displayText: String

    private let apply: (KeyboardShortcuts.Shortcut?) -> Void

    init(
        initialDisplayText: String,
        apply: @escaping (KeyboardShortcuts.Shortcut?) -> Void
    ) {
        self.displayText = initialDisplayText
        self.apply = apply
    }

    func beginRecording() {
        phase = .recording
    }

    func cancel() {
        phase = .idle
    }

    func syncDisplayText(_ nextDisplayText: String) {
        guard phase == .idle else { return }
        displayText = nextDisplayText
    }

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
            return false
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            return false
        }

        displayText = "\(shortcut)"
        phase = .idle
        apply(shortcut)
        return true
    }
}

/// 快捷键 recorder 的展示样式。
enum HotkeyRecorderStyle {
    /// 默认：系统 bordered 圆角按钮。
    case bordered
    /// 键帽样式：逐字符渲染 ⌘ ⇧ N 小键帽（便签管理页设计稿）。
    case keycaps
}

struct HotkeyRecorderView: View {
    let displayText: String
    let onShortcutChanged: (KeyboardShortcuts.Shortcut?) -> Void
    let style: HotkeyRecorderStyle
    @ObservedObject var l10n: L10n
    @StateObject private var state: HotkeyRecorderState
    @Environment(\.colorScheme) private var colorScheme

    init(
        displayText: String,
        onShortcutChanged: @escaping (KeyboardShortcuts.Shortcut?) -> Void,
        l10n: L10n,
        style: HotkeyRecorderStyle = .bordered
    ) {
        self.displayText = displayText
        self.onShortcutChanged = onShortcutChanged
        self.style = style
        self._l10n = ObservedObject(wrappedValue: l10n)
        self._state = StateObject(
            wrappedValue: HotkeyRecorderState(
                initialDisplayText: displayText,
                apply: onShortcutChanged
            )
        )
    }

    var body: some View {
        Group {
            if style == .keycaps {
                Button(action: toggleRecording) { keycapLabel }
                    .buttonStyle(.plain)
            } else {
                Button(action: toggleRecording) {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(minWidth: 130)
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityLabel(l10n.s.settingsClipboardHotkeyRecording)
        .background(HotkeyLocalKeyMonitor(isActive: state.phase == .recording) { event in
            _ = state.consume(event)
        })
        .onChange(of: displayText) { _, nextValue in
            state.syncDisplayText(nextValue)
        }
    }

    private var buttonTitle: String {
        state.phase == .recording ? l10n.s.settingsClipboardHotkeyRecording : state.displayText
    }

    private func toggleRecording() {
        if state.phase == .recording {
            state.cancel()
        } else {
            state.beginRecording()
        }
    }

    /// 键帽标签：录制中显示提示文案，否则逐字符渲染键帽。
    @ViewBuilder
    private var keycapLabel: some View {
        if state.phase == .recording {
            Text(l10n.s.settingsClipboardHotkeyRecording)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        } else {
            HStack(spacing: 3) {
                let characters = Array(state.displayText)
                if characters.isEmpty {
                    keycap("–")
                } else {
                    ForEach(characters.indices, id: \.self) { index in
                        keycap(String(characters[index]))
                    }
                }
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct HotkeyLocalKeyMonitor: NSViewRepresentable {
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
        var parent: HotkeyLocalKeyMonitor
        private var monitor: Any?

        init(parent: HotkeyLocalKeyMonitor) {
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
