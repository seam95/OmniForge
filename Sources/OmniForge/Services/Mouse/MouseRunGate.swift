import Foundation

/// 四个鼠标服务共享的唯一运行门控与失败状态机。
enum MouseRunGate {
    struct Input: Equatable {
        let isAvailable: Bool
        let featureEnabled: Bool
        let hasPermission: Bool
    }

    enum Decision: Equatable {
        case stopped
        case waitingPermission
        case start
    }

    static func decision(for input: Input) -> Decision {
        guard input.isAvailable, input.featureEnabled else {
            return .stopped
        }
        guard input.hasPermission else { return .waitingPermission }
        return .start
    }

    /// 同步只尝试一次启动；失败会锁存，直到用户显式 retry 或先关闭门控。
    static func synchronize(
        input: Input,
        retry: Bool = false,
        isRunning: inout Bool,
        lastError: inout String?,
        start: () throws -> Void,
        stop: () -> Void
    ) {
        switch decision(for: input) {
        case .stopped, .waitingPermission:
            stop()
            isRunning = false
            lastError = nil
        case .start:
            guard !isRunning else { return }
            guard retry || lastError == nil else { return }
            do {
                try start()
                isRunning = true
                lastError = nil
            } catch {
                isRunning = false
                lastError = error.localizedDescription
            }
        }
    }
}

enum MouseServiceError: LocalizedError {
    case eventTapCreationFailed(service: String)

    var errorDescription: String? {
        switch self {
        case .eventTapCreationFailed(let service):
            return "\(service): CGEvent.tapCreate returned nil"
        }
    }
}
