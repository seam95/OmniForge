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
            let line: String = {
                if let endDate {
                    let endText = KeepAwakeControlCountdownFormatter.endTimeText(endDate: endDate, now: now)
                    return String(format: strings.keepAwakeTooltipActiveTimed, endText)
                } else {
                    return strings.keepAwakeStatusActiveIndefinite
                }
            }()
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
        VStack(alignment: .leading, spacing: 10) {
            // 主卡：开关 + 状态区（时长选择 / 倒计时 / 无限期 / 重试清理）
            mainCard

            // 合盖时保持唤醒卡片
            clamshellCard

            // 错误横幅（配置写入失败或运行期错误摘要）
            if let errorText = config.configError ?? presentation.secondaryStatusLine {
                errorBanner(errorText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - 主卡
    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：图标 + 标题/状态 + 开关
            HStack(alignment: .center, spacing: 12) {
                statusIconBlock

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                        .lineLimit(1)
                    Text(presentation.statusLine)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.Stats.down)
                    .disabled(!presentation.isSessionToggleEnabled)
                    .accessibilityLabel(presentation.title)
            }
            .padding(12)

            // 状态区
            if presentation.showsDurationPicker {
                cardDivider
                durationPickerSection
            } else if presentation.countdownEndDate != nil {
                cardDivider
                activeTimedSection
            } else if presentation.showsRetryCleanupButton {
                cardDivider
                retryCleanupSection
            }
        }
        .background(cardBackground)
    }

    /// 唤醒中视觉态：开关拨向开（含开启中）即点亮图标。
    private var isAwakeVisual: Bool {
        presentation.isSessionToggleOn
    }

    private var statusIconBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(iconBackground)
            Image(systemName: isAwakeVisual ? "moon.zzz.fill" : "moon")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isAwakeVisual ? Theme.Stats.down : (colorScheme == .light ? Theme.Stats.text1 : Color.primary))
        }
        .frame(width: 38, height: 38)
        .animation(Theme.Animation.hover, value: isAwakeVisual)
    }

    private var iconBackground: Color {
        if isAwakeVisual {
            return Theme.Stats.down.opacity(colorScheme == .light ? 0.12 : 0.22)
        }
        return colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(colorScheme == .light ? Theme.Stats.separator : Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    // MARK: - 状态区：时长选择（未开启）
    private var durationPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings.keepAwakeDurationLabel)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)

            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    let isSelected = (config.defaultDurationMinutes.wrappedValue == preset.duration.minutes)
                    Button {
                        config.defaultDurationMinutes.wrappedValue = preset.duration.minutes
                        onSetDuration(preset.duration)
                    } label: {
                        Text(preset.labelKey(strings))
                            .font(Theme.Stats.font12Medium)
                            .foregroundStyle(isSelected ? Color.white : (colorScheme == .light ? Theme.Stats.text2 : Color.primary))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : (colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08)))
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
                }
            }
        }
        .padding(12)
    }

    // MARK: - 状态区：定时会话倒计时
    private var activeTimedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.keepAwakeRemainingLabel)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    if let endDate = presentation.countdownEndDate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(KeepAwakeControlCountdownFormatter.text(endDate: endDate, now: context.date, strings: strings))
                                .font(Theme.Stats.font24Bold.monospacedDigit())
                                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                                .contentTransition(.numericText())
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(strings.keepAwakeEndsAtLabel)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    if let endDate = presentation.countdownEndDate {
                        Text(KeepAwakeControlCountdownFormatter.endTimeText(endDate: endDate))
                            .font(Theme.Stats.font13SemiBold)
                            .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.primary)
                    }
                }
            }

            if presentation.showsExtendButtons {
                HStack(spacing: 8) {
                    extendChip(minutes: 15, label: strings.keepAwakeDuration15m)
                    extendChip(minutes: 60, label: strings.keepAwakeDuration1h)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
    }

    private func extendChip(minutes: Int, label: String) -> some View {
        Button {
            onExtend(minutes)
        } label: {
            Text("+ \(label)")
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(Theme.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.accentColor.opacity(colorScheme == .light ? 0.10 : 0.18))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .accessibilityLabel(label)
    }

    // MARK: - 状态区：重试清理
    private var retryCleanupSection: some View {
        Button {
            onRetryCleanup()
        } label: {
            Text(presentation.retryCleanupLabel)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(Theme.Stats.up)
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
        .padding(12)
    }

    // MARK: - 合盖时保持唤醒卡片
    private var clamshellCard: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(config.clamshellPreferred.wrappedValue
                        ? Theme.Stats.down.opacity(colorScheme == .light ? 0.12 : 0.22)
                        : (colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08)))
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(config.clamshellPreferred.wrappedValue
                        ? Theme.Stats.down
                        : (colorScheme == .light ? Theme.Stats.text1 : Color.primary))
            }
            .frame(width: 38, height: 38)
            .animation(Theme.Animation.hover, value: config.clamshellPreferred.wrappedValue)

            VStack(alignment: .leading, spacing: 2) {
                Text(strings.keepAwakeClamshellTitle)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Text(strings.keepAwakeClamshellSubtitle)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                if config.clamshellPreferred.wrappedValue {
                    Text(presentation.clamshellStatusLine ?? strings.keepAwakeClamshellFootnote)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: config.clamshellPreferred)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.Stats.down)
                .disabled(!presentation.clamshellToggleEnabled)
                .accessibilityLabel(strings.keepAwakeClamshellTitle)
        }
        .padding(12)
        .background(cardBackground)
    }

    // MARK: - 错误横幅
    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Stats.up)
            Text(text)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(Theme.Stats.up)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.Stats.up.opacity(colorScheme == .light ? 0.08 : 0.16))
        )
    }

    // MARK: - 卡片背景样式
    private var cardBackground: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.08)
            } else {
                Theme.Stats.cardBackground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
