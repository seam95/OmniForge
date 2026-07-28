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

struct HotkeyRecorderView: View {
    let displayText: String
    let onShortcutChanged: (KeyboardShortcuts.Shortcut?) -> Void
    @ObservedObject var l10n: L10n
    @StateObject private var state: HotkeyRecorderState

    init(
        displayText: String,
        onShortcutChanged: @escaping (KeyboardShortcuts.Shortcut?) -> Void,
        l10n: L10n
    ) {
        self.displayText = displayText
        self.onShortcutChanged = onShortcutChanged
        self._l10n = ObservedObject(wrappedValue: l10n)
        self._state = StateObject(
            wrappedValue: HotkeyRecorderState(
                initialDisplayText: displayText,
                apply: onShortcutChanged
            )
        )
    }

    var body: some View {
        Button {
            if state.phase == .recording {
                state.cancel()
            } else {
                state.beginRecording()
            }
        } label: {
            Text(buttonTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minWidth: 130)
        }
        .buttonStyle(.bordered)
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
