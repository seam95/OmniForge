import Combine
import Foundation
import ServiceManagement

protocol LaunchAtLoginClient {
    func setEnabled(_ enabled: Bool) throws
}

struct LaunchAtLoginError: LocalizedError, Equatable {
    let message: String

    init(_ error: Error) {
        message = error.localizedDescription
    }

    var errorDescription: String? {
        message
    }
}

final class FakeLaunchAtLoginClient: LaunchAtLoginClient {
    private(set) var lastEnabled: Bool?

    func setEnabled(_ enabled: Bool) throws {
        lastEnabled = enabled
    }
}

final class ServiceManagementLaunchAtLoginClient: LaunchAtLoginClient {
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: LaunchAtLoginError?

    private let client: LaunchAtLoginClient
    private let userDefaults: UserDefaults

    init(client: LaunchAtLoginClient, userDefaults: UserDefaults = .standard) {
        self.client = client
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.bool(forKey: UserDefaultsKeys.launchAtLogin)
        self.lastError = nil
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAtLoginError> {
        do {
            try client.setEnabled(enabled)
            isEnabled = enabled
            userDefaults.set(enabled, forKey: UserDefaultsKeys.launchAtLogin)
            lastError = nil
            return .success(())
        } catch {
            let mappedError = LaunchAtLoginError(error)
            lastError = mappedError
            return .failure(mappedError)
        }
    }
}
