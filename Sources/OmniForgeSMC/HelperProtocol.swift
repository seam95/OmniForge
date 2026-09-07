import Foundation

/// 特权风扇 Helper 的 Mach 服务名 — 与 app bundle 内
/// Contents/Library/LaunchDaemons/app.omniforge.fan-helper.plist 的 MachServices 键一致。
public let kFanHelperMachServiceName = "app.omniforge.fan-helper"

/// Helper 协议版本 — app 与已安装 Helper 不匹配时提示重新安装
public let kFanHelperVersion = "1.0.0"

/// 特权 Helper 暴露给主应用的风扇写入命令
@objc public protocol FanHelperProtocol {
    /// 将风扇设为手动并写入目标转速（RPM）
    func setFanSpeed(fanIndex: Int, rpm: Int, reply: @escaping (Bool, String?) -> Void)
    /// 单风扇归还自动模式（全部归还后 Helper 自行关闭 SMC 测试模式）
    func setFanMode(fanIndex: Int, isAuto: Bool, reply: @escaping (Bool, String?) -> Void)
    /// 全部风扇归还自动模式并退出测试模式
    func resetAllFans(reply: @escaping (Bool, String?) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
}
