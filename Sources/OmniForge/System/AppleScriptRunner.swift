import AppKit
import CoreServices

/// 在进程内（通过 NSAppleScript）向另一个 app 发送 Apple Events，而非 spawn `osascript`。
/// 这样 Automation 授权归属本 app —— 跨更新保持授予、丢失时重新请求、且首次授权提示永不被看门狗杀掉。
/// 它与各功能已要求的同一 per-target Automation 权限无异，不请求任何新东西。
/// 请在主线程之外调用，这样慢目标永不会阻塞 UI 或事件 tap（调用会阻塞其线程直到目标回应）。
enum AppleScriptRunner {
    /// 本 app 是否可脚本化 `bundleID`。未决 → 显示系统提示（归属本 app）；已授予 → 立即返回；
    /// 已拒绝 → 返回 false 且不再纠缠。
    @discardableResult
    static func consentToAutomate(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let created = bundleID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, bundleID.utf8.count, &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true) == noErr
    }

    /// 在本进程内运行 AppleScript。返回是否成功及结果字符串（失败时为错误消息）。
    /// 在进程内发送事件本身会在授权未决时触发 Automation 提示。
    @discardableResult
    static func run(_ source: String) -> (ok: Bool, output: String) {
        guard let script = NSAppleScript(source: source) else { return (false, "") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (false, (error[NSAppleScript.errorMessage] as? String) ?? "")
        }
        return (true, result.stringValue ?? "")
    }

    /// 转义一个值，以便嵌入 AppleScript 双引号字符串。
    static func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
