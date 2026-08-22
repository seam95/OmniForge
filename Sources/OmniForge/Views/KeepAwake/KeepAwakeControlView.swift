import AppKit
import SwiftUI

// MARK: - 控制中心纯状态模型（UI 不触碰系统客户端）

enum KeepAwakeControlPrimaryAction: Equatable {
    case start
    case stop
    case retryCleanup
    case none
}

struct KeepAwakeControlPresentation: Equatable {
    var title: String
    var isPrimaryEnabled: Bool
    var primaryAction: KeepAwakeControlPrimaryAction
    var showsExtendButtons: Bool
    var showsDurationPicker: Bool
    var statusLine: String
    var statusSubtitle: String
    var clamshellStatusLine: String?
    var startLabel: String
    var stopLabel: String
    var retryCleanupLabel: String
    var unavailableLabel: String

    // 控制中心 Toggle / 分区 / 倒计时
    var isSessionToggleOn: Bool
    var isSessionToggleEnabled: Bool
    var showsRetryCleanupButton: Bool
    /// 模型层静态倒计时快照（便于纯函数测试）；View 优先用 countdownEndDate + TimelineView。
    var countdownText: String?
    /// 活动定时会话的结束时刻；非 nil 时 View 用内部 TimelineView 实时刷新，避免整页重建。
    var countdownEndDate: Date?
    var showsOptionsSection: Bool
    var showsClamshellSection: Bool
    var clamshellToggleEnabled: Bool
    var secondaryStatusLine: String?

    /// 会话区是否有可渲染内容；含合盖行时即使无限期也会显示，避免双卡片。
    var showsSessionCard: Bool {
        showsDurationPicker
            || showsExtendButtons
            || showsRetryCleanupButton
            || countdownEndDate != nil
            || countdownText != nil
            || showsClamshellSection
    }
}

