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
    var clamshellStatusLine: String?
    var startLabel: String
    var stopLabel: String
    var retryCleanupLabel: String
    var unavailableLabel: String

    // 新增：控制中心 Toggle / 分区 / 倒计时
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
            if let lastError {
                status = String(
                    format: strings.keepAwakeStatusNotActiveWithError,
                    shortError(lastError)
                )
            } else {
                status = strings.keepAwakeStatusNormalSleep
            }
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: true,
                primaryAction: .start,
                showsExtendButtons: false,
                showsDurationPicker: true,
                statusLine: status,
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
                // inactive：lastError 已并入 statusLine；secondary 仅含 pointer/battery
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
            return KeepAwakeControlPresentation(
                title: strings.keepAwakeTitle,
                isPrimaryEnabled: true,
                primaryAction: .stop,
                showsExtendButtons: timed,
                showsDurationPicker: false,
                statusLine: timed
                    ? strings.keepAwakeStatusActiveTimed
                    : strings.keepAwakeStatusActiveIndefinite,
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

// MARK: - View（依赖注入 presentation / config；无 Manager 时显示不可用）

struct KeepAwakeControlView: View {
    let presentation: KeepAwakeControlPresentation
    var config: KeepAwakeControlConfigBindings = .previewDisabled
    var strings: Strings = .en
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetryCleanup: () -> Void = {}
    var onExtend: (Int) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    /// 与 MainDashboardView 一致的控制中心强调色。
    private var accentColor: Color {
        Theme.accentColor
    }

    private var cardBackgroundMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    private var separatorStrokeColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    var body: some View {
        // 不用无界 ScrollView 撑满父级：控制中心按内容固有高度收缩 popover。
        // 内容偶发超过上限时，由 ControlCenterContainerView 的 maxHeight 裁剪承接。
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = config.configError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if presentation.showsSessionCard {
                sessionCard
            }

            if presentation.showsOptionsSection && config.mouseJiggleEnabled.wrappedValue {
                optionsCard
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // 标题行 + 主开关（switch，与输入法锁定页一致）
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(presentation.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let secondary = presentation.secondaryStatusLine {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accentColor)
                .disabled(!presentation.isSessionToggleEnabled)
                .accessibilityLabel(presentation.title)
        }
    }

    // 主会话卡片：时长 / 倒计时 / 关闭时刻 / 延长 / 清理 / 合盖（合并为一张，避免双卡片）。
    @ViewBuilder
    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if presentation.showsDurationPicker {
                settingsRow(title: strings.keepAwakeDurationLabel) {
                    Picker("", selection: config.defaultDurationMinutes) {
                        Text(strings.keepAwakeDurationIndefinite).tag(0)
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 15)).tag(15)
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 30)).tag(30)
                        Text(String(format: strings.keepAwakeDurationHoursFormat, 1)).tag(60)
                        Text(String(format: strings.keepAwakeDurationHoursFormat, 2)).tag(120)
                        Text(String(format: strings.keepAwakeDurationHoursFormat, 4)).tag(240)
                        Text(String(format: strings.keepAwakeDurationHoursFormat, 8)).tag(480)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 140, alignment: .trailing)
                }
            }

            // 局部 TimelineView 秒级刷新，不重建整页。
            if let endDate = presentation.countdownEndDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow(title: strings.keepAwakeRemainingLabel) {
                            Text(
                                KeepAwakeControlCountdownFormatter.text(
                                    endDate: endDate,
                                    now: context.date,
                                    strings: strings
                                )
                            )
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        settingsRow(title: strings.keepAwakeEndsAtLabel) {
                            Text(
                                KeepAwakeControlCountdownFormatter.endTimeText(
                                    endDate: endDate,
                                    now: context.date
                                )
                            )
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let countdown = presentation.countdownText {
                settingsRow(title: strings.keepAwakeRemainingLabel) {
                    Text(countdown)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if presentation.showsExtendButtons {
                HStack(spacing: 8) {
                    extendButton("+15") { onExtend(15) }
                    extendButton("+30") { onExtend(30) }
                    extendButton("+60") { onExtend(60) }
                }
            }

            if presentation.showsRetryCleanupButton {
                Button(presentation.retryCleanupLabel) { onRetryCleanup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if presentation.showsClamshellSection {
                featureRow(
                    title: strings.keepAwakeClamshellAction,
                    helpText: strings.keepAwakeClamshellCaption,
                    isOn: config.clamshellPreferred,
                    enabled: presentation.clamshellToggleEnabled
                )
                if let line = presentation.clamshellStatusLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(sectionCard)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.keepAwakeOptionsSection)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if config.mouseJiggleEnabled.wrappedValue {
                settingsRow(title: strings.keepAwakeJiggleInterval) {
                    Picker("", selection: config.mouseJiggleIntervalMinutes) {
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 1)).tag(1)
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 2)).tag(2)
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 5)).tag(5)
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 10)).tag(10)
                        Text(String(format: strings.keepAwakeDurationMinutesFormat, 15)).tag(15)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 120, alignment: .trailing)
                }

                Text(strings.keepAwakeJiggleCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(strings.keepAwakeRequestAccessibility) {
                    config.onRequestAccessibility()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)
            }
        }
        .padding(12)
        .background(sectionCard)
    }

    private var sectionCard: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.06)
            } else {
                Color.white.opacity(0.55)
            }
        }
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04),
            radius: 6,
            x: 0,
            y: 1.5
        )
    }

    private func featureRow(
        title: String,
        subtitle: String? = nil,
        helpText: String? = nil,
        isOn: Binding<Bool>,
        enabled: Bool = true
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FeatureTitleWithHelp(title: title, helpText: helpText)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accentColor)
                .disabled(!enabled)
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func extendButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
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

