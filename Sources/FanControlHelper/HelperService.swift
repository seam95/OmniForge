import Foundation
import IOKit
import Security
import OmniForgeSMC

/// XPC 命令实现 — 写入序列全部委托共享库 FanSMCWriter，实例常驻保持测试模式状态。
final class FanHelperService: NSObject, FanHelperProtocol {
    private static let writer = FanSMCWriter(smc: SMCClient())

    static func cleanupAndExit() {
        try? writer.resetAllFansToAuto()
        exit(0)
    }

    func setFanSpeed(fanIndex: Int, rpm: Int, reply: @escaping (Bool, String?) -> Void) {
        do {
            try Self.writer.setFanSpeed(index: fanIndex, rpm: Double(rpm))
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func setFanMode(fanIndex: Int, isAuto: Bool, reply: @escaping (Bool, String?) -> Void) {
        guard isAuto else {
            // 手动模式必须携带目标转速（走 setFanSpeed）；
            // 拒绝无转速的手动请求，防止风扇被误写停转
            reply(false, "manual mode requires a target rpm")
            return
        }
        do {
            try Self.writer.setFanAuto(index: fanIndex)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func resetAllFans(reply: @escaping (Bool, String?) -> Void) {
        do {
            try Self.writer.resetAllFansToAuto()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(kFanHelperVersion)
    }
}

/// 连接准入 — 校验调用方签名信息后才放行命令通道
final class FanHelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard FanHelperCallerValidator.isTrusted(newConnection) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        newConnection.exportedObject = FanHelperService()
        newConnection.resume()
        return true
    }
}

/// 调用方校验：pid → SecCode → 签名信息中的 bundle identifier 必须是主应用。
/// 不校验则任意本地进程都可经 Mach 服务命令写风扇。
/// NSXPCConnection 未公开 auditToken，按 pid 取 SecCode 存在理论上的
/// TOCTOU 窗口（pid 复用）；对风扇写入这一攻击面，pid 校验已是务实折中。
enum FanHelperCallerValidator {
    static let expectedBundleIdentifier = "app.omniforge"

    static func isTrusted(_ connection: NSXPCConnection) -> Bool {
        guard let staticCode = staticCode(of: connection),
              let info = signingInfo(of: staticCode) else {
            return false
        }
        return isTrustedSigningInfo(info)
    }

    /// 纯判定（可测）：bundle identifier 与主应用一致。
    /// kSecCodeInfo 常量未完整桥接 Swift，直接用其底层字符串值。
    static func isTrustedSigningInfo(_ info: [String: Any]) -> Bool {
        guard let bundleID = info["bundle-identifier"] as? String else {
            return false
        }
        return bundleID == expectedBundleIdentifier
    }

    private static func staticCode(of connection: NSXPCConnection) -> SecStaticCode? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: connection.processIdentifier as NSNumber] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess else {
            return nil
        }
        return staticCode
    }

    private static func signingInfo(of staticCode: SecStaticCode) -> [String: Any]? {
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &infoCF) == errSecSuccess else {
            return nil
        }
        return infoCF as? [String: Any]
    }
}
