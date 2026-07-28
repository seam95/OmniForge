import Foundation

// MARK: - 输入快照（所有订阅只更新此值，不直接写 AppKit）

/// 状态栏渲染输入；任意字段变化后由 builder 生成等值可比较的输出。
struct StatusBarRenderInput: Equatable {
    var isFeatureAvailable: Bool
    var sessionState: KeepAwakeSessionState
    var lastOperationError: KeepAwakeError?
    var showCountdown: Bool
    var isInputLocked: Bool
    var hideMainIconWhenMetricsVisible: Bool
    var hasVisibleMetrics: Bool
    var metricsSeparateItems: Bool
    /// 菜单栏刷新用“当前时间”；倒计时按分钟向上取整。
    var now: Date
}

// MARK: - 输出状态

enum StatusBarIconColorPolicy: Equatable {
    case template
    case tint(KeepAwakeIconTint)
    case cleanupWarning
}

enum StatusBarCountdownText: Equatable {
    case hidden
    case minutes(Int)
    case hoursMinutes(hours: Int, minutes: Int)
    case indefinite

    var displayString: String {
        switch self {
        case .hidden:
            return ""
        case .minutes(let n):
            return "\(n) min"
        case .hoursMinutes(let hours, let minutes):
            return String(format: "%d:%02d", hours, minutes)
        case .indefinite:
            return "∞"
        }
    }
}

enum StatusBarTooltipKind: Equatable {
    case inactive
    case inactiveWithError(summary: String)
    case activating
    case deactivating
    case activeTimed(endDate: Date)
    case activeIndefinite
    case cleanupRequired
}

enum StatusBarContextMenuModel: Equatable {
    case inactive(canRetryLastStart: Bool)
    case transitional
    case active
    case cleanupRequired
}

/// 单一 render 写入者消费的纯值状态。
struct StatusBarRenderState: Equatable {
    var mainItemVisible: Bool
    var iconColor: StatusBarIconColorPolicy
    var countdown: StatusBarCountdownText
    var showLockBadge: Bool
    var tooltip: StatusBarTooltipKind
    var contextMenu: StatusBarContextMenuModel
    /// 始终提供；菜单项是否启用由 model 决定。
    var includeOpenKeepAwakeSettings: Bool
    var includeQuit: Bool
}

// MARK: - Builder

enum StatusBarRenderStateBuilder {
    /// 由输入快照构建完整渲染状态；无副作用。
    static func build(_ input: StatusBarRenderInput) -> StatusBarRenderState {
        guard input.isFeatureAvailable else {
            return StatusBarRenderState(
                mainItemVisible: true,
                iconColor: .template,
                countdown: .hidden,
                showLockBadge: input.isInputLocked,
                tooltip: .inactive,
                contextMenu: .inactive(canRetryLastStart: false),
                includeOpenKeepAwakeSettings: false,
                includeQuit: true
            )
        }

        let mainItemVisible = resolveMainItemVisible(input)
        let iconColor = resolveIconColor(input.sessionState)
        let countdown = resolveCountdown(input)
        let tooltip = resolveTooltip(input)
        let menu = resolveContextMenu(input)

        return StatusBarRenderState(
            mainItemVisible: mainItemVisible,
            iconColor: iconColor,
            countdown: countdown,
            showLockBadge: input.isInputLocked,
            tooltip: tooltip,
            contextMenu: menu,
            includeOpenKeepAwakeSettings: true,
            includeQuit: true
        )
    }

    /// 菜单栏倒计时文本：按分钟向上取整；不足 1 分钟显示 1 min。
    static func menuBarCountdownText(
        endDate: Date?,
        now: Date,
        showCountdown: Bool
    ) -> StatusBarCountdownText {
        guard showCountdown else { return .hidden }
        guard let endDate else { return .indefinite }
        let remaining = endDate.timeIntervalSince(now)
        if remaining <= 0 {
            return .minutes(1)
        }
        // 向上取整到整分钟。
        let totalMinutes = Int(ceil(remaining / 60.0))
        let minutes = max(1, totalMinutes)
        if minutes < 60 {
            return .minutes(minutes)
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return .hoursMinutes(hours: hours, minutes: mins)
    }

    // MARK: - private

    private static func resolveMainItemVisible(_ input: StatusBarRenderInput) -> Bool {
        // 活动会话必须可见，覆盖“有指标时隐藏主图标”。
        switch input.sessionState {
        case .active, .activating, .deactivating, .cleanupRequired:
            return true
        case .inactive:
            if input.hideMainIconWhenMetricsVisible, input.hasVisibleMetrics {
                return false
            }
            return true
        }
    }

    /// 活动会话固定橙色；不再提供用户可配置的图标颜色。
    private static func resolveIconColor(
        _ state: KeepAwakeSessionState
    ) -> StatusBarIconColorPolicy {
        switch state {
        case .cleanupRequired:
            return .cleanupWarning
        case .active:
            return .tint(.orange)
        case .inactive, .activating, .deactivating:
            return .template
        }
    }

    private static func resolveCountdown(_ input: StatusBarRenderInput) -> StatusBarCountdownText {
        switch input.sessionState {
        case .active(let endDate):
            return menuBarCountdownText(
                endDate: endDate,
                now: input.now,
                showCountdown: input.showCountdown
            )
        case .inactive, .activating, .deactivating, .cleanupRequired:
            return .hidden
        }
    }

    private static func resolveTooltip(_ input: StatusBarRenderInput) -> StatusBarTooltipKind {
        switch input.sessionState {
        case .inactive:
            if let error = input.lastOperationError {
                return .inactiveWithError(summary: shortErrorSummary(error))
            }
            return .inactive
        case .activating:
            return .activating
        case .deactivating:
            return .deactivating
        case .active(let endDate?):
            return .activeTimed(endDate: endDate)
        case .active(nil):
            return .activeIndefinite
        case .cleanupRequired:
            return .cleanupRequired
        }
    }

    private static func resolveContextMenu(_ input: StatusBarRenderInput) -> StatusBarContextMenuModel {
        switch input.sessionState {
        case .inactive:
            return .inactive(canRetryLastStart: input.lastOperationError != nil)
        case .activating, .deactivating:
            return .transitional
        case .active:
            return .active
        case .cleanupRequired:
            return .cleanupRequired
        }
    }

    private static func shortErrorSummary(_ error: KeepAwakeError) -> String {
        switch error {
        case .featureUnavailable:
            return "feature unavailable"
        case .alreadyActive:
            return "already active"
        case .alreadyInactive:
            return "already inactive"
        case .operationInProgress:
            return "operation in progress"
        case .systemAssertionFailed:
            return "system assertion failed"
        case .displayAssertionFailed:
            return "display assertion failed"
        case .batteryReadFailed:
            return "battery read failed"
        case .accessibilityPermissionMissing:
            return "accessibility permission missing"
        case .hotkeyRegistrationFailed:
            return "hotkey registration failed"
        case .administratorAuthorizationCancelled:
            return "authorization cancelled"
        case .clamshellUnsupported:
            return "clamshell unsupported"
        case .assertionReleaseFailed:
            return "assertion release failed"
        case .assertionRollbackFailed:
            return "assertion rollback failed"
        default:
            return "keep awake error"
        }
    }
}
