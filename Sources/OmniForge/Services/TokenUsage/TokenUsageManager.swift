import Combine
import Foundation

/// Token 用量运行时 — 调度限额取数 / 用量采集 / 告警，聚合为面板快照。
///
/// 特性骨架阶段（#01）仅提供启停生命周期；限额取数（#02/#03）、
/// 用量采集（#04+）与告警（#11）按 issue 逐步接入。
@MainActor
final class TokenUsageManager: ObservableObject {
    @Published private(set) var isActive = false

    private let preferences: TokenUsagePreferences
    private var cancellables = Set<AnyCancellable>()

    init(preferences: TokenUsagePreferences) {
        self.preferences = preferences
    }

    /// 启用：开始限额取数与用量采集（由 FeatureRuntime binding 驱动）。
    func start() {
        guard !isActive else { return }
        isActive = true
    }

    /// 停用：停止所有后台刷新与监听。
    func stop() {
        guard isActive else { return }
        isActive = false
    }

    /// 手动刷新入口（底栏「刷新」；穿透缓存但遵循 429 冷却）。
    /// 骨架阶段为空实现，限额刷新自 #02 起接入。
    func refreshNow(force: Bool = false) {}
}
