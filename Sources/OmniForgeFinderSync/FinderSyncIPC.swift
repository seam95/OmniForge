import Cocoa
import OSLog

private let ipcLogger = Logger(subsystem: "app.omniforge.FinderSync", category: "ipc")

/// 扩展端 IPC 发送器：将右键操作事件发送给 OmniForge 宿主应用
final class FinderSyncIPC {
    static let shared = FinderSyncIPC()

    private let notificationName = NSNotification.Name("app.omniforge.rightclick.action")

    /// 宿主写入 App Group 域的 IPC 令牌键，与 RightClickService.ipcTokenKey 同值。
    /// 两端各自声明（appex 无法链接宿主代码），改动时必须同步。
    private static let ipcTokenKey = "rightclick.ipcToken"

    func postAction(type: String, parameter: String? = nil, targetURLs: [URL] = []) {
        // 威胁模型：分布式通知是系统全局总线，任何本地进程都能伪造同名通知，借宿主的
        // TCC 授权执行文件操作；宿主因此校验载荷令牌。令牌只有真正的 App Group 成员
        // 读得到——读不到（宿主未启动过/首次启动尚未写入令牌）则不发送：无令牌消息
        // 会被宿主直接丢弃，退化为无令牌发送只会重新打开伪造通路（降级攻击）。
        guard let token = UserDefaults(suiteName: FinderSyncAppGroup.identifier)?
            .string(forKey: Self.ipcTokenKey) else {
            ipcLogger.error("ipc token unavailable in app group, drop action \(type, privacy: .public)")
            return
        }

        var payload: [String: Any] = [
            "actionType": type,
            "targetURLs": targetURLs.map { $0.absoluteString },
            "token": token,
        ]
        if let param = parameter {
            payload["parameter"] = param
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            ipcLogger.error("failed to encode payload for \(type, privacy: .public)")
            return
        }

        // 载荷必须放在 object 上、userInfo 传 nil：App Sandbox 会拦截携带 userInfo 字典的
        // 分布式通知，投递被静默丢弃（"attempt to post distributed notification ...
        // thwarted by sandboxing"），宿主一个动作都收不到。object 可正常送达。
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: jsonString,
            userInfo: nil,
            deliverImmediately: true
        )
        ipcLogger.info("posted action \(type, privacy: .public) (\(jsonString.count) bytes via object)")
    }
}
