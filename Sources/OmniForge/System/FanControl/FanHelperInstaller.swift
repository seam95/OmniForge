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

    /// 注册状态四态原值（UI 状态机输入）：enabled/requiresApproval/notRegistered/notFound
    static func registrationStatus() -> SMAppService.Status {
        service.status
    }

    /// 注册 daemon（触发系统授权框）。ad-hoc 签名或身份漂移时 launchd 会拒绝。
    /// 首次注册 macOS 会先抛错并弹「后台项目已添加」通知等用户批准 — 事后 status 才是真相。
    static func register() throws {
        try service.register()
    }

    /// 深链系统设置「登录项与扩展」批准页（requiresApproval 时的用户行动入口）
    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 注销 daemon（升级 Helper 版本前先注销）
    static func unregister() throws {
        try service.unregister()
    }

    /// 版本一致性判定（纯函数，可测）：nil 视为不匹配
    static func isVersionMatched(_ installed: String?) -> Bool {
        installed == kFanHelperVersion
    }

    /// register() 抛错后的处置判定（纯函数，可测）。
    /// 首次注册 macOS 同步抛 code=1 属正常「待批准」中间态：系统同时弹通知，
    /// 用户点「允许」并过管理员认证后 daemon 才真正注册 — 报错时的事后 status 才是真相。
    enum RegistrationOutcome: Equatable {
        /// 已注册启用（少见：报错但实际已装上）
        case enabled
        /// 已登记待用户在通知/系统设置批准 — 首装正常中间态，非失败
        case awaitingApproval
        /// 未登记，真失败（附 domain+code 供定位）
        case failed(String)
    }

    static func outcome(
        afterRegisterError error: Error,
        status: SMAppService.Status
    ) -> RegistrationOutcome {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .awaitingApproval
        default:
            // 附带 domain/code：SMAppService 的本地化描述过于含糊，错误码才是定位依据
            let nserror = error as NSError
            return .failed("\(nserror.localizedDescription) (\(nserror.domain) \(nserror.code))")
        }
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
