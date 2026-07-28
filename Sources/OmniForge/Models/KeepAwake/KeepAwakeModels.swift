import Foundation

// MARK: - 配置合法值

/// 保持唤醒会话时长（分钟）。0 表示不限时（无限期）。
enum KeepAwakeDuration: Int, CaseIterable, Equatable, Codable {
    case indefinite = 0
    case minutes15 = 15
    case minutes30 = 30
    case minutes60 = 60
    case minutes120 = 120
    case minutes240 = 240
    case minutes480 = 480

    var minutes: Int { rawValue }
    var isIndefinite: Bool { self == .indefinite }
    var isTimed: Bool { !isIndefinite }

    /// 解析持久化或用户输入的分钟数。非法值明确失败，不替换为默认值。
    static func parse(_ minutes: Int) throws -> KeepAwakeDuration {
        guard let value = KeepAwakeDuration(rawValue: minutes) else {
            throw KeepAwakeError.invalidDuration(minutes)
        }
        return value
    }
}

/// 低电量保护阈值（百分比）。0 表示关闭保护。
enum KeepAwakeBatteryLimit: Int, CaseIterable, Equatable, Codable {
    case disabled = 0
    case percent5 = 5
    case percent10 = 10
    case percent15 = 15
    case percent20 = 20

    var percent: Int { rawValue }
    var isDisabled: Bool { self == .disabled }

    static func parse(_ percent: Int) throws -> KeepAwakeBatteryLimit {
        guard let value = KeepAwakeBatteryLimit(rawValue: percent) else {
            throw KeepAwakeError.invalidBatteryLimit(percent)
        }
        return value
    }
}

/// 指针微动间隔（分钟）。
enum KeepAwakePointerInterval: Int, CaseIterable, Equatable, Codable {
    case minutes1 = 1
    case minutes2 = 2
    case minutes5 = 5
    case minutes10 = 10
    case minutes15 = 15

    var minutes: Int { rawValue }

    static func parse(_ minutes: Int) throws -> KeepAwakePointerInterval {
        guard let value = KeepAwakePointerInterval(rawValue: minutes) else {
            throw KeepAwakeError.invalidPointerInterval(minutes)
        }
        return value
    }
}

/// 菜单栏活动图标着色。
enum KeepAwakeIconTint: String, CaseIterable, Equatable, Codable {
    case orange
    case green
    case blue
    case purple
    case pink
    case none

    static func parse(_ raw: String) throws -> KeepAwakeIconTint {
        guard let value = KeepAwakeIconTint(rawValue: raw) else {
            throw KeepAwakeError.invalidIconTint(raw)
        }
        return value
    }
}

// MARK: - 残留与会话状态

/// 清理失败时仍可能存在的系统副作用。
struct KeepAwakeResidualEffects: OptionSet, Equatable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let systemAssertion = KeepAwakeResidualEffects(rawValue: 1 << 0)
    static let displayAssertion = KeepAwakeResidualEffects(rawValue: 1 << 1)
    static let clamshellSleepDisabled = KeepAwakeResidualEffects(rawValue: 1 << 2)
}

/// 保持唤醒会话状态。唯一业务状态源由 Manager 持有。
enum KeepAwakeSessionState: Equatable {
    case inactive
    case activating
    case active(endDate: Date?)
    case deactivating
    case cleanupRequired(KeepAwakeResidualEffects, KeepAwakeError)

    /// 仅 `.active` 为 true。
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// 仅 `.active` 返回截止时间；无限期为 nil。
    var endDate: Date? {
        if case let .active(endDate) = self { return endDate }
        return nil
    }

    /// 仅 `.cleanupRequired` 暴露残留；其他状态不得携带残留语义。
    var residualEffects: KeepAwakeResidualEffects? {
        if case let .cleanupRequired(effects, _) = self { return effects }
        return nil
    }

    /// 是否允许启动新会话（过渡态与残留态禁止）。
    var canStart: Bool {
        if case .inactive = self { return true }
        return false
    }

    /// 仅定时活动会话可延长。
    var canExtend: Bool {
        if case let .active(endDate) = self { return endDate != nil }
        return false
    }

    /// 残留清理是 cleanupRequired 的首要操作。
    var canRetryCleanup: Bool {
        if case .cleanupRequired = self { return true }
        return false
    }
}

/// 会话结束原因；首次进入 deactivating 的原因获胜。
enum KeepAwakeEndReason: Equatable {
    case manual
    case durationElapsed
    case lowBattery
    case featureUninstall
    case applicationTermination
}

/// 合盖子能力状态；失败不把正常 active 会话改成 inactive。
enum ClamshellState: Equatable {
    case off
    case checking
    case authorizing
    case enabling
    case active
    case restoring
    case conflict(KeepAwakeError)
    case failed(KeepAwakeError)
}

// MARK: - 错误

/// 保持唤醒明确错误。不得静默回退或伪造成功。
enum KeepAwakeError: Error, Equatable {
    case featureUnavailable
    case invalidDuration(Int)
    case invalidBatteryLimit(Int)
    case invalidPointerInterval(Int)
    case invalidIconTint(String)
    case systemAssertionFailed(code: Int32)
    case displayAssertionFailed(code: Int32)
    case assertionRollbackFailed(kind: String, code: Int32)
    case assertionReleaseFailed(kind: String, code: Int32)
    case batteryReadFailed(String)
    case accessibilityPermissionMissing
    case pointerEventFailed
    case operationInProgress
    case alreadyActive
    case alreadyInactive
    case hotkeyRegistrationFailed(status: Int32)
    case hotkeyUnregistrationFailed(status: Int32)
    case clamshellUnsupported(String)
    case administratorAuthorizationCancelled
    case administratorCommandFailed(command: String, status: Int32, output: String)
    case sudoersValidationFailed(String)
    case clamshellStateUnverified(String)
    case recoveryRecordReadFailed(String)
    case recoveryRecordWriteFailed(String)
    case sleepRestoreFailed(String)
    case authorizationRemovalFailed(String)
    case notificationDeliveryFailed(String)
}
