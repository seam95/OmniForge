import Foundation
import OmniForgeSMC
import ServiceManagement

/// 特权风扇 Helper 的安装管理 — SMAppService 注册/注销 + 版本协商。
/// 注册动作是唯一会弹系统管理员授权框的路径。
enum FanHelperInstaller {
    /// 与 app bundle 内 Contents/Library/LaunchDaemons/ 下的 plist 文件名一致
    static let plistName = "app.omniforge.fan-helper.plist"

    private static var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// daemon 是否已注册并启用
    static func isRegistered() -> Bool {
        service.status == .enabled
    }

    /// 注册 daemon（触发系统授权框）。ad-hoc 签名或身份漂移时 launchd 会拒绝。
    static func register() throws {
        try service.register()
    }

    /// 注销 daemon（升级 Helper 版本前先注销）
    static func unregister() throws {
        try service.unregister()
    }

    /// 版本一致性判定（纯函数，可测）：nil 视为不匹配
    static func isVersionMatched(_ installed: String?) -> Bool {
        installed == kFanHelperVersion
    }

    /// 已安装 Helper 与 app 内置协议版本是否一致；未注册时回调 nil
    static func checkVersion(
        client: FanHelperClient,
        completion: @escaping (Bool?) -> Void
    ) {
        guard isRegistered() else {
            completion(nil)
            return
        }
        client.fetchVersion { version in
            completion(isVersionMatched(version) ? true : false)
        }
    }
}
