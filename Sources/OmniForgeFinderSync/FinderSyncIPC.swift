import Cocoa

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
            return
        }

        let userInfo = ["payload": jsonString]
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
