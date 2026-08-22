import SwiftUI
import AppKit

/// Relative bar width for process ranking rows (value vs list max).
enum ProcessUsageShare {
    /// `maxValue <= 0` → 0; otherwise clamp to 0...1.
    static func fraction(value: Double, maxValue: Double) -> Double {
        guard maxValue > 0 else { return 0 }
        return min(max(value / maxValue, 0), 1)
    }
}

/// Shared process value formatting for ranking rows.
enum ProcessUsageFormatting {
    static func valueText(for proc: ProcessUsage, kind: ProcessMetricKind) -> String {
        switch kind {
        case .network:
            let down = MetricFormat.bytesPerSec(proc.networkDownBytesPerSec) ?? "--"
            let up = MetricFormat.bytesPerSec(proc.networkUpBytesPerSec) ?? "--"
            return "↓\(down) ↑\(up)"
        case .memory:
            return MetricFormat.bytes(UInt64(max(0, proc.value.rounded())))
        case .cpu, .gpu, .energy:
            return String(format: "%.1f%%", proc.value)
        }
    }
}

/// Heuristic SF Symbol for a process name (ranking row icon).
enum ProcessUsageIcon {
    static func systemImage(forProcessName name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("terminal")
            || lower.contains("iterm")
            || lower.contains("zsh")
            || lower.contains("bash")
            || lower.contains("fish")
            || lower.contains("shell")
            || lower.hasPrefix("ssh")
        {
            return "terminal"
        }
        if lower.contains("chrome") || lower.contains("safari") || lower.contains("firefox") || lower.contains("browser") {
            return "globe"
        }
        if lower.contains("xcode") || lower.contains("code") || lower.contains("cursor") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if lower.contains("finder") {
            return "folder"
        }
        if lower.contains("mail") {
            return "envelope"
        }
        if lower.contains("music") || lower.contains("spotify") {
            return "music.note"
        }
        return "app"
    }
}

/// One process ranking row: icon, name, monospaced value, relative share bar.
struct ProcessUsageRankRow: View {
    let name: String
    let valueText: String
    let share: Double
    let accent: Color
    /// 真实 app 图标（按 pid 解析，nil 时走 `fallbackSymbol`）。
    let icon: NSImage?
    /// 无 app 图标的系统进程兜底 SF Symbol（terminal/app 等）。
    let fallbackSymbol: String
    /// 是否处于"待终止"确认态（图标已变为红❌）。
    let isArmed: Bool
    /// 该进程是否允许被终止（系统关键进程/自身为 false，点击不响应）。
    let canTerminate: Bool
    /// 点击图标的回调：第一次 arm、第二次（armed）执行终止。
    let onIconTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            iconBadge

            Text(name)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(valueText)
                .font(Theme.Stats.font11Regular.monospacedDigit())
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            MetricBar(value: MetricBar.clamp(share), warning: 101, critical: 101, tint: accent)
                .frame(width: 56)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var iconBadge: some View {
        Button(action: onIconTap) {
            Group {
                if isArmed {
                    // 待终止确认态：红色❌，提示再次点击将终止进程。
                    ZStack {
                        Circle()
                            .fill(Theme.Stats.up.opacity(colorScheme == .dark ? 0.28 : 0.18))
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.Stats.up)
                    }
                } else if let icon {
                    // 真实 app 图标自带彩色 squircle，直接居中显示，无需 accent 底块。
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    // 无 app 图标的系统进程：accent 圆角块 + 兜底 SF Symbol。
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
            }
            .frame(width: 22, height: 22)
            // 可终止时悬停提示可点击；系统关键进程淡化，表明不可操作。
            .opacity(canTerminate ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!canTerminate)
        .accessibilityHidden(true)
    }
}
