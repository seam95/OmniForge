import ApplicationServices
import SwiftUI

/// 实用工具「保持唤醒」详情页：会话控制的工具页新家（信息架构重构阶段②）。
///
/// 控制中心不再有唤醒 tab（阶段③移除），会话控制迁入本页；设置窗的唤醒项
/// 继续承载配置层（本页底部深链直达）。菜单栏倒计时/右键动作组/全局热键
/// 均不受影响，仍由既有 manager 与 StatusBarController 负责。
struct KeepAwakeUtilityDetailView: View {
    let manager: KeepAwakeManager?
    let clamshellRecoveryCoordinator: ClamshellRecoveryCoordinator?
    let strings: Strings
    var isFeatureAvailable: Bool = true
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }

    @State private var configError: String?

    var body: some View {
        if let manager, isFeatureAvailable {
            KeepAwakeControlView(
                presentation: presentation(for: manager),
                config: configBindings(manager: manager),
                strings: strings,
                onStart: { manager.start() },
                onStop: { manager.stop(reason: .manual) },
                onRetryCleanup: {
                    Task { await manager.retryCleanup() }
                },
                onExtend: { minutes in manager.extend(byMinutes: minutes) },
                onSetDuration: { duration in manager.setDuration(duration) }
            )
        } else {
            // 功能不可用 / manager 缺失：渲染禁用态，入口通常已随可用性隐藏。
            KeepAwakeControlView(
                presentation: KeepAwakeControlPresentationBuilder.build(
                    session: .inactive,
                    clamshell: .off,
                    lastError: nil,
                    blocksStart: false,
                    isFeatureAvailable: false,
                    strings: strings
                ),
                config: .previewDisabled,
                strings: strings
            )
        }
    }

    private func presentation(for manager: KeepAwakeManager) -> KeepAwakeControlPresentation {
        // 倒计时由 KeepAwakeControlView 内部基于 countdownEndDate 局部刷新，避免整页秒级重建。
        KeepAwakeControlPresentationBuilder.build(
            session: manager.state,
            clamshell: manager.clamshellState,
            lastError: manager.lastOperationError,
            blocksStart: clamshellRecoveryCoordinator?.blocksKeepAwakeStart ?? false,
            isFeatureAvailable: isFeatureAvailable,
            now: Date(),
            pointerError: manager.pointerActivityError,
            batteryError: manager.batteryMonitoringError,
            strings: strings
        )
    }

    /// 会话常用配置的读写绑定（原控制中心容器实现平移）。
    private func configBindings(manager: KeepAwakeManager) -> KeepAwakeControlConfigBindings {
        let defaults = UserDefaults.standard
        return KeepAwakeControlConfigBindings(
            defaultDurationMinutes: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes) == nil {
                        return 0
                    }
                    return defaults.integer(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
                },
                set: { newValue in
                    do {
                        _ = try KeepAwakeDuration.parse(newValue)
                        defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
                        configError = nil
                    } catch {
                        configError = String(describing: error)
                    }
                }
            ),
            autoStart: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeAutoStart) == nil { return false }
                    return defaults.bool(forKey: UserDefaultsKeys.keepAwakeAutoStart)
                },
                set: { defaults.set($0, forKey: UserDefaultsKeys.keepAwakeAutoStart) }
            ),
            mouseJiggleEnabled: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled) == nil {
                        return false
                    }
                    return defaults.bool(forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled)
                },
                set: { newValue in
                    defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled)
                    manager.resyncPointerActivityFromConfiguration()
                }
            ),
            mouseJiggleIntervalMinutes: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes) == nil {
                        return 5
                    }
                    return defaults.integer(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
                },
                set: { newValue in
                    do {
                        _ = try KeepAwakePointerInterval.parse(newValue)
                        defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
                        configError = nil
                        manager.resyncPointerActivityFromConfiguration()
                    } catch {
                        configError = String(describing: error)
                    }
                }
            ),
            clamshellPreferred: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred) == nil {
                        return false
                    }
                    return defaults.bool(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
                },
                set: { newValue in
                    defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
                    Task { await manager.setClamshellPreferred(newValue) }
                }
            ),
            onRequestAccessibility: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            onOpenKeepAwakeSettings: {
                onOpenSettings(.keepAwake)
            },
            configError: configError
        )
    }
}
