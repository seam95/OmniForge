import AppKit
import SwiftUI

struct FeatureRunStateRow: View {
    let state: FeatureRunState
    let strings: Strings
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if state == .waitingPermission {
                Button(strings.permissionOpenSettings, action: openAccessibilitySettings)
                    .controlSize(.small)
            } else if case .failed = state, let retry {
                Button(strings.actionRetry, action: retry)
                    .controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch state {
        case .stopped: return strings.runStateStopped
        case .running: return strings.runStateRunning
        case .waitingPermission: return strings.runStateWaitingPermission
        case let .failed(message): return String(format: strings.runStateFailed, message)
        }
    }

    private var symbolName: String {
        switch state {
        case .stopped: return "stop.circle"
        case .running: return "checkmark.circle.fill"
        case .waitingPermission: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .stopped: return .secondary
        case .running: return .green
        case .waitingPermission: return .orange
        case .failed: return .red
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
