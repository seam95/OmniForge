import Foundation

/// 功能的真实运行状态。安装状态仍由 FeatureRuntime 独立管理。
enum FeatureRunState: Equatable {
    case stopped
    case running
    case waitingPermission
    case failed(String)

    static func resolve(
        isEnabled: Bool,
        isRunning: Bool,
        hasPermission: Bool,
        lastError: String?
    ) -> FeatureRunState {
        guard isEnabled else { return .stopped }
        guard hasPermission else { return .waitingPermission }
        if isRunning { return .running }
        if let lastError { return .failed(lastError) }
        return .stopped
    }
}
