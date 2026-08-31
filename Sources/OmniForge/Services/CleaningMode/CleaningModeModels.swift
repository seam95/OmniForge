import Foundation

/// 清洁模式的两种动作（SPEC D1）：共享同一锁定内核，区别仅为是否显示遮罩。
enum CleaningMode: Equatable {
    /// 键盘清洁：锁定全部输入、不遮屏。
    case keyboard
    /// 屏幕清洁：锁定全部输入，并在所有屏幕覆盖纯色遮罩。
    case screen
}

/// 屏幕清洁遮罩底色（SPEC D2）：纯黑看灰尘，纯白便于浅色灰尘下检查。
enum CleaningOverlayStyle: String, CaseIterable {
    case black
    case white

    /// 持久化用稳定 rawValue；未知值回落默认纯黑。
    static func fromPersistedValue(_ value: String?) -> CleaningOverlayStyle {
        CleaningOverlayStyle(rawValue: value ?? "") ?? .black
    }
}

/// 超时兜底档位（SPEC D13）：`.off` 表示关闭；默认 10 分钟。
enum CleaningTimeout: Hashable {
    static let allChoices: [CleaningTimeout] = [.off, .minutes(5), .minutes(10), .minutes(15), .minutes(30)]

    /// 开关开启时的档位子集（不含 `.off`）。
    static let minuteChoices: [CleaningTimeout] = [.minutes(5), .minutes(10), .minutes(15), .minutes(30)]

    case off
    case minutes(Int)

    static let standard = CleaningTimeout.minutes(10)

    /// 持久化键 cleaningModeTimeoutMinutes 的落库值（0 表示关闭）。
    var persistedMinutes: Int {
        switch self {
        case .off: return 0
        case .minutes(let value): return value
        }
    }

    /// 从落库值还原；非法值（负数、非档位）回落默认 10 分钟。
    static func fromPersistedMinutes(_ value: Int) -> CleaningTimeout {
        switch value {
        case 0: return .off
        case 5, 10, 15, 30: return .minutes(value)
        default: return standard
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .minutes(let value): return TimeInterval(value * 60)
        }
    }
}
