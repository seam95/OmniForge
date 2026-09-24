import Cocoa
import OSLog

private let ipcLogger = Logger(subsystem: "app.omniforge.FinderSync", category: "ipc")

/// 扩展端 IPC 发送器：将右键操作事件发送给 OmniForge 宿主应用
final class FinderSyncIPC {
    static let shared = FinderSyncIPC()

    private let notificationName = NSNotification.Name("app.omniforge.rightclick.action")

    func postAction(type: String, parameter: String? = nil, targetURLs: [URL] = []) {
        var payload: [String: Any] = [
            "actionType": type,
            "targetURLs": targetURLs.map { $0.absoluteString }
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