/// 标题 + 问号；问号用 AppKit NSPopover，鼠标进入立即显示说明。
private struct FeatureTitleWithHelp: View {
    let title: String
    let helpText: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let helpText {
                InstantHelpIcon(text: helpText)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(helpText)
            }
        }
    }
}

/// 菜单栏 popover 内即时说明：系统 `.help` 延迟大，SwiftUI overlay 易被裁剪；
/// 使用独立 NSView + NSPopover，mouseEntered 立即弹出。
private struct InstantHelpIcon: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> InstantHelpIconNSView {
        InstantHelpIconNSView(helpText: text)
    }

    func updateNSView(_ nsView: InstantHelpIconNSView, context: Context) {
        nsView.helpText = text
    }
}

private final class InstantHelpIconNSView: NSView {
    var helpText: String {
        didSet {
            toolTip = helpText
            if popover.isShown {
                (popover.contentViewController as? HelpTextViewController)?.setText(helpText)
            }
        }
    }

    private var tracking: NSTrackingArea?
    private let imageView = NSImageView()
    private let popover = NSPopover()
    private var dismissWorkItem: DispatchWorkItem?

    init(helpText: String) {
        self.helpText = helpText
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = helpText

        let symbol = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: helpText
        )
        imageView.image = symbol
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18),
        ])

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = HelpTextViewController(text: helpText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        showHelpImmediately()
    }

    override func mouseExited(with event: NSEvent) {
        // 短暂延迟关闭，避免移向气泡时闪断；仍比系统 help 快得多。
        let work = DispatchWorkItem { [weak self] in
            self?.popover.performClose(nil)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showHelpImmediately()
        }
    }

    private func showHelpImmediately() {
        guard window != nil else { return }
        (popover.contentViewController as? HelpTextViewController)?.setText(helpText)
        if !popover.isShown {
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        }
    }
}

private final class HelpTextViewController: NSViewController {
    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String) {
        super.init(nibName: nil, bundle: nil)
        setText(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: .zero)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        view = container
    }

    func setText(_ text: String) {
        label.stringValue = text
    }
}
