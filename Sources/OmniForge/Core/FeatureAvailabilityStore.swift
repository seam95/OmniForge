import Foundation

/// availability 唯一持久化边界；禁止业务层直接写 UserDefaults.standard。
protocol FeatureAvailabilityStoring: AnyObject {
    func isAvailable(_ feature: AppFeature) -> Bool
    func setAvailable(_ feature: AppFeature, _ available: Bool) throws
}

/// 基于 UserDefaults 的 availability 存储。
final class UserDefaultsFeatureAvailabilityStore: FeatureAvailabilityStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAvailable(_ feature: AppFeature) -> Bool {
        // 未写入时默认 true（与 Defaults 注册一致）。
        if defaults.object(forKey: feature.availabilityKey) == nil {
            return true
        }
        return defaults.bool(forKey: feature.availabilityKey)
    }

    func setAvailable(_ feature: AppFeature, _ available: Bool) throws {
        defaults.set(available, forKey: feature.availabilityKey)
    }
}

/// Feature 可用性事务 UI 状态。failed 携带请求方向，UI 据此区分安装/卸载失败
/// 并把重试按钮指向同方向（卸载失败时 availability 仍为 true，不能用它判向）。
enum FeatureAvailabilityPhase: Equatable {
    case idle
    case installing
    case uninstalling
    case failed(requestedAvailable: Bool, reason: String)
}

enum FeatureAvailabilityError: Error, Equatable {
    case operationInProgress
    case teardownFailed(String)
    case persistenceFailed(String)
    case installFailed(String)
}
