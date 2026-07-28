import Foundation

// MARK: - 会话操作

/// 用户或系统对保持唤醒会话发起的操作意图。
enum KeepAwakeSessionAction: Equatable {
    case start
    case stop
    case toggle
    case extend
    case retryCleanup
}

/// 会话决策结果：允许执行，或返回明确业务错误。
enum KeepAwakeSessionDecision: Equatable {
    case allow
    case reject(KeepAwakeError)
}

/// 定时/低电量结束是否应发送通知。
enum KeepAwakeNotificationDecision: Equatable {
    case none
    case sessionEnded(KeepAwakeEndReason)
    case cleanupRequiredWarning(KeepAwakeEndReason)
}

// MARK: - 纯决策

/// 会话状态转移与 generation 规则的纯逻辑。
/// 不持有 token、不调度任务；由 Manager 在主 actor 上调用。
enum KeepAwakeSessionSupport {

    /// 根据 SPEC 5.8 判断当前状态是否允许给定操作。
    static func decide(
        action: KeepAwakeSessionAction,
        state: KeepAwakeSessionState
    ) -> KeepAwakeSessionDecision {
        switch (state, action) {
        case (.inactive, .start), (.inactive, .toggle):
            return .allow
        case (.inactive, .stop):
            return .reject(.alreadyInactive)
        case (.inactive, .extend):
            return .reject(.operationInProgress)
        case (.inactive, .retryCleanup):
            // inactive 没有残留；重试清理无意义。
            return .reject(.alreadyInactive)

        case (.activating, .start), (.activating, .toggle), (.activating, .extend), (.activating, .retryCleanup):
            return .reject(.operationInProgress)
        case (.activating, .stop):
            // 允许请求结束当前 generation；异步返回后由 Manager 做补偿清理。
            return .allow

        case (.active, .start):
            return .reject(.alreadyActive)
        case (.active, .toggle), (.active, .stop):
            return .allow
        case let (.active(endDate), .extend):
            return endDate == nil ? .reject(.operationInProgress) : .allow
        case (.active, .retryCleanup):
            // 活动会话只允许重试失败子能力；顶层 cleanup 不适用。
            return .reject(.operationInProgress)

        case (.deactivating, _):
            return .reject(.operationInProgress)

        case (.cleanupRequired, .retryCleanup), (.cleanupRequired, .stop):
            // stop 在 cleanupRequired 下转为 retry cleanup。
            return .allow
        case (.cleanupRequired, .start), (.cleanupRequired, .toggle), (.cleanupRequired, .extend):
            return .reject(.operationInProgress)
        }
    }

    /// 定时会话延长公式：`max(currentEndDate, now) + extension`。
    static func extendedEndDate(
        currentEndDate: Date,
        now: Date,
        extensionMinutes: Int
    ) -> Date {
        let base = max(currentEndDate, now)
        return base.addingTimeInterval(TimeInterval(extensionMinutes * 60))
    }

    /// 由时长与当前时间计算初始截止时间；无限期返回 nil。
    static func initialEndDate(
        duration: KeepAwakeDuration,
        now: Date
    ) -> Date? {
        guard duration.isTimed else { return nil }
        return now.addingTimeInterval(TimeInterval(duration.minutes * 60))
    }

    /// 定时会话墙钟已过截止时间。用于睡眠冻结 uptime 定时器后的补结束判断。
    static func shouldEndForExpiredDeadline(
        state: KeepAwakeSessionState,
        now: Date
    ) -> Bool {
        guard case let .active(endDate?) = state else { return false }
        return endDate <= now
    }

    /// 首个进入 deactivating 的结束原因获胜；后续请求应被拒绝。
    static func shouldAcceptEndReason(
        currentState: KeepAwakeSessionState,
        existingEndReason: KeepAwakeEndReason?
    ) -> Bool {
        if case .deactivating = currentState {
            return false
        }
        if case .cleanupRequired = currentState {
            // 已进入残留态时不再接受新的结束原因。
            return false
        }
        return existingEndReason == nil
    }

    /// 校验异步回调是否仍属于当前 generation。
    static func isCurrentGeneration(
        callbackGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        callbackGeneration == currentGeneration
    }

    /// 通知决策：仅 duration/lowBattery 发送；cleanupRequired 改用警告文案。
    static func notificationDecision(
        endReason: KeepAwakeEndReason,
        enteredCleanupRequired: Bool
    ) -> KeepAwakeNotificationDecision {
        switch endReason {
        case .manual, .featureUninstall, .applicationTermination:
            return .none
        case .durationElapsed, .lowBattery:
            if enteredCleanupRequired {
                return .cleanupRequiredWarning(endReason)
            }
            return .sessionEnded(endReason)
        }
    }
}
