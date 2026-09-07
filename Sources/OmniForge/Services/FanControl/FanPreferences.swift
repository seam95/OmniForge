import Foundation
import Combine

/// 风扇控制偏好 — 性能模式与手动覆盖的持久化配置
struct FanControlConfiguration: Equatable, Codable {
    /// 性能模式总开关（默认关闭）
    var performanceMode = false
    /// 性能档位
    var performanceLevel = FanCurve.Level.medium
    /// 电池省电：电池供电且电量 ≤ 阈值时抑制性能模式
    var batterySaverEnabled = true
    var batterySaverThreshold = 20
    /// 电池供电时仍强制开启性能模式（覆盖省电抑制）
    var forcePerformanceOnBattery = false
    /// 锁屏/屏幕休眠期间保持风扇控制（默认归还自动，安全优先）
    var keepFansOnScreenSleep = false

    init() {}
}

/// 偏好管理器 — UserDefaults 持久化，写入整包替换触发 @Published
final class FanPreferences: ObservableObject {
    @Published var configuration: FanControlConfiguration
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private static let storageKey = "OmniForge.fanControlConfiguration"

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.configuration = FanPreferences.load(from: userDefaults)
        $configuration
            .dropFirst()
            .sink { [weak self] config in
                self?.persist(config)
            }
            .store(in: &cancellables)
    }

    func update(_ mutate: (inout FanControlConfiguration) -> Void) {
        var copy = configuration
        mutate(&copy)
        configuration = copy
    }

    private static func load(from defaults: UserDefaults) -> FanControlConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(FanControlConfiguration.self, from: data) else {
            return FanControlConfiguration()
        }
        return decoded
    }

    private func persist(_ config: FanControlConfiguration) {
        if let data = try? JSONEncoder().encode(config) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }
}
