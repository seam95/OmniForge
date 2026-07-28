import Combine
import Foundation

final class LockStateManager: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var lockedInputSourceID: String?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isLocked = userDefaults.bool(forKey: UserDefaultsKeys.isLocked)
        self.lockedInputSourceID = userDefaults.string(forKey: UserDefaultsKeys.lockedInputSourceID)
    }

    func lock(to inputSourceID: String) {
        isLocked = true
        lockedInputSourceID = inputSourceID
        userDefaults.set(true, forKey: UserDefaultsKeys.isLocked)
        userDefaults.set(inputSourceID, forKey: UserDefaultsKeys.lockedInputSourceID)
    }

    func unlock() {
        isLocked = false
        userDefaults.set(false, forKey: UserDefaultsKeys.isLocked)
    }
}