/// 控制中心剩余时间：>0 时 `H:MM:SS`（>=1h）或 `M:SS`；<=0 为 `0:00`。不显示负数。
enum KeepAwakeControlCountdownFormatter {
    static func text(endDate: Date, now: Date, strings: Strings = .en) -> String {
        _ = strings
        let remaining = max(0, Int(endDate.timeIntervalSince(now).rounded(.down)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// 关闭时刻：同日只显示短时间；跨日附加短日期。
    static func endTimeText(endDate: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDate(endDate, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        }
        return formatter.string(from: endDate)
    }
}

enum KeepAwakeControlPresentationBuilder {
    static func build(
        session: KeepAwakeSessionState,
        clamshell: ClamshellState,
        lastError: KeepAwakeError?,
        blocksStart: Bool,
        isFeatureAvailable: Bool,
        now: Date = Date(),
        pointerError: KeepAwakeError? = nil,
        batteryError: KeepAwakeError? = nil,
        strings: Strings = .en
    ) -> KeepAwakeControlPresentation {
        let labels = actionLabels(strings)
        let secondary = secondaryLine(
            lastError: lastError,
            pointerError: pointerError,
            batteryError: batteryError,
            session: session,
            strings: strings
        )

        guard isFeatureAvailable else {
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: false,
                primaryAction: .none,
                showsExtendButtons: false,
                showsDurationPicker: false,
                statusLine: strings.keepAwakeStatusFeatureUnavailable,
                statusSubtitle: String(format: strings.keepAwakeStatusCurrentPrefix, strings.keepAwakeStatusFeatureUnavailable),
                clamshellStatusLine: nil,
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: false,
                isSessionToggleEnabled: false,
                showsRetryCleanupButton: false,
                countdownText: nil,
                countdownEndDate: nil,
                showsOptionsSection: false,
                showsClamshellSection: false,
                clamshellToggleEnabled: false,
                secondaryStatusLine: secondary
            )
        }

        if blocksStart {
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: false,
                primaryAction: .none,
                showsExtendButtons: false,
                showsDurationPicker: false,
                statusLine: strings.keepAwakeStatusWaitingRecovery,
                statusSubtitle: String(format: strings.keepAwakeStatusCurrentPrefix, strings.keepAwakeStatusWaitingRecovery),
                clamshellStatusLine: nil,
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: false,
                isSessionToggleEnabled: false,
                showsRetryCleanupButton: false,
                countdownText: nil,
                countdownEndDate: nil,
                showsOptionsSection: false,
                showsClamshellSection: false,
                clamshellToggleEnabled: false,
                secondaryStatusLine: secondary
            )
        }

        switch session {
        case .inactive:
            let status: String
            let subtitle: String
            if let lastError {
                let errText = shortError(lastError)
                status = String(format: strings.keepAwakeStatusNotActiveWithError, errText)
                subtitle = String(format: strings.keepAwakeStatusCurrentPrefix, status)
            } else {
                status = strings.keepAwakeStatusNormalSleep
                subtitle = String(format: strings.keepAwakeStatusCurrentPrefix, strings.keepAwakeStatusNormalSleep)
            }
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: true,
                primaryAction: .start,
                showsExtendButtons: false,
                showsDurationPicker: true,
                statusLine: status,
                statusSubtitle: subtitle,
                clamshellStatusLine: nil,
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: false,
                isSessionToggleEnabled: true,
                showsRetryCleanupButton: false,
                countdownText: nil,
                countdownEndDate: nil,
                showsOptionsSection: true,
                showsClamshellSection: true,
                clamshellToggleEnabled: true,
                secondaryStatusLine: secondary
            )
        case .activating:
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: true,
                primaryAction: .stop,
                showsExtendButtons: false,
                showsDurationPicker: false,
                statusLine: strings.keepAwakeStatusStarting,
                statusSubtitle: String(format: strings.keepAwakeStatusCurrentPrefix, strings.keepAwakeStatusStarting),
                clamshellStatusLine: nil,
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: true,
                isSessionToggleEnabled: false,
                showsRetryCleanupButton: false,
                countdownText: nil,
                countdownEndDate: nil,
                showsOptionsSection: true,
                showsClamshellSection: true,
                clamshellToggleEnabled: true,
                secondaryStatusLine: secondary
            )
        case .active(let endDate):
            let timed = endDate != nil
            let countdown: String? = {
                guard let endDate else { return nil }
                return KeepAwakeControlCountdownFormatter.text(
                    endDate: endDate,
                    now: now,
                    strings: strings
                )
            }()
            let line = timed
                ? strings.keepAwakeStatusActiveTimed
                : strings.keepAwakeStatusActiveIndefinite
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: true,
                primaryAction: .stop,
                showsExtendButtons: timed,
                showsDurationPicker: false,
                statusLine: line,
                statusSubtitle: String(format: strings.keepAwakeStatusCurrentPrefix, line),
                clamshellStatusLine: clamshellLine(clamshell, strings: strings),
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: true,
                isSessionToggleEnabled: true,
                showsRetryCleanupButton: false,
                countdownText: countdown,
                countdownEndDate: endDate,
                showsOptionsSection: true,
                showsClamshellSection: true,
                clamshellToggleEnabled: true,
                secondaryStatusLine: secondary
            )
        case .deactivating:
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: false,
                primaryAction: .none,
                showsExtendButtons: false,
                showsDurationPicker: false,
                statusLine: strings.keepAwakeStatusStopping,
                statusSubtitle: String(format: strings.keepAwakeStatusCurrentPrefix, strings.keepAwakeStatusStopping),
                clamshellStatusLine: nil,
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: false,
                isSessionToggleEnabled: false,
                showsRetryCleanupButton: false,
                countdownText: nil,
                countdownEndDate: nil,
                showsOptionsSection: true,
                showsClamshellSection: true,
                clamshellToggleEnabled: false,
                secondaryStatusLine: secondary
            )
        case .cleanupRequired:
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: true,
                primaryAction: .retryCleanup,
                showsExtendButtons: false,
                showsDurationPicker: false,
                statusLine: strings.keepAwakeStatusCleanupRequired,
                statusSubtitle: String(format: strings.keepAwakeStatusCurrentPrefix, strings.keepAwakeStatusCleanupRequired),
                clamshellStatusLine: clamshellLine(clamshell, strings: strings),
                startLabel: labels.start,
                stopLabel: labels.stop,
                retryCleanupLabel: labels.retry,
                unavailableLabel: labels.unavailable,
                isSessionToggleOn: false,
                isSessionToggleEnabled: false,
                showsRetryCleanupButton: true,
                countdownText: nil,
                countdownEndDate: nil,
                showsOptionsSection: true,
                showsClamshellSection: true,
                clamshellToggleEnabled: false,
                secondaryStatusLine: secondary
            )
        }
    }

    private static func actionLabels(_ strings: Strings) -> (
        start: String,
        stop: String,
        retry: String,
        unavailable: String
    ) {
        (
            strings.keepAwakeStart,
            strings.keepAwakeStop,
            strings.keepAwakeRetryCleanup,
            strings.keepAwakeUnavailable
        )
    }

    private static func clamshellLine(_ state: ClamshellState, strings: Strings) -> String? {
        switch state {
        case .off: return nil
        case .checking: return strings.keepAwakeClamshellChecking
        case .authorizing: return strings.keepAwakeClamshellAuthorizing
        case .enabling: return strings.keepAwakeClamshellEnabling
        case .active: return strings.keepAwakeClamshellActive
        case .restoring: return strings.keepAwakeClamshellRestoring
        case .conflict: return strings.keepAwakeClamshellConflict
        case .failed: return strings.keepAwakeClamshellFailed
        }
    }

    private static func shortError(_ error: KeepAwakeError) -> String {
        switch error {
        case .systemAssertionFailed: return "system assertion failed"
        case .displayAssertionFailed: return "display assertion failed"
        case .featureUnavailable: return "feature unavailable"
        case .operationInProgress: return "busy"
        case .accessibilityPermissionMissing: return "accessibility permission missing"
        case .pointerEventFailed: return "pointer event failed"
        case .batteryReadFailed: return "battery read failed"
        case .invalidPointerInterval: return "invalid pointer interval"
        case .invalidDuration: return "invalid duration"
        case .invalidBatteryLimit: return "invalid battery limit"
        case .alreadyActive: return "already active"
        case .alreadyInactive: return "already inactive"
        case .assertionReleaseFailed: return "assertion release failed"
        case .assertionRollbackFailed: return "assertion rollback failed"
        case .hotkeyRegistrationFailed: return "hotkey registration failed"
        case .administratorAuthorizationCancelled: return "authorization cancelled"
        case .clamshellUnsupported: return "clamshell unsupported"
        default: return "error"
        }
    }

    /// lastError 在 inactive 已并入 statusLine，其它态可作副文案；pointer/battery 始终可摘要。
    private static func secondaryLine(
        lastError: KeepAwakeError?,
        pointerError: KeepAwakeError?,
        batteryError: KeepAwakeError?,
        session: KeepAwakeSessionState,
        strings: Strings
    ) -> String? {
        _ = strings
        var parts: [String] = []
        if case .inactive = session {
            // inactive：lastError 已写进 statusLine，不重复
        } else if let lastError {
            parts.append(shortError(lastError))
        }
        if let pointerError {
            parts.append(shortError(pointerError))
        }
        if let batteryError {
            parts.append(shortError(batteryError))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Config bindings（配置 Binding + 回调；默认预览/未接线）

struct KeepAwakeControlConfigBindings {
    var defaultDurationMinutes: Binding<Int>
    var autoStart: Binding<Bool>
    var mouseJiggleEnabled: Binding<Bool>
    var mouseJiggleIntervalMinutes: Binding<Int>
    var clamshellPreferred: Binding<Bool>
    var onRequestAccessibility: () -> Void
    var onOpenKeepAwakeSettings: () -> Void
    /// 配置写入失败时的可见错误（可选）
    var configError: String?

    static var previewDisabled: KeepAwakeControlConfigBindings {
        KeepAwakeControlConfigBindings(
            defaultDurationMinutes: .constant(0),
            autoStart: .constant(false),
            mouseJiggleEnabled: .constant(false),
            mouseJiggleIntervalMinutes: .constant(5),
            clamshellPreferred: .constant(false),
            onRequestAccessibility: {},
            onOpenKeepAwakeSettings: {},
            configError: nil
        )
    }
}

// MARK: - View

struct KeepAwakeControlView: View {
    let presentation: KeepAwakeControlPresentation
    var config: KeepAwakeControlConfigBindings = .previewDisabled
    var strings: Strings = .en
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetryCleanup: () -> Void = {}
    var onExtend: (Int) -> Void = { _ in }
    var onSetDuration: (KeepAwakeDuration) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    private struct DurationPresetItem: Identifiable {
        let duration: KeepAwakeDuration
        let labelKey: (Strings) -> String

        var id: Int { duration.rawValue }
    }

    private let presets: [DurationPresetItem] = [
        DurationPresetItem(duration: .minutes15, labelKey: { $0.keepAwakeDuration15m }),
        DurationPresetItem(duration: .minutes60, labelKey: { $0.keepAwakeDuration1h }),
        DurationPresetItem(duration: .minutes240, labelKey: { $0.keepAwakeDuration4h }),
        DurationPresetItem(duration: .indefinite, labelKey: { $0.keepAwakeDurationNever }),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 卡片 1：保持唤醒主开关卡片
            mainToggleCard

            // 卡片 2：唤醒时长选择卡片
            durationSelectorCard

            // 卡片 3：合盖时保持唤醒卡片
            clamshellCard

            // 底部说明文案
            Text(strings.keepAwakeClamshellFootnote)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // 残留状态重试清理按钮（若需要）
            if presentation.showsRetryCleanupButton {
                Button(presentation.retryCleanupLabel) { onRetryCleanup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.horizontal, 4)
            }

            // 错误信息（若存在）
            if let error = config.configError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            } else if let secondary = presentation.secondaryStatusLine {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - 卡片 1：保持唤醒
    private var mainToggleCard: some View {
        HStack(alignment: .center, spacing: 12) {
            // 月亮图标圆角底块
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                Image(systemName: "moon")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 40, height: 40)

            // 标题与状态副文案
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(presentation.statusSubtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 绿色 Switch 开关
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .disabled(!presentation.isSessionToggleEnabled)
                .accessibilityLabel(presentation.title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(cardBackground)
    }

    // MARK: - 卡片 2：唤醒时长
    private var durationSelectorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.keepAwakeDurationLabel)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    let isSelected = (config.defaultDurationMinutes.wrappedValue == preset.duration.minutes)
                    Button {
                        config.defaultDurationMinutes.wrappedValue = preset.duration.minutes
                        onSetDuration(preset.duration)
                    } label: {
                        Text(preset.labelKey(strings))
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(cardBackground)
    }

    // MARK: - 卡片 3：合盖时保持唤醒
    private var clamshellCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(strings.keepAwakeClamshellTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(strings.keepAwakeClamshellSubtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                if let line = presentation.clamshellStatusLine {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: config.clamshellPreferred)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .disabled(!presentation.clamshellToggleEnabled)
                .accessibilityLabel(strings.keepAwakeClamshellTitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(cardBackground)
    }

    // MARK: - 卡片背景样式
    private var cardBackground: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.08)
            } else {
                Color.white
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), lineWidth: 0.8)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.03),
            radius: 4,
            x: 0,
            y: 1.5
        )
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { presentation.isSessionToggleOn },
            set: { newValue in
                if newValue {
                    onStart()
                } else {
                    onStop()
                }
            }
        )
    }
}
