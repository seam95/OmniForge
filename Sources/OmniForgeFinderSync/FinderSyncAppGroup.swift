import Foundation

/// 宿主与沙盒化的 FinderSync 扩展共享配置所用的 app group 标识。
///
/// 与宿主侧 `RightClickConfiguration.appGroupIdentifier` 必须是同一个值——两端各自
/// 声明，无法共享代码（appex 目标 `dependencies: []`）。
///
/// 必须带 Team ID 前缀（`P684VHKUAZ.group.app.omniforge`）：不带前缀的 iOS 风格
/// `group.*` 标识会被 containermanagerd 用 TCC 拦起来，扩展侧
/// `UserDefaults(suiteName:)` 会报
/// 「Using kCFPreferencesAnyUser with a container is only allowed for System
/// Containers, detaching from cfprefsd」，读不到任何值，全部静默走默认值。
enum FinderSyncAppGroup {
    static let identifier = "P684VHKUAZ.group.app.omniforge"
}
