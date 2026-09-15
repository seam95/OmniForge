import Foundation
import IOKit
import Security
import OmniForgeSMC

/// XPC 命令实现 — 写入序列全部委托共享库 FanSMCWriter，实例常驻保持测试模式状态。
final class FanHelperService: NSObject, FanHelperProtocol {
    static let writer = FanSMCWriter(smc: SMCClient())
    /// 本连接是否发生过控制命令（速度/模式/归还）；版本查询不算控制会话。
    private var performedControl = false
    /// 首个控制命令登记到连接跟踪器（归还未完成时连接死亡 → 补偿归还）。
    private let onControlActivity: () -> Void

    init(onControlActivity: @escaping () -> Void = {}) {
        self.onControlActivity = onControlActivity
    }

    static func cleanupAndExit() {
        try? writer.resetAllFansToAuto()
        exit(0)
    }

    private func markControlActivity() {
        if !performedControl {
            performedControl = true
            onControlActivity()
        }
    }

    func setFanSpeed(fanIndex: Int, rpm: Int, reply: @escaping (Bool, String?) -> Void) {
        markControlActivity()
        do {
            try Self.writer.setFanSpeed(index: fanIndex, rpm: Double(rpm))
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func setFanMode(fanIndex: Int, isAuto: Bool, reply: @escaping (Bool, String?) -> Void) {
        markControlActivity()
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
        markControlActivity()
        do {
            try Self.writer.resetAllFansToAuto()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func getVersion(reply: @escaping (String) -> Void) {
        // 版本查询不构成控制会话：连接断开不得触发归还补偿，
        // 否则会重置其他活跃控制连接的会话状态。
        reply(kFanHelperVersion)
    }
}

/// 连接准入 — 校验调用方签名信息后才放行命令通道
final class FanHelperDelegate: NSObject, NSXPCListenerDelegate {
    /// 曾下发控制命令的活跃连接；最后一个控制连接断开时补偿归还
    /// （主应用崩溃/被杀时风扇不会停留在手动目标）。
    private static let controlLock = NSLock()
    private static var activeControlConnections: Set<NSXPCConnection> = []

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard FanHelperCallerValidator.isTrusted(newConnection) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        let service = FanHelperService(onControlActivity: { [weak newConnection] in
            guard let connection = newConnection else { return }
            Self.registerControlConnection(connection)
        })
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak newConnection] in
            guard let connection = newConnection else { return }
            Self.unregisterControlConnection(connection)
        }
        newConnection.resume()
        return true
    }

    private static func registerControlConnection(_ connection: NSXPCConnection) {
        controlLock.lock()
        activeControlConnections.insert(connection)
        controlLock.unlock()
    }

    /// 控制连接断开：最后一个断开时归还全部风扇（幂等 — 主应用正常退出
    /// 已先归还过，此路径主要补偿主应用异常死亡）。
    private static func unregisterControlConnection(_ connection: NSXPCConnection) {
        controlLock.lock()
        activeControlConnections.remove(connection)
        let shouldHandBack = activeControlConnections.isEmpty
        controlLock.unlock()
        if shouldHandBack {
            try? FanHelperService.writer.resetAllFansToAuto()
        }
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
